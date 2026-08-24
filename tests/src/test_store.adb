--  Driver for Memcp.Store: exercises the write, read, list, search, session and
--  reindex operations against an in-memory database, then the on-disk
--  transcript path against a file-backed one. The closing section covers the
--  failure paths, breaking the schema behind an open store to reach them.
--  Built with -gnata, so the Store's and the binding's contracts are checked as
--  it runs.

with Ada.Command_Line;
with Ada.Text_IO;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Interfaces;

with Candle_Spark;
with Sqlite_Vec_Spark;
with Memcp.Store;

procedure Test_Store with SPARK_Mode => Off is

   use type Sqlite_Vec_Spark.Status;
   use type Memcp.Store.Open_Status;
   use type Memcp.Store.Op_Status;
   use type Memcp.Store.Row_Id;
   use type Memcp.Store.Summary_Ptr;

   Failures : Natural := 0;
   --  Checks that did not hold; nonzero means a failing exit status.

   procedure Check (Cond : Boolean; Label : String);
   --  Report Cond under Label and count it if it does not hold.

   procedure Check (Cond : Boolean; Label : String) is
   begin
      if Cond then
         Ada.Text_IO.Put_Line ("ok   - " & Label);
      else
         Ada.Text_IO.Put_Line ("FAIL - " & Label);
         Failures := Failures + 1;
      end if;
   end Check;

   Zero_Emb : constant Candle_Spark.Embedding := [others => 0.0];
   --  The all-zero embedding, for rows whose vector does not matter.

   function Hot (K : Positive) return Candle_Spark.Embedding;
   --  A unit embedding with dimension K hot -- enough to order a KNN query.

   function Hot (K : Positive) return Candle_Spark.Embedding is
      E : Candle_Spark.Embedding := [others => 0.0];
   begin
      E (K) := 1.0;
      return E;
   end Hot;

   function Scalar (Path, Query : String) return String;
   --  The first column of Query's first row, run against the database at
   --  Path, or "" when it returns no row. "<null>" for a NULL column, so a
   --  missing attribution is distinguishable from a missing row.

   function Scalar (Path, Query : String) return String is
      DB   : Sqlite_Vec_Spark.Database;
      Stmt : Sqlite_Vec_Spark.Statement;
      St   : Sqlite_Vec_Spark.Status;
   begin
      Sqlite_Vec_Spark.Open (DB, Path, St);
      if St /= Sqlite_Vec_Spark.Ok then
         return "";
      end if;
      Sqlite_Vec_Spark.Prepare (DB, Query, Stmt, St);
      if St /= Sqlite_Vec_Spark.Ok then
         Sqlite_Vec_Spark.Close (DB);
         return "";
      end if;
      Sqlite_Vec_Spark.Step (Stmt, St);
      declare
         Got : Sqlite_Vec_Spark.Text_Ptr;
         Out_S : constant String :=
           (if St /= Sqlite_Vec_Spark.Row then ""
            elsif Sqlite_Vec_Spark.Column_Is_Null (Stmt, 0) then "<null>"
            else "");
      begin
         if Out_S = "" and then St = Sqlite_Vec_Spark.Row then
            Got := Sqlite_Vec_Spark.Column_Text (Stmt, 0);
            declare
               Text : constant String := Got.all;
            begin
               Sqlite_Vec_Spark.Free (Got);
               Sqlite_Vec_Spark.Finalize (Stmt);
               Sqlite_Vec_Spark.Close (DB);
               return Text;
            end;
         end if;
         Sqlite_Vec_Spark.Finalize (Stmt);
         Sqlite_Vec_Spark.Close (DB);
         return Out_S;
      end;
   end Scalar;

   function Read_File (Path : String) return String;
   --  The whole file at Path, as raw bytes.

   function Read_File (Path : String) return String is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Open (F, In_File, Path);
      declare
         Len : constant Natural := Natural (Size (F));
         Buf : String (1 .. Len);
      begin
         String'Read (Stream (F), Buf);
         Close (F);
         return Buf;
      end;
   end Read_File;

   TS : constant String := "2026-01-01T12:00:00+00:00";
   --  created_at for rows whose timestamp is not under test.

   S      : Memcp.Store.Store;
   --  The in-memory store shared by every block below.

   Open_S : Memcp.Store.Open_Status;
   --  Outcome of opening S.
