--  Proof-of-life driver for Memcp_Store against an in-memory SQLite DB.
--  Drives the first Store slice end-to-end: Open (schema + vec0 + meta),
--  Save (fresh insert, content-dedup no-op, session-scoped replace),
--  Fetch_Summary (hit + miss), Forget_Summary (delete + idempotent miss).
--  -gnata turns the Store's and the binding's Pre/Post into live checks.

with Ada.Command_Line;
with Ada.Text_IO;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Interfaces;

with Candle_Spark;
with Memcp_Store;

procedure Test_Store is

   use type Memcp_Store.Open_Status;
   use type Memcp_Store.Op_Status;
   use type Memcp_Store.Row_Id;
   use type Memcp_Store.Summary_Ptr;

   Failures : Natural := 0;

   procedure Check (Cond : Boolean; Label : String) is
   begin
      if Cond then
         Ada.Text_IO.Put_Line ("ok   - " & Label);
      else
         Ada.Text_IO.Put_Line ("FAIL - " & Label);
         Failures := Failures + 1;
      end if;
   end Check;

   --  A deterministic, in-range embedding (0.0 is a valid Embedding_Component).
   Zero_Emb : constant Candle_Spark.Embedding := [others => 0.0];

   --  A unit embedding with a single hot dimension -- enough for KNN ordering.
   function Hot (K : Positive) return Candle_Spark.Embedding is
      E : Candle_Spark.Embedding := [others => 0.0];
   begin
      E (K) := 1.0;
      return E;
   end Hot;

   --  Read a whole file back as raw bytes (verifies the on-disk transcript).
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

   S      : Memcp_Store.Store;
   Open_S : Memcp_Store.Open_Status;