begin
   Memcp.Store.Open (S, ":memory:", Open_S);
   Check (Open_S = Memcp.Store.Opened, "Open :memory: -> Opened");
   Check (Memcp.Store.Is_Open (S), "Is_Open after Open");

   ------------------------------------------------------------------
   --  Fresh insert
   ------------------------------------------------------------------
   declare
      R  : Memcp.Store.Save_Result;
      St : Memcp.Store.Op_Status;
   begin
      Memcp.Store.Save
        (S, "demo", "a diary headline",
         "HEADLINE: my summary head" & ASCII.LF & "the body text",
         Zero_Emb, Has_Session => False, Session_Id => "",
         Surface => "", Surface_Label => "",
         Has_Created => True, Created_At => TS, Result => R, Status => St);
      Check (St = Memcp.Store.Success, "Save fresh -> Success");
      Check (not R.Already_Existed and not R.Replaced, "Save fresh: new row");
      Check (R.Summary_Id > 0 and R.Diary_Id > 0, "Save fresh: rowids assigned");

      --  Fetch it back.
      declare
         P  : Memcp.Store.Summary_Ptr;
         St2 : Memcp.Store.Op_Status;
      begin
         Memcp.Store.Fetch_Summary (S, R.Summary_Id, P, St2);
         Check (St2 = Memcp.Store.Success and then P /= null,
                "Fetch_Summary hit");
         if P /= null then
            Check (P.Project = "demo", "Fetch: project");
            Check (P.Headline = "my summary head", "Fetch: HEADLINE parsed");
            Check (P.Content = "HEADLINE: my summary head" & ASCII.LF
                   & "the body text", "Fetch: body preserved");
            Check (P.Kind = "diary", "Fetch: kind=diary");
            Check (not P.Has_Session, "Fetch: session null");
            Memcp.Store.Free (P);
         end if;
      end;

      --  Identical retry: content-dedup no-op, same ids.
      declare
         R2 : Memcp.Store.Save_Result;
         St2 : Memcp.Store.Op_Status;
      begin
         Memcp.Store.Save
           (S, "demo", "a diary headline",
            "HEADLINE: my summary head" & ASCII.LF & "the body text",
            Zero_Emb, Has_Session => False, Session_Id => "",
            Surface => "", Surface_Label => "",
            Has_Created => True, Created_At => TS, Result => R2, Status => St2);
         Check (St2 = Memcp.Store.Success, "Save retry -> Success");
         Check (R2.Already_Existed and not R2.Replaced, "Save retry: dedup");
         Check (R2.Summary_Id = R.Summary_Id and R2.Diary_Id = R.Diary_Id,
                "Save retry: ids preserved");
      end;

      --  Forget it.
      declare
         Del : Boolean;
         St2 : Memcp.Store.Op_Status;
         P   : Memcp.Store.Summary_Ptr;
         St3 : Memcp.Store.Op_Status;
      begin
         Memcp.Store.Forget_Summary (S, R.Summary_Id, Del, St2);
         Check (St2 = Memcp.Store.Success and then Del, "Forget: deleted");
         Memcp.Store.Fetch_Summary (S, R.Summary_Id, P, St3);
         Check (St3 = Memcp.Store.Success and then P = null,
                "Fetch after forget: miss");
         Memcp.Store.Forget_Summary (S, R.Summary_Id, Del, St2);
         Check (St2 = Memcp.Store.Success and then not Del,
                "Forget again: idempotent miss");
      end;
   end;

   ------------------------------------------------------------------
   --  Session-scoped upsert: second save replaces in place
   ------------------------------------------------------------------
   declare
      R1, R2 : Memcp.Store.Save_Result;
      St1, St2 : Memcp.Store.Op_Status;
      P  : Memcp.Store.Summary_Ptr;
      St3 : Memcp.Store.Op_Status;
   begin
      Memcp.Store.Save
        (S, "demo", "first diary", "first summary body",
         Zero_Emb, Has_Session => True, Session_Id => "sess-1",
         Surface => "", Surface_Label => "",
         Has_Created => True, Created_At => TS, Result => R1, Status => St1);
      Check (St1 = Memcp.Store.Success and then not R1.Already_Existed,
             "Session save: fresh");

      Memcp.Store.Save
        (S, "demo", "second diary", "second summary body",
         Zero_Emb, Has_Session => True, Session_Id => "sess-1",
         Surface => "", Surface_Label => "",
         Has_Created => True, Created_At => TS, Result => R2, Status => St2);
      Check (St2 = Memcp.Store.Success and then R2.Replaced,
             "Session save: replaced in place");
      Check (R2.Summary_Id = R1.Summary_Id and R2.Diary_Id = R1.Diary_Id,
             "Session save: ids preserved across replace");

      Memcp.Store.Fetch_Summary (S, R2.Summary_Id, P, St3);
      Check (St3 = Memcp.Store.Success and then P /= null
             and then P.Content = "second summary body",
             "Session save: body updated");
      Check (P /= null and then P.Has_Session and then P.Session = "sess-1",
             "Session save: session_id set");
      if P /= null then
         Memcp.Store.Free (P);
      end if;
   end;

   ------------------------------------------------------------------
   --  Recent_Diary: list-valued read over a Name_List filter
   ------------------------------------------------------------------
   declare
      use type Memcp.Store.Name_Vectors.Capacity_Range;
      R1, R2, R3 : Memcp.Store.Save_Result;
      Stx        : Memcp.Store.Op_Status;
      Projs      : Memcp.Store.Name_List;
      Empty      : Memcp.Store.Name_List;
      Entries    : Memcp.Store.Diary_Entry_List;
      RD_St      : Memcp.Store.Op_Status;
   begin
      --  Three diary entries across two projects, ascending timestamps.
      Memcp.Store.Save
        (S, "alpha", "diary a1", "body a1", Zero_Emb,
         Has_Session => False, Session_Id => "",
         Has_Created => True, Created_At => "2026-02-01T00:00:00+00:00",
         Surface => "", Surface_Label => "",
         Result => R1, Status => Stx);
      Memcp.Store.Save
        (S, "beta", "diary b1", "body b1", Zero_Emb,
         Has_Session => False, Session_Id => "",
         Has_Created => True, Created_At => "2026-02-02T00:00:00+00:00",
         Surface => "", Surface_Label => "",
         Result => R2, Status => Stx);
      Memcp.Store.Save
        (S, "alpha", "diary a2", "body a2", Zero_Emb,
         Has_Session => False, Session_Id => "",
         Has_Created => True, Created_At => "2026-02-03T00:00:00+00:00",
         Surface => "", Surface_Label => "",
         Result => R3, Status => Stx);

      --  No projects -> empty result, still Success.
      Memcp.Store.Recent_Diary (S, Empty, 10, Entries, RD_St);
      Check (RD_St = Memcp.Store.Success
             and then Memcp.Store.Diary_Vectors.Length (Entries) = 0,
             "Recent_Diary: no projects -> empty");

      --  Filter to "alpha": two rows, newest (a2) first.
      Memcp.Store.Name_Vectors.Append (Projs, (Len => 5, Value => "alpha"));
      Memcp.Store.Recent_Diary (S, Projs, 10, Entries, RD_St);
      Check (RD_St = Memcp.Store.Success
             and then Memcp.Store.Diary_Vectors.Length (Entries) = 2,
             "Recent_Diary: alpha -> 2 rows");
      if Memcp.Store.Diary_Vectors.Length (Entries) = 2 then
         declare
            E1 : constant Memcp.Store.Diary_Entry :=
              Memcp.Store.Diary_Vectors.Element (Entries, 1);
            E2 : constant Memcp.Store.Diary_Entry :=
              Memcp.Store.Diary_Vectors.Element (Entries, 2);
         begin
            Check (E1.Content = "diary a2" and then E2.Content = "diary a1",
                   "Recent_Diary: DESC order (a2 before a1)");
            Check (E1.Project = "alpha" and then not E1.Has_Session,
                   "Recent_Diary: project + null session carried");
            Check (E1.Headline = "body a2", "Recent_Diary: headline joined");
            Check (E1.Kind = "diary", "Recent_Diary: kind joined");
         end;
      end if;

      --  LIMIT: N=1 over both projects returns just the newest (a2).
      Memcp.Store.Name_Vectors.Append (Projs, (Len => 4, Value => "beta"));
      Memcp.Store.Recent_Diary (S, Projs, 1, Entries, RD_St);
      Check (RD_St = Memcp.Store.Success
             and then Memcp.Store.Diary_Vectors.Length (Entries) = 1
             and then Memcp.Store.Diary_Vectors.Element (Entries, 1).Content
                      = "diary a2",
             "Recent_Diary: LIMIT 1 -> newest across projects");
   end;

   ------------------------------------------------------------------
   --  List_Projects: every project with its diary count, newest first
   ------------------------------------------------------------------
   declare
      use type Memcp.Store.Project_Vectors.Capacity_Range;
      Projs : Memcp.Store.Project_Info_List;
      LP_St : Memcp.Store.Op_Status;
   begin
      --  Prior blocks left three projects: alpha (2 diary, newest 02-03),
      --  beta (1, 02-02), demo (1 session-scoped, 01-01). Ordered by newest
      --  activity DESC -> alpha, beta, demo.
      Memcp.Store.List_Projects (S, Projs, LP_St);
      Check (LP_St = Memcp.Store.Success
             and then Memcp.Store.Project_Vectors.Length (Projs) = 3,
             "List_Projects: three projects");
      if Memcp.Store.Project_Vectors.Length (Projs) = 3 then
         declare
            P1 : constant Memcp.Store.Project_Info :=
              Memcp.Store.Project_Vectors.Element (Projs, 1);
         begin
            Check (P1.Name = "alpha" and then P1.Diary_Count = 2,
                   "List_Projects: alpha first, count 2");
            Check (P1.Has_Latest
                   and then P1.Latest_At = "2026-02-03T00:00:00+00:00",
                   "List_Projects: latest_at carried");
         end;
      end if;
   end;

   ------------------------------------------------------------------
   --  Search_Summaries: KNN + Ada-side metadata filtering
   ------------------------------------------------------------------
   declare
      use type Memcp.Store.Summary_Hit_Vectors.Capacity_Range;
      use type Interfaces.IEEE_Float_64;

      Emb_A : Candle_Spark.Embedding := [others => 0.0];
      Emb_B : Candle_Spark.Embedding := [others => 0.0];
      Ra, Rb : Memcp.Store.Save_Result;
      Sv     : Memcp.Store.Op_Status;
      Projs  : Memcp.Store.Name_List;
      No_Filt : Memcp.Store.Name_List;
      Hits   : Memcp.Store.Summary_Hit_List;
      SS_St  : Memcp.Store.Op_Status;
   begin
      Emb_A (1) := 1.0;
      Emb_B (2) := 1.0;
      Memcp.Store.Save
        (S, "search", "diary sa", "summary sa", Emb_A,
         Has_Session => False, Session_Id => "",
         Has_Created => True, Created_At => "2026-03-01T00:00:00+00:00",
         Surface => "", Surface_Label => "",
         Result => Ra, Status => Sv);
      Memcp.Store.Save
        (S, "search", "diary sb", "summary sb", Emb_B,
         Has_Session => False, Session_Id => "",
         Has_Created => True, Created_At => "2026-03-02T00:00:00+00:00",
         Surface => "", Surface_Label => "",
         Result => Rb, Status => Sv);
      Memcp.Store.Name_Vectors.Append (Projs, (Len => 6, Value => "search"));

      --  Query near Emb_A: both hits, sa nearest (distance ~0 < sb).
      Memcp.Store.Search_Summaries
        (S, Emb_A, Projs, 5, Has_Since => False, Since => "",
         Has_Until => False, Until_At => "", Result => Hits, Status => SS_St);
      Check (SS_St = Memcp.Store.Success
             and then Memcp.Store.Summary_Hit_Vectors.Length (Hits) = 2,
             "Search_Summaries: project filter -> 2 hits");
      if Memcp.Store.Summary_Hit_Vectors.Length (Hits) = 2 then
         declare
            H1 : constant Memcp.Store.Summary_Hit :=
              Memcp.Store.Summary_Hit_Vectors.Element (Hits, 1);
            H2 : constant Memcp.Store.Summary_Hit :=
              Memcp.Store.Summary_Hit_Vectors.Element (Hits, 2);
         begin
            Check (H1.Content = "summary sa", "Search_Summaries: nearest first");
            Check (H1.Distance < H2.Distance,
                   "Search_Summaries: ascending distance");
         end;
      end if;

      --  limit 1 -> just the nearest.
      Memcp.Store.Search_Summaries
        (S, Emb_A, Projs, 1, Has_Since => False, Since => "",
         Has_Until => False, Until_At => "", Result => Hits, Status => SS_St);
      Check (SS_St = Memcp.Store.Success
             and then Memcp.Store.Summary_Hit_Vectors.Length (Hits) = 1
             and then Memcp.Store.Summary_Hit_Vectors.Element (Hits, 1).Content
                      = "summary sa",
             "Search_Summaries: limit 1 -> nearest only");

      --  No project filter, limit 1: sa (distance 0) is the global nearest.
      Memcp.Store.Search_Summaries
        (S, Emb_A, No_Filt, 1, Has_Since => False, Since => "",
         Has_Until => False, Until_At => "", Result => Hits, Status => SS_St);
      Check (SS_St = Memcp.Store.Success
             and then Memcp.Store.Summary_Hit_Vectors.Length (Hits) = 1
             and then Memcp.Store.Summary_Hit_Vectors.Element (Hits, 1).Content
                      = "summary sa",
             "Search_Summaries: no filter -> global nearest");

      --  Until before both search rows -> filtered out entirely.
      Memcp.Store.Search_Summaries
        (S, Emb_A, Projs, 5, Has_Since => False, Since => "",
         Has_Until => True, Until_At => "2026-01-01T00:00:00+00:00",
         Result => Hits, Status => SS_St);
      Check (SS_St = Memcp.Store.Success
             and then Memcp.Store.Summary_Hit_Vectors.Length (Hits) = 0,
             "Search_Summaries: until-window excludes all");

      --  Since = sb's timestamp -> only sb passes.
      Memcp.Store.Search_Summaries
        (S, Emb_A, Projs, 5, Has_Since => True,
         Since => "2026-03-02T00:00:00+00:00",
         Has_Until => False, Until_At => "", Result => Hits, Status => SS_St);
      Check (SS_St = Memcp.Store.Success
             and then Memcp.Store.Summary_Hit_Vectors.Length (Hits) = 1
             and then Memcp.Store.Summary_Hit_Vectors.Element (Hits, 1).Content
                      = "summary sb",
             "Search_Summaries: since-window keeps only newer");
   end;

   ------------------------------------------------------------------
   --  Search_Chunks: no chunk rows yet -> empty, but every filter path runs
   ------------------------------------------------------------------
   declare
      use type Memcp.Store.Chunk_Hit_Vectors.Capacity_Range;
      Q       : constant Candle_Spark.Embedding := [others => 0.0];
      Projs   : Memcp.Store.Name_List;
      Sess    : Memcp.Store.Name_List;
      Hits    : Memcp.Store.Chunk_Hit_List;
      SC_St   : Memcp.Store.Op_Status;
   begin
      Memcp.Store.Name_Vectors.Append (Projs, (Len => 6, Value => "search"));
      Memcp.Store.Name_Vectors.Append (Sess, (Len => 4, Value => "sess"));
      Memcp.Store.Search_Chunks
        (S, Q, Projs, Sess, 5, Has_Since => True,
         Since => "2020-01-01T00:00:00+00:00", Has_Until => True,
         Until_At => "2030-01-01T00:00:00+00:00", Result => Hits,
         Status => SC_St);
      Check (SC_St = Memcp.Store.Success
             and then Memcp.Store.Chunk_Hit_Vectors.Length (Hits) = 0,
             "Search_Chunks: all filters, empty table -> empty");
   end;

   ------------------------------------------------------------------
   --  Fetch_Turns with no session rows: every filter branch must still build
   --  valid SQL and return empty + Success.
   ------------------------------------------------------------------
   declare
      use type Memcp.Store.Chunk_Vectors.Capacity_Range;
      Turns : Memcp.Store.Chunk_List;
      FT_St : Memcp.Store.Op_Status;

      procedure Expect_Empty (Label : String);
      --  Check that the preceding Fetch_Turns returned Success and no rows.

      procedure Expect_Empty (Label : String) is
      begin
         Check (FT_St = Memcp.Store.Success
                and then Memcp.Store.Chunk_Vectors.Length (Turns) = 0, Label);
      end Expect_Empty;
   begin
      Memcp.Store.Fetch_Turns
        (S, "no-such", Has_Project => False, Project => "",
         Has_Start => False, Start_Ord => 0, Has_End => False, End_Ord => 0,
         Has_Tail => False, Tail => 1, Result => Turns, Status => FT_St);
      Expect_Empty ("Fetch_Turns: plain, unknown session -> empty");

      Memcp.Store.Fetch_Turns
        (S, "no-such", Has_Project => True, Project => "alpha",
         Has_Start => False, Start_Ord => 0, Has_End => False, End_Ord => 0,
         Has_Tail => False, Tail => 1, Result => Turns, Status => FT_St);
      Expect_Empty ("Fetch_Turns: +project filter -> empty");

      Memcp.Store.Fetch_Turns
        (S, "no-such", Has_Project => False, Project => "",
         Has_Start => True, Start_Ord => 2, Has_End => True, End_Ord => 5,
         Has_Tail => False, Tail => 1, Result => Turns, Status => FT_St);
      Expect_Empty ("Fetch_Turns: +[start,end) window -> empty");

      Memcp.Store.Fetch_Turns
        (S, "no-such", Has_Project => False, Project => "",
         Has_Start => False, Start_Ord => 0, Has_End => False, End_Ord => 0,
         Has_Tail => True, Tail => 3, Result => Turns, Status => FT_St);
      Expect_Empty ("Fetch_Turns: +tail (subquery form) -> empty");
   end;

   ------------------------------------------------------------------
   --  Save_Session on the :memory: store: chunks land, raw_path is skipped,
   --  Fetch_Turns and Search_Chunks read real rows, and a retry is idempotent.
   ------------------------------------------------------------------
   declare
      use type Memcp.Store.Chunk_Vectors.Capacity_Range;
      Sess_TS : constant String := "2026-05-01T00:00:00+00:00";
      CL   : Memcp.Store.Chunk_Input_List;
      R    : Memcp.Store.Session_Save_Result;
      St   : Memcp.Store.Op_Status;
   begin
      Memcp.Store.Chunk_Input_Vectors.Append
        (CL, (Body_Len => 6, Content => "turn 0", Embedding => Hot (1)));
      Memcp.Store.Chunk_Input_Vectors.Append
        (CL, (Body_Len => 6, Content => "turn 1", Embedding => Hot (2)));
      Memcp.Store.Chunk_Input_Vectors.Append
        (CL, (Body_Len => 6, Content => "turn 2", Embedding => Hot (3)));

      Memcp.Store.Save_Session
        (S, "sessapp", "se-1", "raw transcript body", CL,
         Surface => "", Surface_Label => "",
         Has_Created => True, Created_At => Sess_TS, Result => R, Status => St);
      Check (St = Memcp.Store.Success and then not R.Already_Existed
             and then R.Chunk_Count = 3 and then R.Session_Row_Id > 0,
             "Save_Session: fresh, 3 chunks");
      Check (not R.Raw_Path_Set,
             "Save_Session: :memory: writes no transcript file");

      --  Fetch_Turns returns real rows, ascending ordinal.
      declare
         Turns : Memcp.Store.Chunk_List;
         FT_St : Memcp.Store.Op_Status;
      begin
         Memcp.Store.Fetch_Turns
           (S, "se-1", Has_Project => False, Project => "",
            Has_Start => False, Start_Ord => 0, Has_End => False, End_Ord => 0,
            Has_Tail => False, Tail => 1, Result => Turns, Status => FT_St);
         Check (FT_St = Memcp.Store.Success
                and then Memcp.Store.Chunk_Vectors.Length (Turns) = 3,
                "Fetch_Turns: session has 3 turns");
         if Memcp.Store.Chunk_Vectors.Length (Turns) = 3 then
            declare
               T0 : constant Memcp.Store.Chunk :=
                 Memcp.Store.Chunk_Vectors.Element (Turns, 1);
               T2 : constant Memcp.Store.Chunk :=
                 Memcp.Store.Chunk_Vectors.Element (Turns, 3);
            begin
               Check (T0.Content = "turn 0" and then T0.Ordinal = 0,
                      "Fetch_Turns: first turn ordinal 0");
               Check (T2.Content = "turn 2" and then T2.Ordinal = 2,
                      "Fetch_Turns: last turn ordinal 2");
               Check (T0.Created_At = Sess_TS,
                      "Fetch_Turns: chunk inherits session created_at");
            end;
         end if;

         --  tail = 1 -> just the last turn, still ascending.
         Memcp.Store.Fetch_Turns
           (S, "se-1", Has_Project => True, Project => "sessapp",
            Has_Start => False, Start_Ord => 0, Has_End => False, End_Ord => 0,
            Has_Tail => True, Tail => 1, Result => Turns, Status => FT_St);
         Check (FT_St = Memcp.Store.Success
                and then Memcp.Store.Chunk_Vectors.Length (Turns) = 1
                and then Memcp.Store.Chunk_Vectors.Element (Turns, 1).Content
                         = "turn 2",
                "Fetch_Turns: tail 1 -> last turn");

         --  [start, end) window -> ordinals 1 and 2.
         Memcp.Store.Fetch_Turns
           (S, "se-1", Has_Project => False, Project => "",
            Has_Start => True, Start_Ord => 1, Has_End => True, End_Ord => 3,
            Has_Tail => False, Tail => 1, Result => Turns, Status => FT_St);
         Check (FT_St = Memcp.Store.Success
                and then Memcp.Store.Chunk_Vectors.Length (Turns) = 2
                and then Memcp.Store.Chunk_Vectors.Element (Turns, 1).Ordinal = 1,
                "Fetch_Turns: [1,3) window -> 2 turns from ordinal 1");

         --  Every filter at once: the maximal query, end to end. The positions
         --  themselves are proved in the body, so what is left here is that
         --  each filter's value reaches the placeholder meant for it.
         Memcp.Store.Fetch_Turns
           (S, "se-1", Has_Project => True, Project => "sessapp",
            Has_Start => True, Start_Ord => 0, Has_End => True, End_Ord => 3,
            Has_Tail => True, Tail => 2, Result => Turns, Status => FT_St);
         Check (FT_St = Memcp.Store.Success
                and then Memcp.Store.Chunk_Vectors.Length (Turns) = 2
                and then Memcp.Store.Chunk_Vectors.Element (Turns, 1).Ordinal = 1
                and then Memcp.Store.Chunk_Vectors.Element (Turns, 2).Ordinal = 2,
                "Fetch_Turns: all filters -> tail 2 of [0,3)");
      end;

      --  Search_Chunks over real chunk rows: nearest to Hot(1) is turn 0.
      declare
         Projs : Memcp.Store.Name_List;
         Hits  : Memcp.Store.Chunk_Hit_List;
         SC_St : Memcp.Store.Op_Status;
      begin
         Memcp.Store.Name_Vectors.Append
           (Projs, (Len => 7, Value => "sessapp"));
         Memcp.Store.Search_Chunks
           (S, Hot (1), Projs, Memcp.Store.Name_Vectors.Empty_Vector, 5,
            Has_Since => False, Since => "", Has_Until => False, Until_At => "",
            Result => Hits, Status => SC_St);
         Check (SC_St = Memcp.Store.Success
                and then Memcp.Store.Chunk_Hit_Vectors.Length (Hits) = 3,
                "Search_Chunks: project filter -> 3 hits");
         if Memcp.Store.Chunk_Hit_Vectors.Length (Hits) = 3 then
            Check (Memcp.Store.Chunk_Hit_Vectors.Element (Hits, 1).Content
                   = "turn 0"
                   and then Memcp.Store.Chunk_Hit_Vectors.Element (Hits, 1)
                              .Session = "se-1",
                   "Search_Chunks: nearest is turn 0, session carried");
         end if;
      end;

      --  Idempotent retry: same session -> Already_Existed, count preserved.
      declare
         R2 : Memcp.Store.Session_Save_Result;
         St2 : Memcp.Store.Op_Status;
      begin
         Memcp.Store.Save_Session
           (S, "sessapp", "se-1", "different transcript", CL,
            Has_Created => True, Created_At => Sess_TS,
            Surface => "", Surface_Label => "",
            Result => R2, Status => St2);
         Check (St2 = Memcp.Store.Success and then R2.Already_Existed
                and then R2.Chunk_Count = 3
                and then R2.Session_Row_Id = R.Session_Row_Id,
                "Save_Session: idempotent retry, no re-insert");
      end;
   end;

   ------------------------------------------------------------------
   --  Save_Autorecap: writes when no Header exists, then short-circuits.
   ------------------------------------------------------------------
   declare
      Rec : Memcp.Store.Autorecap_Result;
      St  : Memcp.Store.Op_Status;
   begin
      --  se-1 has chunks but no summary yet -> autorecap is written.
      Memcp.Store.Save_Autorecap
        (S, "sessapp", "se-1", "session recap line", Hot (5),
         Has_Created => True, Created_At => TS,
         Surface => "", Surface_Label => "",
         Result => Rec, Status => St);
      Check (St = Memcp.Store.Success and then Rec.Written
             and then Rec.Summary_Id > 0 and then Rec.Diary_Id > 0,
             "Save_Autorecap: fresh -> written");

      declare
         P   : Memcp.Store.Summary_Ptr;
         St2 : Memcp.Store.Op_Status;
      begin
         Memcp.Store.Fetch_Summary (S, Rec.Summary_Id, P, St2);
         Check (St2 = Memcp.Store.Success and then P /= null
                and then P.Kind = "autorecap"
                and then P.Content = "session recap line"
                and then P.Headline = "session recap line"
                and then P.Has_Session and then P.Session = "se-1",
                "Save_Autorecap: summary kind/body/headline/session");
         if P /= null then
            Memcp.Store.Free (P);
         end if;
      end;

      --  Second call finds an existing Header -> short-circuit, no write.
      Memcp.Store.Save_Autorecap
        (S, "sessapp", "se-1", "a different recap", Hot (5),
         Has_Created => True, Created_At => TS,
         Surface => "", Surface_Label => "",
         Result => Rec, Status => St);
      Check (St = Memcp.Store.Success and then not Rec.Written,
             "Save_Autorecap: existing Header -> not written");

      --  A real Save for a session must also block a later autorecap.
      declare
         R  : Memcp.Store.Save_Result;
         Sv : Memcp.Store.Op_Status;
      begin
         Memcp.Store.Save
           (S, "sessapp", "diary for se-2", "summary for se-2", Zero_Emb,
            Has_Session => True, Session_Id => "se-2",
            Surface => "", Surface_Label => "",
            Has_Created => True, Created_At => TS, Result => R, Status => Sv);
         Memcp.Store.Save_Autorecap
           (S, "sessapp", "se-2", "recap for se-2", Hot (6),
            Has_Created => True, Created_At => TS,
            Surface => "", Surface_Label => "",
            Result => Rec, Status => St);
         Check (St = Memcp.Store.Success and then not Rec.Written,
                "Save_Autorecap: real save() takes precedence");
      end;
   end;

   ------------------------------------------------------------------
   --  Reindex_Session: replace a session's chunks in place.
   ------------------------------------------------------------------
   declare
      use type Memcp.Store.Chunk_Vectors.Capacity_Range;
      NL    : Memcp.Store.Chunk_Input_List;
      Found : Boolean;
      Old_C, New_C : Natural;
      St    : Memcp.Store.Op_Status;
   begin
      Memcp.Store.Chunk_Input_Vectors.Append
        (NL, (Body_Len => 10, Content => "new turn A", Embedding => Hot (1)));
      Memcp.Store.Chunk_Input_Vectors.Append
        (NL, (Body_Len => 10, Content => "new turn B", Embedding => Hot (2)));

      Memcp.Store.Reindex_Session
        (S, "sessapp", "se-1", NL, Found => Found,
         Old_Count => Old_C, New_Count => New_C, Status => St);
      Check (St = Memcp.Store.Success and then Found
             and then Old_C = 3 and then New_C = 2,
             "Reindex_Session: 3 old chunks -> 2 new");

      declare
         Turns : Memcp.Store.Chunk_List;
         FT_St : Memcp.Store.Op_Status;
      begin
         Memcp.Store.Fetch_Turns
           (S, "se-1", Has_Project => False, Project => "",
            Has_Start => False, Start_Ord => 0, Has_End => False, End_Ord => 0,
            Has_Tail => False, Tail => 1, Result => Turns, Status => FT_St);
         Check (FT_St = Memcp.Store.Success
                and then Memcp.Store.Chunk_Vectors.Length (Turns) = 2
                and then Memcp.Store.Chunk_Vectors.Element (Turns, 1).Content
                         = "new turn A"
                and then Memcp.Store.Chunk_Vectors.Element (Turns, 1).Created_At
                         = "2026-05-01T00:00:00+00:00",
                "Reindex_Session: new turns replace old, created_at preserved");
      end;

      --  Unknown session -> Found False, Success.
      Memcp.Store.Reindex_Session
        (S, "sessapp", "no-such-session", NL, Found => Found,
         Old_Count => Old_C, New_Count => New_C, Status => St);
      Check (St = Memcp.Store.Success and then not Found,
             "Reindex_Session: unknown session -> not found");
   end;

   Memcp.Store.Close (S);
   Check (not Memcp.Store.Is_Open (S), "Close -> not open");

   ------------------------------------------------------------------
   --  On-disk transcript path: a file-backed store writes the raw jsonl.
   ------------------------------------------------------------------
   declare
      Tmp : constant String :=
        (if Ada.Environment_Variables.Exists ("TMPDIR")
         then Ada.Environment_Variables.Value ("TMPDIR")
         else "/tmp");
      Base : constant String :=
        (if Tmp'Length > 0 and then Tmp (Tmp'Last) = '/'
         then Tmp else Tmp & "/") & "memcp_store_test";
      DB_File : constant String := Base & "/store.db";
      FS      : Memcp.Store.Store;
      Open_FS : Memcp.Store.Open_Status;
   begin
      if Ada.Directories.Exists (Base) then
         Ada.Directories.Delete_Tree (Base);
      end if;
      Ada.Directories.Create_Path (Base);

      Memcp.Store.Open (FS, DB_File, Open_FS);
      Check (Open_FS = Memcp.Store.Opened, "Open file-backed store");

      if Open_FS = Memcp.Store.Opened then
         declare
            CL : Memcp.Store.Chunk_Input_List;
            R  : Memcp.Store.Session_Save_Result;
            St : Memcp.Store.Op_Status;
            Expect_Path : constant String :=
              Base & "/sessions/fileproj/fs-1.jsonl";
         begin
            Memcp.Store.Chunk_Input_Vectors.Append
              (CL, (Body_Len => 4, Content => "only", Embedding => Hot (1)));
            Memcp.Store.Save_Session
              (FS, "fileproj", "fs-1", "hello transcript", CL,
               Has_Created => True, Created_At => TS,
               Surface => "", Surface_Label => "",
               Result => R, Status => St);
            Check (St = Memcp.Store.Success and then not R.Already_Existed
                   and then R.Raw_Path_Set,
                   "Save_Session: file-backed -> raw_path written");
            Check (Ada.Directories.Exists (Expect_Path),
                   "Save_Session: transcript file exists on disk");
            if Ada.Directories.Exists (Expect_Path) then
               Check (Read_File (Expect_Path) = "hello transcript",
                      "Save_Session: transcript bytes match");
            end if;
         end;
         Memcp.Store.Close (FS);
      end if;

      if Ada.Directories.Exists (Base) then
         Ada.Directories.Delete_Tree (Base);
      end if;
   end;

   ------------------------------------------------------------------
   --  Surface provenance, and the migration that adds it to a database
   --  written before it existed. Both are asserted with raw SQL: the Store
   --  writes provenance but exposes no read for it yet.
   ------------------------------------------------------------------
   declare
      Tmp : constant String :=
        (if Ada.Environment_Variables.Exists ("TMPDIR")
         then Ada.Environment_Variables.Value ("TMPDIR")
         else "/tmp");
      Base : constant String :=
        (if Tmp'Length > 0 and then Tmp (Tmp'Last) = '/'
         then Tmp else Tmp & "/") & "memcp_surface_test";
      DB_File : constant String := Base & "/store.db";


      procedure Exec_Raw (Path, Query : String);
      --  Run a resultless statement against the database at Path.

      procedure Exec_Raw (Path, Query : String) is
         DB : Sqlite_Vec_Spark.Database;
         St : Sqlite_Vec_Spark.Status;
      begin
         Sqlite_Vec_Spark.Open (DB, Path, St);
         if St = Sqlite_Vec_Spark.Ok then
            Sqlite_Vec_Spark.Execute (DB, Query, St);
            Check (St = Sqlite_Vec_Spark.Ok, "fixture SQL accepted");
            Sqlite_Vec_Spark.Close (DB);
         else
            Check (False, "fixture database opened");
         end if;
      end Exec_Raw;
   begin
      if Ada.Directories.Exists (Base) then
         Ada.Directories.Delete_Tree (Base);
      end if;
      Ada.Directories.Create_Path (Base);

      --  ---- a pre-provenance database, migrated in place ----
      --  Only the tables the migration touches, shaped as they were before
      --  surface_row_id existed, carrying one row each.
      Exec_Raw
        (DB_File,
         "CREATE TABLE projects (id INTEGER PRIMARY KEY,"
         & " name TEXT NOT NULL UNIQUE);"
         & "CREATE TABLE summaries (id INTEGER PRIMARY KEY,"
         & " project_id INTEGER NOT NULL REFERENCES projects(id),"
         & " session_id TEXT, created_at TEXT NOT NULL,"
         & " headline TEXT NOT NULL, body TEXT NOT NULL,"
         & " dedup_hash TEXT, kind TEXT NOT NULL DEFAULT 'diary');"
         & "CREATE TABLE sessions (id INTEGER PRIMARY KEY,"
         & " project_id INTEGER NOT NULL REFERENCES projects(id),"
         & " session_id TEXT NOT NULL, created_at TEXT NOT NULL,"
         & " raw_path TEXT, UNIQUE (project_id, session_id));"
         & "INSERT INTO projects (id, name) VALUES (1, 'old');"
         & "INSERT INTO summaries (id, project_id, session_id, created_at,"
         & " headline, body, dedup_hash, kind)"
         & " VALUES (1, 1, 'old-1', '2026-01-01T00:00:00+00:00',"
         & " 'old head', 'old body', 'oldhash', 'diary');"
         & "INSERT INTO sessions (id, project_id, session_id, created_at,"
         & " raw_path) VALUES (1, 1, 'old-1', '2026-01-01T00:00:00+00:00',"
         & " '/old/path.jsonl');");

      declare
         MS      : Memcp.Store.Store;
         Open_MS : Memcp.Store.Open_Status;
      begin
         Memcp.Store.Open (MS, DB_File, Open_MS);
         Check (Open_MS = Memcp.Store.Opened,
                "Migration: pre-provenance database still opens");
         if Open_MS = Memcp.Store.Opened then
            Memcp.Store.Close (MS);
         end if;
      end;

      Check (Scalar (DB_File, "SELECT count(*) FROM summaries") = "1"
             and then Scalar (DB_File, "SELECT count(*) FROM sessions") = "1",
             "Migration: no row lost");
      Check (Scalar
               (DB_File,
                "SELECT headline || '|' || body || '|' || dedup_hash"
                & " || '|' || kind || '|' || created_at || '|' || session_id"
                & " FROM summaries WHERE id = 1")
             = "old head|old body|oldhash|diary|"
               & "2026-01-01T00:00:00+00:00|old-1",
             "Migration: the pre-existing summary reads back unchanged");
      Check (Scalar (DB_File, "SELECT raw_path FROM sessions WHERE id = 1")
             = "/old/path.jsonl",
             "Migration: the pre-existing session reads back unchanged");
      Check (Scalar
               (DB_File, "SELECT surface_row_id FROM summaries WHERE id = 1")
             = "<null>"
             and then Scalar
               (DB_File, "SELECT surface_row_id FROM sessions WHERE id = 1")
             = "<null>",
             "Migration: pre-existing rows migrate with null provenance");

      --  ---- writes from a surface, into the same migrated database ----
      declare
         MS      : Memcp.Store.Store;
         Open_MS : Memcp.Store.Open_Status;
         SR      : Memcp.Store.Save_Result;
         SeR     : Memcp.Store.Session_Save_Result;
         St      : Memcp.Store.Op_Status;
         CL      : Memcp.Store.Chunk_Input_List;
      begin
         Memcp.Store.Open (MS, DB_File, Open_MS);
         Check (Open_MS = Memcp.Store.Opened,
                "Migration: re-opening a migrated database is a no-op");
         if Open_MS = Memcp.Store.Opened then
            Memcp.Store.Save
              (MS, "prov", "attributed diary", "attributed body", Zero_Emb,
               Has_Session => True, Session_Id => "p-1",
               Has_Created => True, Created_At => TS,
               Surface => "11111111-2222-3333-4444-555555555555",
               Surface_Label => "laptop",
               Result => SR, Status => St);
            Check (St = Memcp.Store.Success, "Provenance: save -> Success");

            Memcp.Store.Chunk_Input_Vectors.Append
              (CL, (Body_Len => 4, Content => "turn", Embedding => Hot (1)));
            Memcp.Store.Save_Session
              (MS, "prov", "p-1", "transcript", CL,
               Has_Created => True, Created_At => TS,
               Surface => "11111111-2222-3333-4444-555555555555",
               Surface_Label => "laptop",
               Result => SeR, Status => St);
            Check (St = Memcp.Store.Success,
                   "Provenance: session upload -> Success");

            --  An unattributed write lands beside them, with no surface.
            Memcp.Store.Save
              (MS, "prov", "anon diary", "anon body", Zero_Emb,
               Has_Session => True, Session_Id => "p-2",
               Has_Created => True, Created_At => TS,
               Surface => "", Surface_Label => "",
               Result => SR, Status => St);
            Check (St = Memcp.Store.Success,
                   "Provenance: unattributed save still succeeds");
            Memcp.Store.Close (MS);
         end if;
      end;

      Check (Scalar (DB_File, "SELECT count(*) FROM surfaces") = "1",
             "Provenance: both writes share one surfaces row");
      Check (Scalar
               (DB_File,
                "SELECT s.label FROM surfaces s JOIN summaries m"
                & " ON m.surface_row_id = s.id WHERE m.session_id = 'p-1'")
             = "laptop",
             "Provenance: the summary carries the writing surface");
      Check (Scalar
               (DB_File,
                "SELECT s.surface_id FROM surfaces s JOIN sessions x"
                & " ON x.surface_row_id = s.id WHERE x.session_id = 'p-1'")
             = "11111111-2222-3333-4444-555555555555",
             "Provenance: the session carries the uploading surface");
      Check (Scalar
               (DB_File,
                "SELECT surface_row_id FROM summaries"
                & " WHERE session_id = 'p-2'")
             = "<null>",
             "Provenance: an unattributed write stays null");

      if Ada.Directories.Exists (Base) then
         Ada.Directories.Delete_Tree (Base);
      end if;
   end;

   --  Degraded surfaces: a summary whose session never had a transcript
   --  uploaded is what a stopped SessionEnd hook looks like from the corpus.
   declare
      Tmp : constant String :=
        (if Ada.Environment_Variables.Exists ("TMPDIR")
         then Ada.Environment_Variables.Value ("TMPDIR")
         else "/tmp");
      Base : constant String :=
        (if Tmp'Length > 0 and then Tmp (Tmp'Last) = '/'
         then Tmp else Tmp & "/") & "memcp_health_test";
      DB_File : constant String := Base & "/store.db";

      HS      : Memcp.Store.Store;
      Open_HS : Memcp.Store.Open_Status;
      St      : Memcp.Store.Op_Status;
      Found   : Memcp.Store.Surface_Health_List;

      procedure Saved
        (Session, Surface, Label, At_Time : String; Uploaded : Boolean);
      --  A session on Surface that saved a summary, and uploaded a transcript
      --  only when Uploaded. An empty Surface is the write no hook attributed.

      procedure Saved
        (Session, Surface, Label, At_Time : String; Uploaded : Boolean)
      is
         SR  : Memcp.Store.Save_Result;
         SeR : Memcp.Store.Session_Save_Result;
         CL  : Memcp.Store.Chunk_Input_List;
         Ok  : Memcp.Store.Op_Status;
      begin
         Memcp.Store.Save
           (HS, "health", "d " & Session, "b " & Session, Zero_Emb,
            Has_Session => True, Session_Id => Session,
            Has_Created => True, Created_At => At_Time,
            Surface => Surface, Surface_Label => Label,
            Result => SR, Status => Ok);
         Check (Ok = Memcp.Store.Success, "Health: save " & Session);
         if Uploaded then
            Memcp.Store.Chunk_Input_Vectors.Append
              (CL, (Body_Len => 4, Content => "turn", Embedding => Zero_Emb));
            Memcp.Store.Save_Session
              (HS, "health", Session, "transcript", CL,
               Has_Created => True, Created_At => At_Time,
               Surface => Surface, Surface_Label => Label,
               Result => SeR, Status => Ok);
            Check (Ok = Memcp.Store.Success, "Health: upload " & Session);
         end if;
      end Saved;

      function Reported (Label : String) return Boolean;
      --  Whether the last query named the surface Label, "" for the group it
      --  could not attribute.

      function Reported (Label : String) return Boolean is
         package V renames Memcp.Store.Surface_Health_Vectors;
      begin
         for I in V.First_Index (Found) .. V.Last_Index (Found) loop
            declare
               E : constant Memcp.Store.Surface_Health :=
                 V.Element (Found, I);
            begin
               if (if Label = "" then not E.Attributed
                   else E.Attributed and then E.Label = Label)
               then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Reported;

      function Missing (Label : String) return Memcp.Store.Row_Id;
      --  How many of Label's counted sessions had no transcript; 0 when the
      --  query did not report it at all.

      function Missing (Label : String) return Memcp.Store.Row_Id is
         package V renames Memcp.Store.Surface_Health_Vectors;
      begin
         for I in V.First_Index (Found) .. V.Last_Index (Found) loop
            declare
               E : constant Memcp.Store.Surface_Health :=
                 V.Element (Found, I);
            begin
               if E.Attributed and then E.Label = Label then
                  return E.Missing;
               end if;
            end;
         end loop;
         return 0;
      end Missing;

      function Uploaded (Label : String) return String;
      --  The newest transcript time the last query reports for Label, "" when
      --  it reports none or does not name Label at all.

      function Uploaded (Label : String) return String is
         package V renames Memcp.Store.Surface_Health_Vectors;
      begin
         for I in V.First_Index (Found) .. V.Last_Index (Found) loop
            declare
               E : constant Memcp.Store.Surface_Health :=
                 V.Element (Found, I);
            begin
               if E.Attributed and then E.Label = Label then
                  return E.Last_Uploaded;
               end if;
            end;
         end loop;
         return "";
      end Uploaded;
   begin
      if Ada.Directories.Exists (Base) then
         Ada.Directories.Delete_Tree (Base);
      end if;
      Ada.Directories.Create_Path (Base);

      Memcp.Store.Open (HS, DB_File, Open_HS);
      Check (Open_HS = Memcp.Store.Opened, "Health: open store");

      if Open_HS = Memcp.Store.Opened then
         --  Degraded: saves, no uploads.
         Saved ("d-1", "uuid-a", "boxa", "2026-08-01T09:00:00Z", False);
         Saved ("d-2", "uuid-a", "boxa", "2026-08-02T09:00:00Z", False);
         Saved ("d-3", "uuid-a", "boxa", "2026-08-03T09:00:00Z", False);

         --  Healthy: every save followed by its upload.
         Saved ("h-1", "uuid-b", "boxb", "2026-08-01T09:00:00Z", True);
         Saved ("h-2", "uuid-b", "boxb", "2026-08-02T09:00:00Z", True);
         Saved ("h-3", "uuid-b", "boxb", "2026-08-03T09:00:00Z", True);

         --  Below the threshold: two gaps, not three.
         Saved ("q-1", "uuid-c", "boxc", "2026-08-01T09:00:00Z", False);
         Saved ("q-2", "uuid-c", "boxc", "2026-08-02T09:00:00Z", False);

         --  No surface at all: countable, not nameable.
         Saved ("u-1", "", "", "2026-08-01T09:00:00Z", False);
         Saved ("u-2", "", "", "2026-08-02T09:00:00Z", False);
         Saved ("u-3", "", "", "2026-08-03T09:00:00Z", False);

         Memcp.Store.Degraded_Surfaces
           (HS, Memcp.Store.Health_Window, Memcp.Store.Health_Threshold,
            Found, St);
         Check (St = Memcp.Store.Success, "Health: query -> Success");
         Check (Reported ("boxa"), "Health: a surface that stopped uploading");
         Check (not Reported ("boxb"), "Health: a healthy surface is silent");
         Check (not Reported ("boxc"), "Health: below the threshold is silent");
         Check (Reported (""), "Health: unattributed sessions are counted");

         --  The upsert the metric rests on: one session that saves five times
         --  is one session, not five, so it cannot push a surface over on its
         --  own.
         for K in 1 .. 5 loop
            Saved ("q-3", "uuid-c", "boxc", "2026-08-04T09:00:00Z", False);
         end loop;
         Memcp.Store.Degraded_Surfaces
           (HS, Memcp.Store.Health_Window, Memcp.Store.Health_Threshold,
            Found, St);
         Check (Missing ("boxc") = 3,
                "Health: repeated saves in one session count once");

         --  The window is a lookback bound: with only the two newest sessions
         --  weighed, a surface whose gaps have aged out falls silent.
         Memcp.Store.Degraded_Surfaces (HS, 2, 3, Found, St);
         Check (St = Memcp.Store.Success, "Health: narrow window -> Success");
         Check (not Reported ("boxa"),
                "Health: gaps outside the window are not counted");

         --  A surface that has only ever read is known, and has no sessions to
         --  report on.
         Memcp.Store.Touch_Surface
           (HS, "uuid-d", "boxd", "0.6.0", "boxd", "boxd", St);
         Check (St = Memcp.Store.Success, "Health: check-in -> Success");
         Memcp.Store.Degraded_Surfaces
           (HS, Memcp.Store.Health_Window, Memcp.Store.Health_Threshold,
            Found, St);
         Check (not Reported ("boxd"),
                "Health: a surface that only checked in is silent");

         --  A caller that knows less than the last one erases nothing: only
         --  the label and last_seen are unconditional.
         Memcp.Store.Touch_Surface (HS, "uuid-d", "boxd", "", "", "", St);
         Check (St = Memcp.Store.Success, "Health: bare check-in -> Success");

         --  The roster is the same window read without the threshold, so
         --  everything the metric hides is in it.
         Memcp.Store.Fleet_Health
           (HS, Memcp.Store.Health_Window, Found, St);
         Check (St = Memcp.Store.Success, "Fleet: query -> Success");
         Check (Reported ("boxa"), "Fleet: a degraded surface");
         Check (Reported ("boxb"), "Fleet: a healthy surface too");
         Check (Reported ("boxc"), "Fleet: one below the threshold too");
         Check (Reported ("boxd"), "Fleet: one that has only checked in");
         Check (Reported (""), "Fleet: the unattributed group");
         Check (Missing ("boxb") = 0, "Fleet: a healthy surface has no gap");
         Check (Uploaded ("boxb") = "2026-08-03T09:00:00Z",
                "Fleet: the newest transcript per surface");
         Check (Uploaded ("boxa") = "",
                "Fleet: a surface that never uploaded reports none");

         Memcp.Store.Close (HS);
      end if;

      Check (Scalar (DB_File, "SELECT label FROM surfaces"
                     & " WHERE surface_id = 'uuid-d'") = "boxd",
             "Health: the check-in recorded the surface");
      Check (Scalar (DB_File, "SELECT hook_version FROM surfaces"
                     & " WHERE surface_id = 'uuid-d'") = "0.6.0",
             "Health: the check-in recorded the hook version");
      Check (Scalar (DB_File, "SELECT install_host FROM surfaces"
                     & " WHERE surface_id = 'uuid-d'") = "boxd",
             "Health: a later bare check-in kept it");
      Check (Scalar (DB_File, "SELECT count(*) FROM surfaces"
                     & " WHERE surface_id = 'uuid-a'"
                     & " AND hook_version IS NULL") = "1",
             "Health: a surface that never reported one has none");
      Check (Scalar (DB_File, "SELECT count(*) FROM summaries"
                     & " WHERE session_id = 'q-3'") = "1",
             "Health: five saves left one summary row");

      if Ada.Directories.Exists (Base) then
         Ada.Directories.Delete_Tree (Base);
      end if;
   end;

   ------------------------------------------------------------------
   --  The failure paths. A second connection drops a table out from under an
   --  open store: nothing the Store's own API accepts can make a statement
   --  fail, so Db_Error is otherwise unreachable from a test. Each case
   --  asserts both halves -- that the failure is reported rather than
   --  swallowed, and that a transaction interrupted part-way left the rows it
   --  had already touched alone.
   ------------------------------------------------------------------
   declare
      Tmp : constant String :=
        (if Ada.Environment_Variables.Exists ("TMPDIR")
         then Ada.Environment_Variables.Value ("TMPDIR")
         else "/tmp");
      Base : constant String :=
        (if Tmp'Length > 0 and then Tmp (Tmp'Last) = '/'
         then Tmp else Tmp & "/") & "memcp_fault_test";
      Meta_DB    : constant String := Base & "/meta.db";
      Summary_DB : constant String := Base & "/summary.db";
      Chunk_DB   : constant String := Base & "/chunk.db";

      procedure Exec_Raw (Path, Query : String);
      --  Run a resultless statement against the database at Path, on a
      --  connection of its own.

      procedure Exec_Raw (Path, Query : String) is
         DB : Sqlite_Vec_Spark.Database;
         St : Sqlite_Vec_Spark.Status;
      begin
         Sqlite_Vec_Spark.Open (DB, Path, St);
         if St = Sqlite_Vec_Spark.Ok then
            Sqlite_Vec_Spark.Execute (DB, Query, St);
            Check (St = Sqlite_Vec_Spark.Ok, "fixture SQL accepted");
            Sqlite_Vec_Spark.Close (DB);
         else
            Check (False, "fixture database opened");
         end if;
      end Exec_Raw;
   begin
      if Ada.Directories.Exists (Base) then
         Ada.Directories.Delete_Tree (Base);
      end if;
      Ada.Directories.Create_Path (Base);

      --  ---- a path SQLite cannot create ----
      declare
         FS      : Memcp.Store.Store;
         Open_FS : Memcp.Store.Open_Status;
      begin
         Memcp.Store.Open (FS, Base & "/nonesuch/store.db", Open_FS);
         Check (Open_FS = Memcp.Store.Cannot_Open,
                "Open: a path under a missing directory -> Cannot_Open");
      end;

      --  ---- a database stamped by a different schema version ----
      Exec_Raw
        (Meta_DB,
         "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
         & "INSERT INTO meta (key, value) VALUES ('schema_version', '0');");
      declare
         MS      : Memcp.Store.Store;
         Open_MS : Memcp.Store.Open_Status;
      begin
         Memcp.Store.Open (MS, Meta_DB, Open_MS);
         Check (Open_MS = Memcp.Store.Meta_Mismatch,
                "Open: a foreign schema_version -> Meta_Mismatch");
         Check (Scalar (Meta_DB, "SELECT value FROM meta"
                        & " WHERE key = 'schema_version'") = "0",
                "Open: a refused open rewrites nothing");
      end;

      --  ---- the summary write path, with its vec0 table gone ----
      declare
         S1      : Memcp.Store.Store;
         Open_S1 : Memcp.Store.Open_Status;
         R       : Memcp.Store.Save_Result;
         St      : Memcp.Store.Op_Status;
         Id      : Memcp.Store.Row_Id := 0;
      begin
         Memcp.Store.Open (S1, Summary_DB, Open_S1);
         Check (Open_S1 = Memcp.Store.Opened, "Fault: the summary store opens");

         if Open_S1 = Memcp.Store.Opened then
            Memcp.Store.Save
              (S1, "faults", "diary one", "summary one", Hot (1),
               Has_Session => False, Session_Id => "",
               Has_Created => True, Created_At => "2026-06-01T00:00:00+00:00",
               Surface => "", Surface_Label => "",
               Result => R, Status => St);
            Check (St = Memcp.Store.Success, "Fault: the seed row saved");
            Id := R.Summary_Id;

            Exec_Raw (Summary_DB, "DROP TABLE summary_vec;");

            Memcp.Store.Save
              (S1, "faults", "diary two", "summary two", Hot (2),
               Has_Session => False, Session_Id => "",
               Has_Created => True, Created_At => "2026-06-02T00:00:00+00:00",
               Surface => "", Surface_Label => "",
               Result => R, Status => St);
            Check (St = Memcp.Store.Db_Error,
                   "Save: a failing embedding write -> Db_Error");
            Check (Scalar (Summary_DB, "SELECT count(*) FROM summaries") = "1",
                   "Save: the failed save left no summary row behind");
            Check (Scalar (Summary_DB, "SELECT count(*) FROM diary") = "1",
                   "Save: nor a diary line");

            declare
               Projs : Memcp.Store.Name_List;
               Hits  : Memcp.Store.Summary_Hit_List;
               SS    : Memcp.Store.Op_Status;
            begin
               Memcp.Store.Search_Summaries
                 (S1, Hot (1), Projs, 5, Has_Since => False, Since => "",
                  Has_Until => False, Until_At => "", Result => Hits,
                  Status => SS);
               Check (SS = Memcp.Store.Db_Error,
                      "Search_Summaries: a missing vec0 table -> Db_Error");
            end;

            --  A forget deletes the embedding first, so this one fails with
            --  the summary and its diary line already inside the transaction.
            declare
               Del   : Boolean;
               FG_St : Memcp.Store.Op_Status;
            begin
               Memcp.Store.Forget_Summary (S1, Id, Del, FG_St);
               Check (FG_St = Memcp.Store.Db_Error and then not Del,
                      "Forget_Summary: a failing embedding delete -> Db_Error");
            end;
            Check (Scalar (Summary_DB, "SELECT count(*) FROM summaries") = "1",
                   "Forget_Summary: the interrupted delete kept the summary");
            Check (Scalar (Summary_DB, "SELECT count(*) FROM diary") = "1",
                   "Forget_Summary: and the diary line it would have cascaded");

            --  A read that never reaches the missing table is unaffected.
            declare
               P    : Memcp.Store.Summary_Ptr;
               F_St : Memcp.Store.Op_Status;
            begin
               Memcp.Store.Fetch_Summary (S1, Id, P, F_St);
               Check (F_St = Memcp.Store.Success and then P /= null,
                      "Fetch_Summary: unaffected by the broken table");
               if P /= null then
                  Memcp.Store.Free (P);
               end if;
            end;

            Memcp.Store.Close (S1);
         end if;
      end;

      --  ---- the session write path, with its vec0 table gone ----
      declare
         S2      : Memcp.Store.Store;
         Open_S2 : Memcp.Store.Open_Status;
         CL      : Memcp.Store.Chunk_Input_List;
         R       : Memcp.Store.Session_Save_Result;
         St      : Memcp.Store.Op_Status;
      begin
         Memcp.Store.Chunk_Input_Vectors.Append
           (CL, (Body_Len => 6, Content => "turn 0", Embedding => Hot (1)));
         Memcp.Store.Chunk_Input_Vectors.Append
           (CL, (Body_Len => 6, Content => "turn 1", Embedding => Hot (2)));

         Memcp.Store.Open (S2, Chunk_DB, Open_S2);
         Check (Open_S2 = Memcp.Store.Opened, "Fault: the session store opens");

         if Open_S2 = Memcp.Store.Opened then
            Memcp.Store.Save_Session
              (S2, "faults", "se-ok", "raw transcript", CL,
               Has_Created => True, Created_At => "2026-06-01T00:00:00+00:00",
               Surface => "", Surface_Label => "",
               Result => R, Status => St);
            Check (St = Memcp.Store.Success and then R.Chunk_Count = 2,
                   "Fault: the seed session saved");

            Exec_Raw (Chunk_DB, "DROP TABLE chunk_vec;");

            Memcp.Store.Save_Session
              (S2, "faults", "se-bad", "raw transcript", CL,
               Has_Created => True, Created_At => "2026-06-02T00:00:00+00:00",
               Surface => "", Surface_Label => "",
               Result => R, Status => St);
            Check (St = Memcp.Store.Db_Error,
                   "Save_Session: a failing chunk embedding -> Db_Error");
            Check (Scalar (Chunk_DB, "SELECT count(*) FROM sessions") = "1",
                   "Save_Session: the failed save left no session row");
            Check (Scalar (Chunk_DB, "SELECT count(*) FROM chunks") = "2",
                   "Save_Session: nor any orphan chunk");

            --  A reindex deletes the old chunks before inserting the new ones,
            --  so an interrupted swap is the case that would lose rows.
            declare
               Found        : Boolean;
               Old_C, New_C : Natural;
               RI_St        : Memcp.Store.Op_Status;
            begin
               Memcp.Store.Reindex_Session
                 (S2, "faults", "se-ok", CL, Found, Old_C, New_C, RI_St);
               Check (RI_St = Memcp.Store.Db_Error,
                      "Reindex_Session: a failing re-embed -> Db_Error");
            end;
            Check (Scalar (Chunk_DB, "SELECT count(*) FROM chunks") = "2",
                   "Reindex_Session: the interrupted swap kept the old chunks");

            declare
               use type Memcp.Store.Chunk_Vectors.Capacity_Range;
               Turns : Memcp.Store.Chunk_List;
               FT_St : Memcp.Store.Op_Status;
            begin
               Memcp.Store.Fetch_Turns
                 (S2, "se-ok", Has_Project => False, Project => "",
                  Has_Start => False, Start_Ord => 0,
                  Has_End => False, End_Ord => 0,
                  Has_Tail => False, Tail => 1,
                  Result => Turns, Status => FT_St);
               Check (FT_St = Memcp.Store.Success
                      and then Memcp.Store.Chunk_Vectors.Length (Turns) = 2,
                      "Fetch_Turns: unaffected by the broken table");
            end;

            declare
               Projs, Sess : Memcp.Store.Name_List;
               Hits        : Memcp.Store.Chunk_Hit_List;
               SC_St       : Memcp.Store.Op_Status;
            begin
               Memcp.Store.Search_Chunks
                 (S2, Hot (1), Projs, Sess, 5,
                  Has_Since => False, Since => "",
                  Has_Until => False, Until_At => "",
                  Result => Hits, Status => SC_St);
               Check (SC_St = Memcp.Store.Db_Error,
                      "Search_Chunks: a missing vec0 table -> Db_Error");
            end;

            Memcp.Store.Close (S2);
         end if;
      end;

      if Ada.Directories.Exists (Base) then
         Ada.Directories.Delete_Tree (Base);
      end if;
   end;

   Ada.Text_IO.New_Line;
   if Failures = 0 then
      Ada.Text_IO.Put_Line ("ALL PASS");
   else
      Ada.Text_IO.Put_Line ("FAILURES:" & Failures'Image);
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Test_Store;