begin
   Memcp_Store.Open (S, ":memory:", Open_S);
   Check (Open_S = Memcp_Store.Opened, "Open :memory: -> Opened");
   Check (Memcp_Store.Is_Open (S), "Is_Open after Open");

   ------------------------------------------------------------------
   --  Fresh insert
   ------------------------------------------------------------------
   declare
      R  : Memcp_Store.Save_Result;
      St : Memcp_Store.Op_Status;
   begin
      Memcp_Store.Save
        (S, "demo", "a diary headline",
         "HEADLINE: my summary head" & ASCII.LF & "the body text",
         Zero_Emb, Has_Session => False, Session_Id => "",
         Has_Created => True, Created_At => TS, Result => R, Status => St);
      Check (St = Memcp_Store.Success, "Save fresh -> Success");
      Check (not R.Already_Existed and not R.Replaced, "Save fresh: new row");
      Check (R.Summary_Id > 0 and R.Diary_Id > 0, "Save fresh: rowids assigned");

      --  Fetch it back.
      declare
         P  : Memcp_Store.Summary_Ptr;
         St2 : Memcp_Store.Op_Status;
      begin
         Memcp_Store.Fetch_Summary (S, R.Summary_Id, P, St2);
         Check (St2 = Memcp_Store.Success and then P /= null,
                "Fetch_Summary hit");
         if P /= null then
            Check (P.Project = "demo", "Fetch: project");
            Check (P.Headline = "my summary head", "Fetch: HEADLINE parsed");
            Check (P.Content = "HEADLINE: my summary head" & ASCII.LF
                   & "the body text", "Fetch: body preserved");
            Check (P.Kind = "diary", "Fetch: kind=diary");
            Check (not P.Has_Session, "Fetch: session null");
            Memcp_Store.Free (P);
         end if;
      end;

      --  Identical retry: content-dedup no-op, same ids.
      declare
         R2 : Memcp_Store.Save_Result;
         St2 : Memcp_Store.Op_Status;
      begin
         Memcp_Store.Save
           (S, "demo", "a diary headline",
            "HEADLINE: my summary head" & ASCII.LF & "the body text",
            Zero_Emb, Has_Session => False, Session_Id => "",
            Has_Created => True, Created_At => TS, Result => R2, Status => St2);
         Check (St2 = Memcp_Store.Success, "Save retry -> Success");
         Check (R2.Already_Existed and not R2.Replaced, "Save retry: dedup");
         Check (R2.Summary_Id = R.Summary_Id and R2.Diary_Id = R.Diary_Id,
                "Save retry: ids preserved");
      end;

      --  Forget it.
      declare
         Del : Boolean;
         St2 : Memcp_Store.Op_Status;
         P   : Memcp_Store.Summary_Ptr;
         St3 : Memcp_Store.Op_Status;
      begin
         Memcp_Store.Forget_Summary (S, R.Summary_Id, Del, St2);
         Check (St2 = Memcp_Store.Success and then Del, "Forget: deleted");
         Memcp_Store.Fetch_Summary (S, R.Summary_Id, P, St3);
         Check (St3 = Memcp_Store.Success and then P = null,
                "Fetch after forget: miss");
         Memcp_Store.Forget_Summary (S, R.Summary_Id, Del, St2);
         Check (St2 = Memcp_Store.Success and then not Del,
                "Forget again: idempotent miss");
      end;
   end;

   ------------------------------------------------------------------
   --  Session-scoped upsert: second save replaces in place
   ------------------------------------------------------------------
   declare
      R1, R2 : Memcp_Store.Save_Result;
      St1, St2 : Memcp_Store.Op_Status;
      P  : Memcp_Store.Summary_Ptr;
      St3 : Memcp_Store.Op_Status;
   begin
      Memcp_Store.Save
        (S, "demo", "first diary", "first summary body",
         Zero_Emb, Has_Session => True, Session_Id => "sess-1",
         Has_Created => True, Created_At => TS, Result => R1, Status => St1);
      Check (St1 = Memcp_Store.Success and then not R1.Already_Existed,
             "Session save: fresh");

      Memcp_Store.Save
        (S, "demo", "second diary", "second summary body",
         Zero_Emb, Has_Session => True, Session_Id => "sess-1",
         Has_Created => True, Created_At => TS, Result => R2, Status => St2);
      Check (St2 = Memcp_Store.Success and then R2.Replaced,
             "Session save: replaced in place");
      Check (R2.Summary_Id = R1.Summary_Id and R2.Diary_Id = R1.Diary_Id,
             "Session save: ids preserved across replace");

      Memcp_Store.Fetch_Summary (S, R2.Summary_Id, P, St3);
      Check (St3 = Memcp_Store.Success and then P /= null
             and then P.Content = "second summary body",
             "Session save: body updated");
      Check (P /= null and then P.Has_Session and then P.Session = "sess-1",
             "Session save: session_id set");
      if P /= null then
         Memcp_Store.Free (P);
      end if;
   end;

   ------------------------------------------------------------------
   --  Recent_Diary: list-valued read over a Name_List filter
   ------------------------------------------------------------------
   declare
      use type Memcp_Store.Name_Vectors.Capacity_Range;
      R1, R2, R3 : Memcp_Store.Save_Result;
      Stx        : Memcp_Store.Op_Status;
      Projs      : Memcp_Store.Name_List;
      Empty      : Memcp_Store.Name_List;
      Entries    : Memcp_Store.Diary_Entry_List;
      RD_St      : Memcp_Store.Op_Status;
   begin
      --  Three diary entries across two projects, ascending timestamps.
      Memcp_Store.Save
        (S, "alpha", "diary a1", "body a1", Zero_Emb,
         Has_Session => False, Session_Id => "",
         Has_Created => True, Created_At => "2026-02-01T00:00:00+00:00",
         Result => R1, Status => Stx);
      Memcp_Store.Save
        (S, "beta", "diary b1", "body b1", Zero_Emb,
         Has_Session => False, Session_Id => "",
         Has_Created => True, Created_At => "2026-02-02T00:00:00+00:00",
         Result => R2, Status => Stx);
      Memcp_Store.Save
        (S, "alpha", "diary a2", "body a2", Zero_Emb,
         Has_Session => False, Session_Id => "",
         Has_Created => True, Created_At => "2026-02-03T00:00:00+00:00",
         Result => R3, Status => Stx);

      --  Empty projects -> empty result, Success (store.py `if not projects`).
      Memcp_Store.Recent_Diary (S, Empty, 10, Entries, RD_St);
      Check (RD_St = Memcp_Store.Success
             and then Memcp_Store.Diary_Vectors.Length (Entries) = 0,
             "Recent_Diary: no projects -> empty");

      --  Filter to "alpha": two rows, newest (a2) first.
      Memcp_Store.Name_Vectors.Append (Projs, (Len => 5, Value => "alpha"));
      Memcp_Store.Recent_Diary (S, Projs, 10, Entries, RD_St);
      Check (RD_St = Memcp_Store.Success
             and then Memcp_Store.Diary_Vectors.Length (Entries) = 2,
             "Recent_Diary: alpha -> 2 rows");
      if Memcp_Store.Diary_Vectors.Length (Entries) = 2 then
         declare
            E1 : constant Memcp_Store.Diary_Entry :=
              Memcp_Store.Diary_Vectors.Element (Entries, 1);
            E2 : constant Memcp_Store.Diary_Entry :=
              Memcp_Store.Diary_Vectors.Element (Entries, 2);
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
      Memcp_Store.Name_Vectors.Append (Projs, (Len => 4, Value => "beta"));
      Memcp_Store.Recent_Diary (S, Projs, 1, Entries, RD_St);
      Check (RD_St = Memcp_Store.Success
             and then Memcp_Store.Diary_Vectors.Length (Entries) = 1
             and then Memcp_Store.Diary_Vectors.Element (Entries, 1).Content
                      = "diary a2",
             "Recent_Diary: LIMIT 1 -> newest across projects");
   end;

   ------------------------------------------------------------------
   --  List_Projects: every project with its diary count, newest first
   ------------------------------------------------------------------
   declare
      use type Memcp_Store.Project_Vectors.Capacity_Range;
      Projs : Memcp_Store.Project_Info_List;
      LP_St : Memcp_Store.Op_Status;
   begin
      --  Prior blocks left three projects: alpha (2 diary, newest 02-03),
      --  beta (1, 02-02), demo (1 session-scoped, 01-01). Ordered by newest
      --  activity DESC -> alpha, beta, demo.
      Memcp_Store.List_Projects (S, Projs, LP_St);
      Check (LP_St = Memcp_Store.Success
             and then Memcp_Store.Project_Vectors.Length (Projs) = 3,
             "List_Projects: three projects");
      if Memcp_Store.Project_Vectors.Length (Projs) = 3 then
         declare
            P1 : constant Memcp_Store.Project_Info :=
              Memcp_Store.Project_Vectors.Element (Projs, 1);
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
      use type Memcp_Store.Summary_Hit_Vectors.Capacity_Range;
      use type Interfaces.IEEE_Float_64;

      Emb_A : Candle_Spark.Embedding := [others => 0.0];
      Emb_B : Candle_Spark.Embedding := [others => 0.0];
      Ra, Rb : Memcp_Store.Save_Result;
      Sv     : Memcp_Store.Op_Status;
      Projs  : Memcp_Store.Name_List;
      No_Filt : Memcp_Store.Name_List;
      Hits   : Memcp_Store.Summary_Hit_List;
      SS_St  : Memcp_Store.Op_Status;
   begin
      Emb_A (1) := 1.0;
      Emb_B (2) := 1.0;
      Memcp_Store.Save
        (S, "search", "diary sa", "summary sa", Emb_A,
         Has_Session => False, Session_Id => "",
         Has_Created => True, Created_At => "2026-03-01T00:00:00+00:00",
         Result => Ra, Status => Sv);
      Memcp_Store.Save
        (S, "search", "diary sb", "summary sb", Emb_B,
         Has_Session => False, Session_Id => "",
         Has_Created => True, Created_At => "2026-03-02T00:00:00+00:00",
         Result => Rb, Status => Sv);
      Memcp_Store.Name_Vectors.Append (Projs, (Len => 6, Value => "search"));

      --  Query near Emb_A: both hits, sa nearest (distance ~0 < sb).
      Memcp_Store.Search_Summaries
        (S, Emb_A, Projs, 5, Has_Since => False, Since => "",
         Has_Until => False, Until_At => "", Result => Hits, Status => SS_St);
      Check (SS_St = Memcp_Store.Success
             and then Memcp_Store.Summary_Hit_Vectors.Length (Hits) = 2,
             "Search_Summaries: project filter -> 2 hits");
      if Memcp_Store.Summary_Hit_Vectors.Length (Hits) = 2 then
         declare
            H1 : constant Memcp_Store.Summary_Hit :=
              Memcp_Store.Summary_Hit_Vectors.Element (Hits, 1);
            H2 : constant Memcp_Store.Summary_Hit :=
              Memcp_Store.Summary_Hit_Vectors.Element (Hits, 2);
         begin
            Check (H1.Content = "summary sa", "Search_Summaries: nearest first");
            Check (H1.Distance < H2.Distance,
                   "Search_Summaries: ascending distance");
         end;
      end if;

      --  limit 1 -> just the nearest.
      Memcp_Store.Search_Summaries
        (S, Emb_A, Projs, 1, Has_Since => False, Since => "",
         Has_Until => False, Until_At => "", Result => Hits, Status => SS_St);
      Check (SS_St = Memcp_Store.Success
             and then Memcp_Store.Summary_Hit_Vectors.Length (Hits) = 1
             and then Memcp_Store.Summary_Hit_Vectors.Element (Hits, 1).Content
                      = "summary sa",
             "Search_Summaries: limit 1 -> nearest only");

      --  No project filter, limit 1: sa (distance 0) is the global nearest.
      Memcp_Store.Search_Summaries
        (S, Emb_A, No_Filt, 1, Has_Since => False, Since => "",
         Has_Until => False, Until_At => "", Result => Hits, Status => SS_St);
      Check (SS_St = Memcp_Store.Success
             and then Memcp_Store.Summary_Hit_Vectors.Length (Hits) = 1
             and then Memcp_Store.Summary_Hit_Vectors.Element (Hits, 1).Content
                      = "summary sa",
             "Search_Summaries: no filter -> global nearest");

      --  Until before both search rows -> filtered out entirely.
      Memcp_Store.Search_Summaries
        (S, Emb_A, Projs, 5, Has_Since => False, Since => "",
         Has_Until => True, Until_At => "2026-01-01T00:00:00+00:00",
         Result => Hits, Status => SS_St);
      Check (SS_St = Memcp_Store.Success
             and then Memcp_Store.Summary_Hit_Vectors.Length (Hits) = 0,
             "Search_Summaries: until-window excludes all");

      --  Since = sb's timestamp -> only sb passes.
      Memcp_Store.Search_Summaries
        (S, Emb_A, Projs, 5, Has_Since => True,
         Since => "2026-03-02T00:00:00+00:00",
         Has_Until => False, Until_At => "", Result => Hits, Status => SS_St);
      Check (SS_St = Memcp_Store.Success
             and then Memcp_Store.Summary_Hit_Vectors.Length (Hits) = 1
             and then Memcp_Store.Summary_Hit_Vectors.Element (Hits, 1).Content
                      = "summary sb",
             "Search_Summaries: since-window keeps only newer");
   end;

   ------------------------------------------------------------------
   --  Search_Chunks: no chunk rows yet -> empty, but every filter path runs
   ------------------------------------------------------------------
   declare
      use type Memcp_Store.Chunk_Hit_Vectors.Capacity_Range;
      Q       : constant Candle_Spark.Embedding := [others => 0.0];
      Projs   : Memcp_Store.Name_List;
      Sess    : Memcp_Store.Name_List;
      Hits    : Memcp_Store.Chunk_Hit_List;
      SC_St   : Memcp_Store.Op_Status;
   begin
      Memcp_Store.Name_Vectors.Append (Projs, (Len => 6, Value => "search"));
      Memcp_Store.Name_Vectors.Append (Sess, (Len => 4, Value => "sess"));
      Memcp_Store.Search_Chunks
        (S, Q, Projs, Sess, 5, Has_Since => True,
         Since => "2020-01-01T00:00:00+00:00", Has_Until => True,
         Until_At => "2030-01-01T00:00:00+00:00", Result => Hits,
         Status => SC_St);
      Check (SC_St = Memcp_Store.Success
             and then Memcp_Store.Chunk_Hit_Vectors.Length (Hits) = 0,
             "Search_Chunks: all filters, empty table -> empty");
   end;

   ------------------------------------------------------------------
   --  Fetch_Turns: no session rows yet (save_session is a later slice),
   --  so every filter branch must build valid SQL and return empty+Success.
   ------------------------------------------------------------------
   declare
      use type Memcp_Store.Chunk_Vectors.Capacity_Range;
      Turns : Memcp_Store.Chunk_List;
      FT_St : Memcp_Store.Op_Status;

      procedure Expect_Empty (Label : String) is
      begin
         Check (FT_St = Memcp_Store.Success
                and then Memcp_Store.Chunk_Vectors.Length (Turns) = 0, Label);
      end Expect_Empty;
   begin
      Memcp_Store.Fetch_Turns
        (S, "no-such", Has_Project => False, Project => "",
         Has_Start => False, Start_Ord => 0, Has_End => False, End_Ord => 0,
         Has_Tail => False, Tail => 1, Result => Turns, Status => FT_St);
      Expect_Empty ("Fetch_Turns: plain, unknown session -> empty");

      Memcp_Store.Fetch_Turns
        (S, "no-such", Has_Project => True, Project => "alpha",
         Has_Start => False, Start_Ord => 0, Has_End => False, End_Ord => 0,
         Has_Tail => False, Tail => 1, Result => Turns, Status => FT_St);
      Expect_Empty ("Fetch_Turns: +project filter -> empty");

      Memcp_Store.Fetch_Turns
        (S, "no-such", Has_Project => False, Project => "",
         Has_Start => True, Start_Ord => 2, Has_End => True, End_Ord => 5,
         Has_Tail => False, Tail => 1, Result => Turns, Status => FT_St);
      Expect_Empty ("Fetch_Turns: +[start,end) window -> empty");

      Memcp_Store.Fetch_Turns
        (S, "no-such", Has_Project => False, Project => "",
         Has_Start => False, Start_Ord => 0, Has_End => False, End_Ord => 0,
         Has_Tail => True, Tail => 3, Result => Turns, Status => FT_St);
      Expect_Empty ("Fetch_Turns: +tail (subquery form) -> empty");
   end;

   ------------------------------------------------------------------
   --  Save_Session on the :memory: store: chunks land (raw_path skipped),
   --  Fetch_Turns / Search_Chunks now read real rows, idempotent retry.
   ------------------------------------------------------------------
   declare
      --  Both instances' Capacity_Range is the same Count_Type subtype, so one
      --  use-type clause makes "=" visible for every Length comparison below.
      use type Memcp_Store.Chunk_Vectors.Capacity_Range;
      Sess_TS : constant String := "2026-05-01T00:00:00+00:00";
      CL   : Memcp_Store.Chunk_Input_List;
      R    : Memcp_Store.Session_Save_Result;
      St   : Memcp_Store.Op_Status;
   begin
      Memcp_Store.Chunk_Input_Vectors.Append
        (CL, (Body_Len => 6, Content => "turn 0", Embedding => Hot (1)));
      Memcp_Store.Chunk_Input_Vectors.Append
        (CL, (Body_Len => 6, Content => "turn 1", Embedding => Hot (2)));
      Memcp_Store.Chunk_Input_Vectors.Append
        (CL, (Body_Len => 6, Content => "turn 2", Embedding => Hot (3)));

      Memcp_Store.Save_Session
        (S, "sessapp", "se-1", "raw transcript body", CL,
         Has_Created => True, Created_At => Sess_TS, Result => R, Status => St);
      Check (St = Memcp_Store.Success and then not R.Already_Existed
             and then R.Chunk_Count = 3 and then R.Session_Row_Id > 0,
             "Save_Session: fresh, 3 chunks");
      Check (not R.Raw_Path_Set,
             "Save_Session: :memory: writes no transcript file");

      --  Fetch_Turns now returns real rows, ascending ordinal.
      declare
         Turns : Memcp_Store.Chunk_List;
         FT_St : Memcp_Store.Op_Status;
      begin
         Memcp_Store.Fetch_Turns
           (S, "se-1", Has_Project => False, Project => "",
            Has_Start => False, Start_Ord => 0, Has_End => False, End_Ord => 0,
            Has_Tail => False, Tail => 1, Result => Turns, Status => FT_St);
         Check (FT_St = Memcp_Store.Success
                and then Memcp_Store.Chunk_Vectors.Length (Turns) = 3,
                "Fetch_Turns: session has 3 turns");
         if Memcp_Store.Chunk_Vectors.Length (Turns) = 3 then
            declare
               T0 : constant Memcp_Store.Chunk :=
                 Memcp_Store.Chunk_Vectors.Element (Turns, 1);
               T2 : constant Memcp_Store.Chunk :=
                 Memcp_Store.Chunk_Vectors.Element (Turns, 3);
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
         Memcp_Store.Fetch_Turns
           (S, "se-1", Has_Project => True, Project => "sessapp",
            Has_Start => False, Start_Ord => 0, Has_End => False, End_Ord => 0,
            Has_Tail => True, Tail => 1, Result => Turns, Status => FT_St);
         Check (FT_St = Memcp_Store.Success
                and then Memcp_Store.Chunk_Vectors.Length (Turns) = 1
                and then Memcp_Store.Chunk_Vectors.Element (Turns, 1).Content
                         = "turn 2",
                "Fetch_Turns: tail 1 -> last turn");

         --  [start, end) window -> ordinals 1 and 2.
         Memcp_Store.Fetch_Turns
           (S, "se-1", Has_Project => False, Project => "",
            Has_Start => True, Start_Ord => 1, Has_End => True, End_Ord => 3,
            Has_Tail => False, Tail => 1, Result => Turns, Status => FT_St);
         Check (FT_St = Memcp_Store.Success
                and then Memcp_Store.Chunk_Vectors.Length (Turns) = 2
                and then Memcp_Store.Chunk_Vectors.Element (Turns, 1).Ordinal = 1,
                "Fetch_Turns: [1,3) window -> 2 turns from ordinal 1");
      end;

      --  Search_Chunks over real chunk rows: nearest to Hot(1) is turn 0.
      declare
         Projs : Memcp_Store.Name_List;
         Hits  : Memcp_Store.Chunk_Hit_List;
         SC_St : Memcp_Store.Op_Status;
      begin
         Memcp_Store.Name_Vectors.Append
           (Projs, (Len => 7, Value => "sessapp"));
         Memcp_Store.Search_Chunks
           (S, Hot (1), Projs, Memcp_Store.Name_Vectors.Empty_Vector, 5,
            Has_Since => False, Since => "", Has_Until => False, Until_At => "",
            Result => Hits, Status => SC_St);
         Check (SC_St = Memcp_Store.Success
                and then Memcp_Store.Chunk_Hit_Vectors.Length (Hits) = 3,
                "Search_Chunks: project filter -> 3 hits");
         if Memcp_Store.Chunk_Hit_Vectors.Length (Hits) = 3 then
            Check (Memcp_Store.Chunk_Hit_Vectors.Element (Hits, 1).Content
                   = "turn 0"
                   and then Memcp_Store.Chunk_Hit_Vectors.Element (Hits, 1)
                              .Session = "se-1",
                   "Search_Chunks: nearest is turn 0, session carried");
         end if;
      end;

      --  Idempotent retry: same session -> Already_Existed, count preserved.
      declare
         R2 : Memcp_Store.Session_Save_Result;
         St2 : Memcp_Store.Op_Status;
      begin
         Memcp_Store.Save_Session
           (S, "sessapp", "se-1", "different transcript", CL,
            Has_Created => True, Created_At => Sess_TS,
            Result => R2, Status => St2);
         Check (St2 = Memcp_Store.Success and then R2.Already_Existed
                and then R2.Chunk_Count = 3
                and then R2.Session_Row_Id = R.Session_Row_Id,
                "Save_Session: idempotent retry, no re-insert");
      end;
   end;

   ------------------------------------------------------------------
   --  Save_Autorecap: writes when no Header exists, then short-circuits.
   ------------------------------------------------------------------
   declare
      Sum_Id, Diary_Id : Memcp_Store.Row_Id;
      Written : Boolean;
      St      : Memcp_Store.Op_Status;
   begin
      --  se-1 has chunks but no summary yet -> autorecap is written.
      Memcp_Store.Save_Autorecap
        (S, "sessapp", "se-1", "session recap line", Hot (5),
         Has_Created => True, Created_At => TS,
         Summary_Id => Sum_Id, Diary_Id => Diary_Id,
         Written => Written, Status => St);
      Check (St = Memcp_Store.Success and then Written
             and then Sum_Id > 0 and then Diary_Id > 0,
             "Save_Autorecap: fresh -> written");

      declare
         P   : Memcp_Store.Summary_Ptr;
         St2 : Memcp_Store.Op_Status;
      begin
         Memcp_Store.Fetch_Summary (S, Sum_Id, P, St2);
         Check (St2 = Memcp_Store.Success and then P /= null
                and then P.Kind = "autorecap"
                and then P.Content = "session recap line"
                and then P.Headline = "session recap line"
                and then P.Has_Session and then P.Session = "se-1",
                "Save_Autorecap: summary kind/body/headline/session");
         if P /= null then
            Memcp_Store.Free (P);
         end if;
      end;

      --  Second call now finds an existing Header -> short-circuit, no write.
      Memcp_Store.Save_Autorecap
        (S, "sessapp", "se-1", "a different recap", Hot (5),
         Has_Created => True, Created_At => TS,
         Summary_Id => Sum_Id, Diary_Id => Diary_Id,
         Written => Written, Status => St);
      Check (St = Memcp_Store.Success and then not Written,
             "Save_Autorecap: existing Header -> not written");

      --  A real save() for a session must also block a later autorecap.
      declare
         R  : Memcp_Store.Save_Result;
         Sv : Memcp_Store.Op_Status;
      begin
         Memcp_Store.Save
           (S, "sessapp", "diary for se-2", "summary for se-2", Zero_Emb,
            Has_Session => True, Session_Id => "se-2",
            Has_Created => True, Created_At => TS, Result => R, Status => Sv);
         Memcp_Store.Save_Autorecap
           (S, "sessapp", "se-2", "recap for se-2", Hot (6),
            Has_Created => True, Created_At => TS,
            Summary_Id => Sum_Id, Diary_Id => Diary_Id,
            Written => Written, Status => St);
         Check (St = Memcp_Store.Success and then not Written,
                "Save_Autorecap: real save() takes precedence");
      end;
   end;

   ------------------------------------------------------------------
   --  Reindex_Session: replace a session's chunks in place.
   ------------------------------------------------------------------
   declare
      use type Memcp_Store.Chunk_Vectors.Capacity_Range;
      NL    : Memcp_Store.Chunk_Input_List;
      Found : Boolean;
      Old_C, New_C : Natural;
      St    : Memcp_Store.Op_Status;
   begin
      Memcp_Store.Chunk_Input_Vectors.Append
        (NL, (Body_Len => 10, Content => "new turn A", Embedding => Hot (1)));
      Memcp_Store.Chunk_Input_Vectors.Append
        (NL, (Body_Len => 10, Content => "new turn B", Embedding => Hot (2)));

      Memcp_Store.Reindex_Session
        (S, "sessapp", "se-1", NL, Found => Found,
         Old_Count => Old_C, New_Count => New_C, Status => St);
      Check (St = Memcp_Store.Success and then Found
             and then Old_C = 3 and then New_C = 2,
             "Reindex_Session: 3 old chunks -> 2 new");

      declare
         Turns : Memcp_Store.Chunk_List;
         FT_St : Memcp_Store.Op_Status;
      begin
         Memcp_Store.Fetch_Turns
           (S, "se-1", Has_Project => False, Project => "",
            Has_Start => False, Start_Ord => 0, Has_End => False, End_Ord => 0,
            Has_Tail => False, Tail => 1, Result => Turns, Status => FT_St);
         Check (FT_St = Memcp_Store.Success
                and then Memcp_Store.Chunk_Vectors.Length (Turns) = 2
                and then Memcp_Store.Chunk_Vectors.Element (Turns, 1).Content
                         = "new turn A"
                and then Memcp_Store.Chunk_Vectors.Element (Turns, 1).Created_At
                         = "2026-05-01T00:00:00+00:00",
                "Reindex_Session: new turns replace old, created_at preserved");
      end;

      --  Unknown session -> Found False, Success.
      Memcp_Store.Reindex_Session
        (S, "sessapp", "no-such-session", NL, Found => Found,
         Old_Count => Old_C, New_Count => New_C, Status => St);
      Check (St = Memcp_Store.Success and then not Found,
             "Reindex_Session: unknown session -> not found");
   end;

   Memcp_Store.Close (S);
   Check (not Memcp_Store.Is_Open (S), "Close -> not open");

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
      FS      : Memcp_Store.Store;
      Open_FS : Memcp_Store.Open_Status;
   begin
      if Ada.Directories.Exists (Base) then
         Ada.Directories.Delete_Tree (Base);
      end if;
      Ada.Directories.Create_Path (Base);

      Memcp_Store.Open (FS, DB_File, Open_FS);
      Check (Open_FS = Memcp_Store.Opened, "Open file-backed store");

      if Open_FS = Memcp_Store.Opened then
         declare
            CL : Memcp_Store.Chunk_Input_List;
            R  : Memcp_Store.Session_Save_Result;
            St : Memcp_Store.Op_Status;
            Expect_Path : constant String :=
              Base & "/sessions/fileproj/fs-1.jsonl";
         begin
            Memcp_Store.Chunk_Input_Vectors.Append
              (CL, (Body_Len => 4, Content => "only", Embedding => Hot (1)));
            Memcp_Store.Save_Session
              (FS, "fileproj", "fs-1", "hello transcript", CL,
               Has_Created => True, Created_At => TS,
               Result => R, Status => St);
            Check (St = Memcp_Store.Success and then not R.Already_Existed
                   and then R.Raw_Path_Set,
                   "Save_Session: file-backed -> raw_path written");
            Check (Ada.Directories.Exists (Expect_Path),
                   "Save_Session: transcript file exists on disk");
            if Ada.Directories.Exists (Expect_Path) then
               Check (Read_File (Expect_Path) = "hello transcript",
                      "Save_Session: transcript bytes match");
            end if;
         end;
         Memcp_Store.Close (FS);
      end if;

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
