--  Memcp.Store body: the schema DDL, the prepare/bind/step sequence behind
--  each operation, and the few helpers that sit outside SPARK (SHA-256 dedup
--  hash, wall-clock timestamp, raw transcript write).

with Ada.Streams;             use Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Conversion;
with Ada.Directories;

with GNAT.SHA256;
with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Calendar.Time_Zones;

with SPARK.Containers.Types;

with Memcp.Log;

package body Memcp.Store with SPARK_Mode => On is

   package Sql renames Sqlite_Vec_Spark;
   use type Sql.Status;
   use type Row_Id;

   --  Operators on the vectors' Capacity_Range, for the Length and Last_Count
   --  comparisons below.
   use type SPARK.Containers.Types.Count_Type;

   procedure Free_Path is
     new Ada.Unchecked_Deallocation (String, Path_Access);
   --  Reclaim a remembered database path or transcript-path copy.

   function Dedup_Hash
     (Project, Diary_Body, Summary_Body : String) return String
     with Global => null;
   --  SHA-256 hex over Project, Diary_Body and Summary_Body, NUL-delimited so
   --  field boundaries cannot collide ("ab" + "c" against "a" + "bc"). The
   --  digest is stored, and the conformance corpus holds hashes built this way,
   --  so the construction is frozen. The body is outside SPARK; Global => null
   --  is the boundary claim, as on the FFI imports.

   function Now_Iso return String with Global => null;
   --  Wall-clock timestamp as ISO-8601 with the local UTC offset, e.g.
   --  "2026-07-13T14:12:13-04:00". Sub-second precision is dropped; a caller
   --  that needs an exact stamp supplies Created_At instead. Body outside
   --  SPARK, as for Dedup_Hash.

   -------------------------------------------
   --  Schema, applied to every store by Open
   -------------------------------------------

   LF : constant Character := ASCII.LF;
   --  Statement separator within the DDL below.

   Schema_SQL : constant String :=
     "CREATE TABLE IF NOT EXISTS meta ("                              & LF &
     "  key TEXT PRIMARY KEY, value TEXT NOT NULL);"                  & LF &
     "CREATE TABLE IF NOT EXISTS projects ("                          & LF &
     "  id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);"          & LF &
     "CREATE TABLE IF NOT EXISTS surfaces ("                          & LF &
     "  id INTEGER PRIMARY KEY,"                                      & LF &
     "  surface_id TEXT NOT NULL UNIQUE, label TEXT NOT NULL,"        & LF &
     "  first_seen TEXT NOT NULL, last_seen TEXT NOT NULL);"          & LF &
     "CREATE TABLE IF NOT EXISTS summaries ("                         & LF &
     "  id INTEGER PRIMARY KEY,"                                      & LF &
     "  project_id INTEGER NOT NULL REFERENCES projects(id),"         & LF &
     "  session_id TEXT, created_at TEXT NOT NULL,"                   & LF &
     "  headline TEXT NOT NULL, body TEXT NOT NULL,"                  & LF &
     "  dedup_hash TEXT, kind TEXT NOT NULL DEFAULT 'diary');"        & LF &
     "CREATE INDEX IF NOT EXISTS idx_summaries_project_date"          & LF &
     "  ON summaries(project_id, created_at DESC);"                   & LF &
     "CREATE INDEX IF NOT EXISTS idx_summaries_session"               & LF &
     "  ON summaries(session_id);"                                    & LF &
     "CREATE INDEX IF NOT EXISTS idx_summaries_dedup"                 & LF &
     "  ON summaries(dedup_hash);"                                    & LF &
     "CREATE TABLE IF NOT EXISTS diary ("                             & LF &
     "  id INTEGER PRIMARY KEY,"                                      & LF &
     "  project_id INTEGER NOT NULL REFERENCES projects(id),"         & LF &
     "  summary_id INTEGER NOT NULL REFERENCES summaries(id)"         & LF &
     "    ON DELETE CASCADE,"                                         & LF &
     "  created_at TEXT NOT NULL, body TEXT NOT NULL);"               & LF &
     "CREATE INDEX IF NOT EXISTS idx_diary_project_date"              & LF &
     "  ON diary(project_id, created_at DESC);"                       & LF &
     "CREATE TABLE IF NOT EXISTS sessions ("                          & LF &
     "  id INTEGER PRIMARY KEY,"                                      & LF &
     "  project_id INTEGER NOT NULL REFERENCES projects(id),"         & LF &
     "  session_id TEXT NOT NULL, created_at TEXT NOT NULL,"          & LF &
     "  raw_path TEXT, UNIQUE (project_id, session_id));"             & LF &
     "CREATE INDEX IF NOT EXISTS idx_sessions_project_date"           & LF &
     "  ON sessions(project_id, created_at DESC);"                    & LF &
     "CREATE TABLE IF NOT EXISTS chunks ("                            & LF &
     "  id INTEGER PRIMARY KEY,"                                      & LF &
     "  session_row_id INTEGER NOT NULL REFERENCES sessions(id)"      & LF &
     "    ON DELETE CASCADE,"                                         & LF &
     "  project_id INTEGER NOT NULL REFERENCES projects(id),"         & LF &
     "  ordinal INTEGER NOT NULL, body TEXT NOT NULL,"                & LF &
     "  created_at TEXT NOT NULL);"                                   & LF &
     "CREATE INDEX IF NOT EXISTS idx_chunks_session"                  & LF &
     "  ON chunks(session_row_id);";
   --  The relational schema: meta, projects, surfaces, summaries, diary,
   --  sessions and chunks, with their indexes. Every statement is IF NOT
   --  EXISTS, so applying it to an existing database is a no-op. The
   --  surface_row_id columns are added by Add_Column instead, which no CREATE
   --  can express for a table that already exists.

   Vec_Summary_SQL : constant String :=
     "CREATE VIRTUAL TABLE IF NOT EXISTS summary_vec"
     & " USING vec0(embedding float[384])";
   --  The vec0 table holding one embedding per summaries row, keyed by rowid.

   Vec_Chunk_SQL   : constant String :=
     "CREATE VIRTUAL TABLE IF NOT EXISTS chunk_vec"
     & " USING vec0(embedding float[384])";
   --  The vec0 table holding one embedding per chunks row, keyed by rowid.

   -------------------------------------------------------------
   --  Trusted, non-SPARK helpers (isolated behind SPARK_Mode Off)
   -------------------------------------------------------------

   function Dedup_Hash
     (Project, Diary_Body, Summary_Body : String) return String
     with SPARK_Mode => Off
   is
      Ctx : GNAT.SHA256.Context := GNAT.SHA256.Initial_Context;
      Nul : constant String := [1 => ASCII.NUL];
   begin
      GNAT.SHA256.Update (Ctx, Project);
      GNAT.SHA256.Update (Ctx, Nul);
      GNAT.SHA256.Update (Ctx, Diary_Body);
      GNAT.SHA256.Update (Ctx, Nul);
      GNAT.SHA256.Update (Ctx, Summary_Body);
      return GNAT.SHA256.Digest (Ctx);
   end Dedup_Hash;

   function Now_Iso return String with SPARK_Mode => Off is
      use Ada.Calendar;
      use Ada.Calendar.Time_Zones;
      Off_Min : constant Time_Offset := UTC_Time_Offset;
      Base    : constant String :=
        Ada.Calendar.Formatting.Image (Clock, False, Off_Min);
      --  Base is "YYYY-MM-DD HH:MM:SS"; ISO wants a 'T' and a +HH:MM suffix.
      Iso     : String := Base;
      Sign    : constant Character := (if Off_Min < 0 then '-' else '+');
      Mag     : constant Natural := Natural (abs Integer (Off_Min));
      HH      : constant Natural := Mag / 60;
      MM      : constant Natural := Mag mod 60;
      function D2 (N : Natural) return String is
        [1 => Character'Val (Character'Pos ('0') + N / 10),
         2 => Character'Val (Character'Pos ('0') + N mod 10)];
      --  N as exactly two decimal digits.
   begin
      Iso (Iso'First + 10) := 'T';
      return Iso & Sign & D2 (HH) & ":" & D2 (MM);
   end Now_Iso;

   ----------------------------------------------
   --  Raw session-file location and write
   ----------------------------------------------

   function Parent_Dir (Path : String) return String;
   --  Directory portion of Path, everything before the last '/':
   --  "/a/b/x" gives "/a/b", "/x" gives "/", and a Path with no separator
   --  (including ":memory:") gives ".". Always a slice of Path, never a
   --  concatenation, so it cannot overflow.

   function Parent_Dir (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            if I = Path'First then
               return "/";
            else
               return Path (Path'First .. I - 1);
            end if;
         end if;
      end loop;
      return ".";
   end Parent_Dir;

   procedure Write_Session_File
     (Parent, Project, Session_Id, Content : String;
      Path_Out : out Path_Access)
     with Global => null;
   --  Write Content to <Parent>/sessions/<Project>/<Session_Id>.jsonl, creating
   --  the parent directories first. Best-effort: on success Path_Out is an
   --  owning copy of the path written, for the caller to store and then Free;
   --  any I/O failure leaves it null. Stream_IO writes the exact bytes, one per
   --  Character, so UTF-8 content passes through unaltered. Body outside SPARK.

   procedure Write_Session_File
     (Parent, Project, Session_Id, Content : String;
      Path_Out : out Path_Access)
     with SPARK_Mode => Off
   is
      use Ada.Streams.Stream_IO;
      Dir  : constant String := Parent & "/sessions/" & Project;
      Path : constant String := Dir & "/" & Session_Id & ".jsonl";
      F    : File_Type;
   begin
      Path_Out := null;
      Ada.Directories.Create_Path (Dir);
      Create (F, Out_File, Path);
      String'Write (Stream (F), Content);
      Close (F);
      Path_Out := new String'(Path);
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Path_Out := null;
   end Write_Session_File;

   ------------------------
   --  Headline extraction
   ------------------------

   function Is_Space (C : Character) return Boolean is
     (C = ' ' or else C = ASCII.HT or else C = ASCII.LF
      or else C = ASCII.CR or else C = ASCII.FF or else C = ASCII.VT);
   --  Whether C is one of the six ASCII whitespace characters.

   Headline_Cap : constant := 100;
   --  Longest headline derived from a body, in characters.

   Prefix       : constant String := "HEADLINE:";
   --  The marker a body may use to name its own headline.

   function To_Upper (C : Character) return Character is
     (if C in 'a' .. 'z'
      then Character'Val (Character'Pos (C) - 32) else C);
   --  C folded to upper case, ASCII only.

   procedure Strip_Bounds (S : String; First : out Integer; Last : out Integer)
     with Pre  => S'Last < Integer'Last,
          Post => (First > Last) or else
                    (First in S'Range and then Last in S'Range),
          Always_Terminates;
   --  The [First, Last] slice bounds of S with leading and trailing
   --  whitespace removed; First > Last signals an all-blank S.

   procedure Strip_Bounds (S : String; First : out Integer; Last : out Integer)
   is
   begin
      First := S'First;
      Last  := S'Last;
      while First <= Last and then Is_Space (S (First)) loop
         pragma Loop_Invariant (First in S'First .. Last and then Last = S'Last);
         pragma Loop_Variant (Increases => First);
         First := First + 1;
      end loop;
      while Last >= First and then Is_Space (S (Last)) loop
         pragma Loop_Invariant
           (Last in First .. S'Last and then First >= S'First);
         pragma Loop_Variant (Decreases => Last);
         Last := Last - 1;
      end loop;
   end Strip_Bounds;

   function Starts_With_Prefix (S : String) return Boolean
     with Pre  => S'Last < Integer'Last,
          --  On True a caller may slice Prefix off S without a further length
          --  check of its own.
          Post => (if Starts_With_Prefix'Result then S'Length >= Prefix'Length);
   --  Whether S begins with Prefix, compared case-insensitively.

   function Starts_With_Prefix (S : String) return Boolean is
   begin
      if S'Length < Prefix'Length then
         return False;
      end if;
      for K in 0 .. Prefix'Length - 1 loop
         if To_Upper (S (S'First + K)) /= Prefix (Prefix'First + K) then
            return False;
         end if;
      end loop;
      return True;
   end Starts_With_Prefix;

   function Parse_Headline (Body_Text : String) return String
     with Pre => Body_Text'Last < Integer'Last;
   --  Headline of a summary body: the remainder of a first line that starts
   --  with Prefix, else the whole stripped body flattened to one line.

   function Parse_Headline (Body_Text : String) return String is
      First : Integer;
      Last  : Integer;
   begin
      Strip_Bounds (Body_Text, First, Last);
      if First > Last then
         return "";
      end if;

      --  The first line is Body_Text (First .. Line_Last), the stripped body up
      --  to the first LF. Leading whitespace, LF included, is already gone, so
      --  that line is non-empty.
      declare
         Line_Last : Integer := Last;
      begin
         for I in First .. Last loop
            pragma Loop_Invariant (Line_Last = Last);
            if Body_Text (I) = ASCII.LF then
               Line_Last := I - 1;
               exit;
            end if;
         end loop;

         if Line_Last >= First
           and then Starts_With_Prefix (Body_Text (First .. Line_Last))
         then
            --  Remainder of the first line after Prefix, stripped.
            declare
               RF, RL : Integer;
               Rest   : constant String :=
                 Body_Text (First + Prefix'Length .. Line_Last);
            begin
               Strip_Bounds (Rest, RF, RL);
               if RF > RL then
                  return "";
               end if;
               return Rest (RF .. RL);
            end;
         end if;
      end;

      --  Fallback: whole stripped body, newlines to spaces, capped at
      --  Headline_Cap.
      declare
         Full : String := Body_Text (First .. Last);
         Take : constant Natural :=
           Natural'Min (Full'Length, Headline_Cap);
      begin
         for I in Full'Range loop
            if Full (I) = ASCII.LF then
               Full (I) := ' ';
            end if;
         end loop;
         return Full (Full'First .. Full'First + Take - 1);
      end;
   end Parse_Headline;

   function Recap_Headline (Text : String) return String
     with Pre => Text'Last < Integer'Last;
   --  Headline of an autorecap: Parse_Headline's fallback branch alone, with
   --  no Prefix parsing.

   function Recap_Headline (Text : String) return String is
      First : Integer;
      Last  : Integer;
   begin
      Strip_Bounds (Text, First, Last);
      if First > Last then
         return "";
      end if;
      declare
         Full : String := Text (First .. Last);
         Take : constant Natural := Natural'Min (Full'Length, Headline_Cap);
      begin
         for I in Full'Range loop
            if Full (I) = ASCII.LF then
               Full (I) := ' ';
            end if;
         end loop;
         return Full (Full'First .. Full'First + Take - 1);
      end;
   end Recap_Headline;

   --------------------------------------
   --  Embedding to packed float32 blob
   --------------------------------------

   Blob_Bytes : constant := Embedding_Dim * 4;
   --  Size of a packed embedding: four bytes per float32 component.

   subtype Packed_Blob is Stream_Element_Array (1 .. Blob_Bytes);
   --  One embedding as the bytes sqlite-vec stores in a vec0 column.

   --  The Store and the embedder must agree on the dimension, else the
   --  conversion below would not be size-exact.
   pragma Compile_Time_Error
     (Embedding_Dim /= Candle_Spark.Dimension,
      "Store embedding dimension disagrees with the embedder");

   subtype Store_Embedding is Candle_Spark.Embedding;
   --  Local anchor for To_Blob: gnatprove confirms an unchecked conversion
   --  size-exact and suitable only when the representation is anchored in the
   --  current unit, and flags an instance taken directly on
   --  Candle_Spark.Embedding as "size not confirmed / unsuitable source".
   --  TODO(embed-blob): a workaround rather than an idiom -- there may be a
   --  cleaner spelling, or grounds for a gnatprove report.

   function To_Blob is new Ada.Unchecked_Conversion
     (Store_Embedding, Packed_Blob);
   --  Zero-copy reinterpretation of an embedding as the packed little-endian
   --  float32 blob sqlite-vec stores and compares against.

   -------------------
   -- Insert_Chunks --
   -------------------

   procedure Insert_Chunks
     (S           : Store;
      Session_Row : Row_Id;
      Proj_Id     : Row_Id;
      TS          : String;
      Chunks      : Chunk_Input_List;
      Ok          : out Boolean)
     with Pre => Is_Open (S);
   --  Insert every element of Chunks, body and embedding, against one
   --  session row: shared by Save_Session and Reindex_Session. Ordinal is
   --  the 0-based position within Chunks. Runs inside the caller's
   --  transaction, and Ok is False from the first SQLite failure on.

   procedure Insert_Chunks
     (S           : Store;
      Session_Row : Row_Id;
      Proj_Id     : Row_Id;
      TS          : String;
      Chunks      : Chunk_Input_List;
      Ok          : out Boolean)
   is
   begin
      Ok := True;
      for I in Chunk_Input_Vectors.First_Index (Chunks)
               .. Chunk_Input_Vectors.Last_Index (Chunks)
      loop
         declare
            El   : constant Chunk_Input :=
              Chunk_Input_Vectors.Element (Chunks, I);
            Ord  : constant Row_Id :=
              Row_Id (I - Chunk_Input_Vectors.First_Index (Chunks));
            Blob : constant Packed_Blob := To_Blob (El.Embedding);
            Ins  : Sql.Statement;
            St   : Sql.Status;
            New_Chunk : Row_Id;
         begin
            Sql.Prepare
              (S.DB,
               "INSERT INTO chunks (session_row_id, project_id, ordinal,"
               & " body, created_at) VALUES (?, ?, ?, ?, ?)", Ins, St);
            if St = Sql.Ok then
               Sql.Bind_Int64 (Ins, 1, Session_Row, St);
            end if;
            if St = Sql.Ok then
               Sql.Bind_Int64 (Ins, 2, Proj_Id, St);
            end if;
            if St = Sql.Ok then
               Sql.Bind_Int64 (Ins, 3, Ord, St);
            end if;
            if St = Sql.Ok then
               Sql.Bind_Text (Ins, 4, El.Content, St);
            end if;
            if St = Sql.Ok then
               Sql.Bind_Text (Ins, 5, TS, St);
            end if;
            if St = Sql.Ok then
               Sql.Step (Ins, St);
            end if;
            Sql.Finalize (Ins);

            if St /= Sql.Done then
               Ok := False;
            else
               New_Chunk := Sql.Last_Insert_Rowid (S.DB);
               Sql.Prepare
                 (S.DB,
                  "INSERT INTO chunk_vec (rowid, embedding) VALUES (?, ?)",
                  Ins, St);
               if St = Sql.Ok then
                  Sql.Bind_Int64 (Ins, 1, New_Chunk, St);
               end if;
               if St = Sql.Ok then
                  Sql.Bind_Blob (Ins, 2, Blob, St);
               end if;
               if St = Sql.Ok then
                  Sql.Step (Ins, St);
               end if;
               Sql.Finalize (Ins);
               if St /= Sql.Done then
                  Ok := False;
               end if;
            end if;
         end;
         exit when not Ok;
      end loop;
   end Insert_Chunks;

   ----------------------------
   -- Small statement helpers --
   ----------------------------

   procedure Exec (S : Store; Text : String; Ok : out Boolean)
     with Pre => Is_Open (S)
                 and then Text'Length > 0
                 and then Text'Last < Natural'Last;
   --  Run a resultless statement -- BEGIN, COMMIT, ROLLBACK, simple DML --
   --  as a whole. Ok when SQLite accepted it.

   procedure Exec (S : Store; Text : String; Ok : out Boolean) is
      St : Sql.Status;
   begin
      Sql.Execute (S.DB, Text, St);
      Ok := St = Sql.Ok;
   end Exec;

   procedure Rollback (S : Store)
     with Pre => Is_Open (S);
   --  Abandon the current transaction. A ROLLBACK that itself fails can
   --  leave the database mid-transaction, so it is logged rather than
   --  discarded: callers reach here with nothing left to try.

   procedure Rollback (S : Store) is
      Ok : Boolean;
   begin
      Exec (S, "ROLLBACK", Ok);
      if not Ok then
         Memcp.Log.Error
           ("transaction ROLLBACK failed; database may be left "
            & "mid-transaction");
      end if;
   end Rollback;

   function Placeholders (K : Positive) return String
     with Pre  => K <= Max_Filter_Terms,
          Post => Placeholders'Result'First = 1
                  and then Placeholders'Result'Length = 2 * K - 1;
   --  "?,?,...,?": the parameter list for an IN clause of K bound values,
   --  K '?' separated by K - 1 ','.

   function Placeholders (K : Positive) return String is
      Buf : String (1 .. 2 * K - 1) := [others => '?'];
   begin
      --  Overwrite the even positions with commas; odd positions stay '?'.
      for I in 2 .. K loop
         Buf (2 * I - 2) := ',';
      end loop;
      return Buf;
   end Placeholders;

   function Contains (L : Name_List; Value : String) return Boolean;
   --  Whether Value is one of the names in L, the Ada-side membership test
   --  for the search metadata filters. A full scan; filter lists are tiny.

   function Contains (L : Name_List; Value : String) return Boolean is
      Found : Boolean := False;
   begin
      for I in Name_Vectors.First_Index (L) .. Name_Vectors.Last_Index (L) loop
         if Name_Vectors.Element (L, I).Value = Value then
            Found := True;
         end if;
      end loop;
      return Found;
   end Contains;

   -----------------
   -- Project_Id  --
   -----------------

   procedure Project_Id
     (S : Store; Name : String; Id : out Row_Id; Status : out Op_Status)
     with Pre => Is_Open (S);
   --  The id of the project named Name, inserting the projects row when it
   --  does not exist yet.

   procedure Project_Id
     (S : Store; Name : String; Id : out Row_Id; Status : out Op_Status)
   is
      Stmt : Sql.Statement;
      St   : Sql.Status;
   begin
      Id     := 0;
      Status := Db_Error;

      Sql.Prepare (S.DB, "SELECT id FROM projects WHERE name = ?", Stmt, St);
      if St /= Sql.Ok then
         return;
      end if;
      Sql.Bind_Text (Stmt, 1, Name, St);
      if St = Sql.Ok then
         Sql.Step (Stmt, St);
         if St = Sql.Row then
            Id     := Sql.Column_Int64 (Stmt, 0);
            Status := Success;
            Sql.Finalize (Stmt);
            return;
         end if;
      end if;
      Sql.Finalize (Stmt);
      if St /= Sql.Done then
         return;   --  a genuine error, not "no such project"
      end if;

      --  Not present: insert it.
      Sql.Prepare (S.DB, "INSERT INTO projects (name) VALUES (?)", Stmt, St);
      if St /= Sql.Ok then
         return;
      end if;
      Sql.Bind_Text (Stmt, 1, Name, St);
      if St = Sql.Ok then
         Sql.Step (Stmt, St);
      end if;
      Sql.Finalize (Stmt);
      if St = Sql.Done then
         Id     := Sql.Last_Insert_Rowid (S.DB);
         Status := Success;
      end if;
   end Project_Id;

   ----------------
   -- Add_Column --
   ----------------

   procedure Add_Column
     (S : Store; Table, Column, Decl : String; Ok : out Boolean)
     with Pre => Is_Open (S)
                 --  Bounded so the ALTER built below cannot overflow; every
                 --  caller passes a literal well inside these.
                 and then Table'Length in 1 .. 64
                 and then Column'Length in 1 .. 64
                 and then Decl'Length in 1 .. 128;
   --  Add Column to Table when it is absent, leaving an already-migrated
   --  database untouched. Absence is established first so that a failing ALTER
   --  is a real error rather than the expected duplicate-column refusal.

   procedure Add_Column
     (S : Store; Table, Column, Decl : String; Ok : out Boolean)
   is
      Stmt    : Sql.Statement;
      St      : Sql.Status;
      Present : Boolean := False;
   begin
      Ok := False;

      Sql.Prepare
        (S.DB,
         "SELECT 1 FROM pragma_table_info(?) WHERE name = ?", Stmt, St);
      if St /= Sql.Ok then
         return;
      end if;
      Sql.Bind_Text (Stmt, 1, Table, St);
      if St = Sql.Ok then
         Sql.Bind_Text (Stmt, 2, Column, St);
      end if;
      if St = Sql.Ok then
         Sql.Step (Stmt, St);
         Present := St = Sql.Row;
      end if;
      Sql.Finalize (Stmt);
      if St /= Sql.Row and then St /= Sql.Done then
         return;
      end if;

      if Present then
         Ok := True;
      else
         Exec
           (S, "ALTER TABLE " & Table & " ADD COLUMN " & Column & " " & Decl,
            Ok);
      end if;
   end Add_Column;

   --------------------
   -- Surface_Row_Id --
   --------------------

   procedure Surface_Row_Id
     (S      : Store;
      Uuid   : String;
      Label  : String;
      Now    : String;
      Id     : out Row_Id;
      Status : out Op_Status)
     with Pre => Is_Open (S);
   --  The id of the surfaces row for Uuid, inserting it when new and
   --  refreshing its label and last_seen when not. An empty Uuid is the
   --  unattributed write: Id comes back 0, which every caller binds as NULL.

   procedure Surface_Row_Id
     (S      : Store;
      Uuid   : String;
      Label  : String;
      Now    : String;
      Id     : out Row_Id;
      Status : out Op_Status)
   is
      Stmt  : Sql.Statement;
      St    : Sql.Status;
      Found : Boolean := False;
   begin
      Id     := 0;
      Status := Success;

      if Uuid'Length = 0 then
         return;
      end if;
      Status := Db_Error;

      Sql.Prepare
        (S.DB, "SELECT id FROM surfaces WHERE surface_id = ?", Stmt, St);
      if St /= Sql.Ok then
         return;
      end if;
      Sql.Bind_Text (Stmt, 1, Uuid, St);
      if St = Sql.Ok then
         Sql.Step (Stmt, St);
         if St = Sql.Row then
            Found := True;
            Id    := Sql.Column_Int64 (Stmt, 0);
         end if;
      end if;
      Sql.Finalize (Stmt);
      if St /= Sql.Row and then St /= Sql.Done then
         Id := 0;
         return;
      end if;

      if Found then
         --  The label is config on the surface, so the newest write wins.
         Sql.Prepare
           (S.DB,
            "UPDATE surfaces SET label = ?, last_seen = ? WHERE id = ?",
            Stmt, St);
         if St = Sql.Ok then
            Sql.Bind_Text (Stmt, 1, Label, St);
            if St = Sql.Ok then
               Sql.Bind_Text (Stmt, 2, Now, St);
            end if;
            if St = Sql.Ok then
               Sql.Bind_Int64 (Stmt, 3, Id, St);
            end if;
            if St = Sql.Ok then
               Sql.Step (Stmt, St);
            end if;
         end if;
      else
         Sql.Prepare
           (S.DB,
            "INSERT INTO surfaces (surface_id, label, first_seen, last_seen)"
            & " VALUES (?, ?, ?, ?)", Stmt, St);
         if St = Sql.Ok then
            Sql.Bind_Text (Stmt, 1, Uuid, St);
            if St = Sql.Ok then
               Sql.Bind_Text (Stmt, 2, Label, St);
            end if;
            if St = Sql.Ok then
               Sql.Bind_Text (Stmt, 3, Now, St);
            end if;
            if St = Sql.Ok then
               Sql.Bind_Text (Stmt, 4, Now, St);
            end if;
            if St = Sql.Ok then
               Sql.Step (Stmt, St);
            end if;
         end if;
      end if;
      Sql.Finalize (Stmt);

      if St = Sql.Done then
         if not Found then
            Id := Sql.Last_Insert_Rowid (S.DB);
         end if;
         Status := Success;
      else
         Id := 0;
      end if;
   end Surface_Row_Id;

   ------------------
   -- Bind_Surface --
   ------------------

   procedure Bind_Surface
     (Stmt : Sql.Statement; Index : Positive; Id : Row_Id; St : out Sql.Status);
   --  Bind the surfaces-row id at Index, or NULL for the unattributed write.

   procedure Bind_Surface
     (Stmt : Sql.Statement; Index : Positive; Id : Row_Id; St : out Sql.Status)
   is
   begin
      if Id = 0 then
         Sql.Bind_Null (Stmt, Index, St);
      else
         Sql.Bind_Int64 (Stmt, Index, Id, St);
      end if;
   end Bind_Surface;

   ----------
   -- Open --
   ----------

   procedure Open
     (S : out Store; DB_Path : String; Result : out Open_Status)
   is
      St : Sql.Status;
      Ok : Boolean;

      procedure Assert_Meta (Key, Value : String; Outcome : out Open_Status);
      --  Assert one meta (key, value) pair: insert it when absent, and
      --  report Meta_Mismatch when the stored value differs.

      procedure Assert_Meta (Key, Value : String; Outcome : out Open_Status) is
         Stmt : Sql.Statement;
         MSt  : Sql.Status;
      begin
         Outcome := Schema_Error;
         Sql.Prepare (S.DB, "SELECT value FROM meta WHERE key = ?", Stmt, MSt);
         if MSt /= Sql.Ok then
            return;
         end if;
         Sql.Bind_Text (Stmt, 1, Key, MSt);
         if MSt /= Sql.Ok then
            Sql.Finalize (Stmt);
            return;
         end if;
         Sql.Step (Stmt, MSt);
         if MSt = Sql.Row then
            declare
               Existing : Sql.Text_Ptr := Sql.Column_Text (Stmt, 0);
               Matches  : constant Boolean := Existing.all = Value;
            begin
               Sql.Free (Existing);
               Sql.Finalize (Stmt);
               Outcome := (if Matches then Opened else Meta_Mismatch);
            end;
            return;
         end if;
         Sql.Finalize (Stmt);
         if MSt /= Sql.Done then
            return;
         end if;

         --  Absent: insert the default.
         Sql.Prepare
           (S.DB, "INSERT INTO meta (key, value) VALUES (?, ?)", Stmt, MSt);
         if MSt /= Sql.Ok then
            return;
         end if;
         Sql.Bind_Text (Stmt, 1, Key, MSt);
         if MSt = Sql.Ok then
            Sql.Bind_Text (Stmt, 2, Value, MSt);
         end if;
         if MSt = Sql.Ok then
            Sql.Step (Stmt, MSt);
         end if;
         Sql.Finalize (Stmt);
         Outcome := (if MSt = Sql.Done then Opened else Schema_Error);
      end Assert_Meta;

      Dim_Image : constant String := "384";
      --  Embedding_Dim as the text the embedding_dim meta row carries.
   begin
      --  Initialize the owning field before S is read anywhere; the real path
      --  goes in only once the store is fully Opened, below.
      S.DB_Path := null;

      Sql.Open (S.DB, DB_Path, St);
      if St /= Sql.Ok then
         Result := Cannot_Open;
         return;
      end if;

      Exec (S, Schema_SQL, Ok);
      if Ok then
         Exec (S, Vec_Summary_SQL, Ok);
      end if;
      if Ok then
         Exec (S, Vec_Chunk_SQL, Ok);
      end if;
      if Ok then
         Add_Column
           (S, "summaries", "surface_row_id",
            "INTEGER REFERENCES surfaces(id)", Ok);
      end if;
      if Ok then
         Add_Column
           (S, "sessions", "surface_row_id",
            "INTEGER REFERENCES surfaces(id)", Ok);
      end if;
      if not Ok then
         Sql.Close (S.DB);
         Result := Schema_Error;
         return;
      end if;

      Assert_Meta ("schema_version", Schema_Version, Result);
      if Result = Opened then
         Assert_Meta ("embedding_model", Embedding_Model, Result);
      end if;
      if Result = Opened then
         Assert_Meta ("embedding_dim", Dim_Image, Result);
      end if;

      if Result /= Opened then
         Sql.Close (S.DB);
      else
         --  Remember the path so Save_Session can anchor its sessions
         --  directory on it.
         S.DB_Path := new String'(DB_Path);
      end if;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (S : in out Store) is
   begin
      Free_Path (S.DB_Path);
      Sql.Close (S.DB);
   end Close;

   -------------------
   -- Fetch_Summary --
   -------------------

   Fetch_Summary_SQL : constant String :=
     "SELECT s.id, p.name, s.session_id, s.created_at, s.headline,"
     & " s.body, s.kind FROM summaries s"
     & " JOIN projects p ON p.id = s.project_id WHERE s.id = ?";
   --  One summaries row by id, with its project name. Also driven per candidate
   --  by Search_Summaries.

   procedure Fetch_Summary
     (S      : Store;
      Id     : Row_Id;
      Result : out Summary_Ptr;
      Status : out Op_Status)
   is
      Stmt : Sql.Statement;
      St   : Sql.Status;
   begin
      Result := null;
      Status := Db_Error;

      Sql.Prepare (S.DB, Fetch_Summary_SQL, Stmt, St);
      if St /= Sql.Ok then
         return;
      end if;
      Sql.Bind_Int64 (Stmt, 1, Id, St);
      if St /= Sql.Ok then
         Sql.Finalize (Stmt);
         return;
      end if;

      Sql.Step (Stmt, St);
      if St = Sql.Row then
         declare
            Proj : Sql.Text_Ptr := Sql.Column_Text (Stmt, 1);
            Sess : Sql.Text_Ptr := Sql.Column_Text (Stmt, 2);
            Crea : Sql.Text_Ptr := Sql.Column_Text (Stmt, 3);
            Head : Sql.Text_Ptr := Sql.Column_Text (Stmt, 4);
            Bod  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 5);
            Kind : Sql.Text_Ptr := Sql.Column_Text (Stmt, 6);
            Null_S : constant Boolean := Sql.Column_Is_Null (Stmt, 2);
            Has_S  : constant Boolean := not Null_S;
            --  A volatile column read may not be an operand of `not`, nor
            --  appear in an aggregate; hence the two steps here.
            Id_C   : constant Row_Id := Sql.Column_Int64 (Stmt, 0);
         begin
            Result := new Summary'
              (Project_Len  => Proj.all'Length,
               Session_Len  => Sess.all'Length,
               Created_Len  => Crea.all'Length,
               Headline_Len => Head.all'Length,
               Body_Len     => Bod.all'Length,
               Kind_Len     => Kind.all'Length,
               Id           => Id_C,
               Has_Session  => Has_S,
               Project      => Proj.all,
               Session      => Sess.all,
               Created_At   => Crea.all,
               Headline     => Head.all,
               Content      => Bod.all,
               Kind         => Kind.all);
            Sql.Free (Proj);
            Sql.Free (Sess);
            Sql.Free (Crea);
            Sql.Free (Head);
            Sql.Free (Bod);
            Sql.Free (Kind);
         end;
         Status := Success;
      elsif St = Sql.Done then
         Status := Success;   --  no such id: Result stays null
      end if;

      Sql.Finalize (Stmt);
   end Fetch_Summary;

   ------------------
   -- Recent_Diary --
   ------------------

   procedure Recent_Diary
     (S        : Store;
      Projects : Name_List;
      N        : Natural;
      Result   : out Diary_Entry_List;
      Status   : out Op_Status)
   is
      Len_CT : constant Name_Vectors.Capacity_Range :=
        Name_Vectors.Length (Projects);
   begin
      Result := Diary_Vectors.Empty_Vector;
      Status := Db_Error;

      --  No projects, or a filter too long to spell as a bounded IN clause:
      --  both return an empty list with Success.
      if Len_CT = 0 or else Len_CT > Max_Filter_Terms then
         Status := Success;
         return;
      end if;

      declare
         K     : constant Positive := Positive (Len_CT);
         Query : constant String :=
           "SELECT d.id, p.name, d.summary_id, s.session_id, d.created_at,"
           & " d.body, s.headline, s.kind FROM diary d"
           & " JOIN projects p ON p.id = d.project_id"
           & " JOIN summaries s ON s.id = d.summary_id"
           & " WHERE p.name IN (" & Placeholders (K) & ")"
           & " ORDER BY d.created_at DESC LIMIT ?";
         Stmt  : Sql.Statement;
         St    : Sql.Status;
      begin
         Sql.Prepare (S.DB, Query, Stmt, St);
         if St /= Sql.Ok then
            return;
         end if;

         --  The K project names go to params 1 .. K, the 1-based vector index
         --  doubling as the bind position, and N to the LIMIT param at K + 1.
         for I in Name_Vectors.First_Index (Projects)
                  .. Name_Vectors.Last_Index (Projects)
         loop
            Sql.Bind_Text
              (Stmt, I, Name_Vectors.Element (Projects, I).Value, St);
            exit when St /= Sql.Ok;
         end loop;
         if St = Sql.Ok then
            Sql.Bind_Int64 (Stmt, K + 1, Row_Id (N), St);
         end if;
         if St /= Sql.Ok then
            Sql.Finalize (Stmt);
            return;
         end if;

         --  One Diary_Entry per row; the Length guard discharges Append's
         --  capacity precondition.
         loop
            Sql.Step (Stmt, St);
            exit when St /= Sql.Row;
            exit when Diary_Vectors.Length (Result) = Diary_Vectors.Last_Count;
            declare
               Id_C  : constant Row_Id := Sql.Column_Int64 (Stmt, 0);
               Sid_C : constant Row_Id := Sql.Column_Int64 (Stmt, 2);
               Proj  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 1);
               Sess  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 3);
               Crea  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 4);
               Bod   : Sql.Text_Ptr := Sql.Column_Text (Stmt, 5);
               Head  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 6);
               Kind  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 7);
               Null_S : constant Boolean := Sql.Column_Is_Null (Stmt, 3);
               Has_S  : constant Boolean := not Null_S;
               --  Two steps, as in Fetch_Summary: a volatile column read may
               --  not be an operand of `not`.
            begin
               Diary_Vectors.Append
                 (Result,
                  Diary_Entry'
                    (Project_Len  => Proj.all'Length,
                     Session_Len  => Sess.all'Length,
                     Created_Len  => Crea.all'Length,
                     Body_Len     => Bod.all'Length,
                     Headline_Len => Head.all'Length,
                     Kind_Len     => Kind.all'Length,
                     Id           => Id_C,
                     Summary_Id   => Sid_C,
                     Has_Session  => Has_S,
                     Project      => Proj.all,
                     Session      => Sess.all,
                     Created_At   => Crea.all,
                     Content      => Bod.all,
                     Headline     => Head.all,
                     Kind         => Kind.all));
               Sql.Free (Proj);
               Sql.Free (Sess);
               Sql.Free (Crea);
               Sql.Free (Bod);
               Sql.Free (Head);
               Sql.Free (Kind);
            end;
         end loop;

         Sql.Finalize (Stmt);
         if St = Sql.Done then
            Status := Success;
         end if;
      end;
   end Recent_Diary;

   -------------------
   -- List_Projects --
   -------------------

   procedure List_Projects
     (S      : Store;
      Result : out Project_Info_List;
      Status : out Op_Status)
   is
      Query : constant String :=
        "SELECT p.name, COUNT(d.id), MAX(d.created_at)"
        & " FROM projects p LEFT JOIN diary d ON d.project_id = p.id"
        & " GROUP BY p.id, p.name"
        & " ORDER BY MAX(d.created_at) IS NULL,"
        & " MAX(d.created_at) DESC, p.name";
      Stmt : Sql.Statement;
      St   : Sql.Status;
   begin
      Result := Project_Vectors.Empty_Vector;
      Status := Db_Error;

      Sql.Prepare (S.DB, Query, Stmt, St);
      if St /= Sql.Ok then
         return;
      end if;

      loop
         Sql.Step (Stmt, St);
         exit when St /= Sql.Row;
         exit when
           Project_Vectors.Length (Result) = Project_Vectors.Last_Count;
         declare
            Cnt   : constant Row_Id := Sql.Column_Int64 (Stmt, 1);
            Nm    : Sql.Text_Ptr := Sql.Column_Text (Stmt, 0);
            Lat   : Sql.Text_Ptr := Sql.Column_Text (Stmt, 2);
            Null_L : constant Boolean := Sql.Column_Is_Null (Stmt, 2);
            Has_L  : constant Boolean := not Null_L;
            --  Two steps, as in Fetch_Summary: a volatile column read may not
            --  be an operand of `not`.
         begin
            Project_Vectors.Append
              (Result,
               Project_Info'
                 (Name_Len    => Nm.all'Length,
                  Latest_Len  => Lat.all'Length,
                  Diary_Count => Cnt,
                  Has_Latest  => Has_L,
                  Name        => Nm.all,
                  Latest_At   => Lat.all));
            Sql.Free (Nm);
            Sql.Free (Lat);
         end;
      end loop;

      Sql.Finalize (Stmt);
      if St = Sql.Done then
         Status := Success;
      end if;
   end List_Projects;

   -----------------------
   -- Degraded_Surfaces --
   -----------------------

   procedure Degraded_Surfaces
     (S      : Store;
      Window : Positive;
      Least  : Positive;
      Result : out Surface_Health_List;
      Status : out Op_Status)
   is
      Query : constant String :=
        "WITH ranked AS ("
        & " SELECT m.surface_row_id AS srf, m.project_id AS pid,"
        & " m.session_id AS sid,"
        & " ROW_NUMBER() OVER (PARTITION BY m.surface_row_id"
        & " ORDER BY m.created_at DESC) AS rn"
        & " FROM summaries m WHERE m.session_id IS NOT NULL)"
        & " SELECT f.label, f.surface_id, COUNT(DISTINCT r.sid),"
        & " COUNT(DISTINCT CASE WHEN x.id IS NULL THEN r.sid END)"
        & " FROM ranked r"
        & " LEFT JOIN surfaces f ON f.id = r.srf"
        & " LEFT JOIN sessions x"
        & " ON x.project_id = r.pid AND x.session_id = r.sid"
        & " WHERE r.rn <= ?"
        & " GROUP BY r.srf"
        & " HAVING COUNT(DISTINCT CASE WHEN x.id IS NULL THEN r.sid END) >= ?"
        & " ORDER BY 4 DESC";
      --  A summary whose session has no sessions row is a session that saved
      --  and was never uploaded. PARTITION BY collects the rows carrying no
      --  surface into one group, the same way GROUP BY does, so they are
      --  windowed and reported together rather than each standing alone.

      Stmt : Sql.Statement;
      St   : Sql.Status;
   begin
      Result := Surface_Health_Vectors.Empty_Vector;
      Status := Db_Error;

      Sql.Prepare (S.DB, Query, Stmt, St);
      if St /= Sql.Ok then
         return;
      end if;

      Sql.Bind_Int64 (Stmt, 1, Row_Id (Window), St);
      if St = Sql.Ok then
         Sql.Bind_Int64 (Stmt, 2, Row_Id (Least), St);
      end if;
      if St /= Sql.Ok then
         Sql.Finalize (Stmt);
         return;
      end if;

      loop
         Sql.Step (Stmt, St);
         exit when St /= Sql.Row;
         exit when Surface_Health_Vectors.Length (Result)
                   = Surface_Health_Vectors.Last_Count;
         declare
            Sess_C : constant Row_Id := Sql.Column_Int64 (Stmt, 2);
            Miss_C : constant Row_Id := Sql.Column_Int64 (Stmt, 3);
            Lab    : Sql.Text_Ptr := Sql.Column_Text (Stmt, 0);
            Uid    : Sql.Text_Ptr := Sql.Column_Text (Stmt, 1);
            Null_L : constant Boolean := Sql.Column_Is_Null (Stmt, 0);
            Attr   : constant Boolean := not Null_L;
            --  Two steps, as in Recent_Diary: a volatile column read may not
            --  be an operand of `not`.
         begin
            Surface_Health_Vectors.Append
              (Result,
               Surface_Health'
                 (Label_Len  => Lab.all'Length,
                  Uuid_Len   => Uid.all'Length,
                  Attributed => Attr,
                  Sessions   => Sess_C,
                  Missing    => Miss_C,
                  Label      => Lab.all,
                  Uuid       => Uid.all));
            Sql.Free (Lab);
            Sql.Free (Uid);
         end;
      end loop;

      Sql.Finalize (Stmt);
      if St = Sql.Done then
         Status := Success;
      end if;
   end Degraded_Surfaces;

   -------------------
   -- Touch_Surface --
   -------------------

   procedure Touch_Surface
     (S      : Store;
      Uuid   : String;
      Label  : String;
      Status : out Op_Status)
   is
      Id : Row_Id;
   begin
      Surface_Row_Id (S, Uuid, Label, Now_Iso, Id, Status);

      --  Id is 0 only for the empty Uuid, which is the caller asking for
      --  nothing. A named surface that resolved to no row means the upsert
      --  reported a success it did not achieve.
      if Status = Success and then Uuid'Length > 0 and then Id = 0 then
         Status := Db_Error;
      end if;
   end Touch_Surface;

   -----------------
   -- Fetch_Turns --
   -----------------

   procedure Fetch_Turns
     (S           : Store;
      Session_Id  : String;
      Has_Project : Boolean;
      Project     : String;
      Has_Start   : Boolean;
      Start_Ord   : Row_Id;
      Has_End     : Boolean;
      End_Ord     : Row_Id;
      Has_Tail    : Boolean;
      Tail        : Positive;
      Result      : out Chunk_List;
      Status      : out Op_Status)
   is
      Where_SQL : constant String :=
        " WHERE s.session_id = ?"
        & (if Has_Project then " AND p.name = ?" else "")
        & (if Has_Start then " AND c.ordinal >= ?" else "")
        & (if Has_End then " AND c.ordinal < ?" else "");
      --  The session_id filter, plus whichever optional filters are present.

      Sel : constant String :=
        "SELECT c.id AS id, c.session_row_id AS srid, p.name AS project,"
        & " c.ordinal AS ordinal, c.body AS body, c.created_at AS created_at"
        & " FROM chunks c JOIN projects p ON p.id = c.project_id"
        & " JOIN sessions s ON s.id = c.session_row_id"
        & Where_SQL;
      --  The inner SELECT. Columns are aliased so the tail form below can name
      --  them again in an outer query.

      Query : constant String :=
        (if Has_Tail
         then "SELECT id, srid, project, ordinal, body, created_at FROM ("
              & Sel & " ORDER BY ordinal DESC LIMIT ?) ORDER BY ordinal ASC"
         else Sel & " ORDER BY ordinal ASC");
      --  Rows in ascending ordinal either way: the tail form takes the last
      --  Tail rows with DESC + LIMIT and SQLite re-sorts them ascending, so
      --  nothing is reversed on the Ada side.

      Stmt : Sql.Statement;
      St   : Sql.Status;

      P_Project : constant Positive := 2;
      --  Placeholder of " AND p.name = ?", right after the session_id one.

      P_Start : constant Positive := P_Project + Boolean'Pos (Has_Project);
      --  Placeholder of " AND c.ordinal >= ?", which moves up only past those
      --  optional filters Where_SQL actually emitted ahead of it.

      P_End : constant Positive := P_Start + Boolean'Pos (Has_Start);
      --  Placeholder of " AND c.ordinal < ?".

      P_Tail : constant Positive := P_End + Boolean'Pos (Has_End);
      --  Placeholder of the tail form's LIMIT, last in either query.

      Placeholder_Count : constant Positive :=
        1 + Boolean'Pos (Has_Project) + Boolean'Pos (Has_Start)
        + Boolean'Pos (Has_End) + Boolean'Pos (Has_Tail);
      --  How many placeholders Query holds, summed from the flags rather than
      --  accumulated along the chain above.

      pragma Assert (P_Tail + Boolean'Pos (Has_Tail) = Placeholder_Count + 1);
      --  Checks that the chain of positions lands exactly one past the last
      --  placeholder, against a total derived the other way. A position that
      --  advances for an absent filter, or holds still for a present one, makes
      --  the two disagree.
   begin
      Result := Chunk_Vectors.Empty_Vector;
      Status := Db_Error;

      Sql.Prepare (S.DB, Query, Stmt, St);
      if St /= Sql.Ok then
         return;
      end if;

      Sql.Bind_Text (Stmt, 1, Session_Id, St);
      if St = Sql.Ok and then Has_Project then
         Sql.Bind_Text (Stmt, P_Project, Project, St);
      end if;
      if St = Sql.Ok and then Has_Start then
         Sql.Bind_Int64 (Stmt, P_Start, Start_Ord, St);
      end if;
      if St = Sql.Ok and then Has_End then
         Sql.Bind_Int64 (Stmt, P_End, End_Ord, St);
      end if;
      if St = Sql.Ok and then Has_Tail then
         Sql.Bind_Int64 (Stmt, P_Tail, Row_Id (Tail), St);
      end if;
      if St /= Sql.Ok then
         Sql.Finalize (Stmt);
         return;
      end if;

      loop
         Sql.Step (Stmt, St);
         exit when St /= Sql.Row;
         exit when Chunk_Vectors.Length (Result) = Chunk_Vectors.Last_Count;
         declare
            Id_C  : constant Row_Id := Sql.Column_Int64 (Stmt, 0);
            Sr_C  : constant Row_Id := Sql.Column_Int64 (Stmt, 1);
            Ord_C : constant Row_Id := Sql.Column_Int64 (Stmt, 3);
            Proj  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 2);
            Bod   : Sql.Text_Ptr := Sql.Column_Text (Stmt, 4);
            Crea  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 5);
         begin
            Chunk_Vectors.Append
              (Result,
               Chunk'
                 (Project_Len    => Proj.all'Length,
                  Body_Len       => Bod.all'Length,
                  Created_Len    => Crea.all'Length,
                  Id             => Id_C,
                  Session_Row_Id => Sr_C,
                  Ordinal        => Ord_C,
                  Project        => Proj.all,
                  Content        => Bod.all,
                  Created_At     => Crea.all));
            Sql.Free (Proj);
            Sql.Free (Bod);
            Sql.Free (Crea);
         end;
      end loop;

      Sql.Finalize (Stmt);
      if St = Sql.Done then
         Status := Success;
      end if;
   end Fetch_Turns;

   ---------------------
   -- Search_Summaries --
   ---------------------

   procedure Search_Summaries
     (S         : Store;
      Query_Emb : Candle_Spark.Embedding;
      Projects  : Name_List;
      Limit     : Natural;
      Has_Since : Boolean;
      Since     : String;
      Has_Until : Boolean;
      Until_At  : String;
      Result    : out Summary_Hit_List;
      Status    : out Op_Status)
   is
      Blob        : constant Packed_Blob := To_Blob (Query_Emb);
      Len_P       : constant Name_Vectors.Capacity_Range :=
        Name_Vectors.Length (Projects);
      Has_Filters : constant Boolean :=
        Len_P > 0 or else Has_Since or else Has_Until;
      Lim         : constant Natural := Natural'Min (Limit, Max_Search_Limit);
      Over        : constant Natural := (if Has_Filters then Lim * 5 else Lim);
      K1          : Sql.Statement;
      St          : Sql.Status;
      Count       : Natural := 0;
      Failed      : Boolean := False;
   begin
      Result := Summary_Hit_Vectors.Empty_Vector;
      Status := Db_Error;

      if Lim = 0 or else Len_P > Max_Filter_Terms then
         Status := Success;
         return;
      end if;

      Sql.Prepare
        (S.DB,
         "SELECT rowid, distance FROM summary_vec"
         & " WHERE embedding MATCH ? ORDER BY distance LIMIT ?", K1, St);
      if St /= Sql.Ok then
         return;
      end if;
      Sql.Bind_Blob (K1, 1, Blob, St);
      if St = Sql.Ok then
         Sql.Bind_Int64 (K1, 2, Row_Id (Over), St);
      end if;
      if St /= Sql.Ok then
         Sql.Finalize (K1);
         return;
      end if;

      --  One prepared per-row fetch, reset and rebound between candidates: the
      --  filtered over-fetch runs to Lim * 5 rows.
      declare
         M   : Sql.Statement;
         MSt : Sql.Status;
      begin
         Sql.Prepare (S.DB, Fetch_Summary_SQL, M, MSt);
         if MSt /= Sql.Ok then
            Sql.Finalize (K1);
            return;
         end if;

         loop
            Sql.Step (K1, St);
            exit when St /= Sql.Row;
            exit when Count >= Lim;
            exit when Summary_Hit_Vectors.Length (Result)
                      = Summary_Hit_Vectors.Last_Count;
            declare
               Rid  : constant Row_Id := Sql.Column_Int64 (K1, 0);
               Dist : constant Interfaces.IEEE_Float_64 :=
                 Sql.Column_Double (K1, 1);
            begin
               Sql.Reset (M, MSt);
               if MSt = Sql.Ok then
                  Sql.Bind_Int64 (M, 1, Rid, MSt);
               end if;
               if MSt = Sql.Ok then
                  Sql.Step (M, MSt);
               end if;
               if MSt = Sql.Row then
                  declare
                     Proj  : Sql.Text_Ptr := Sql.Column_Text (M, 1);
                     Sess  : Sql.Text_Ptr := Sql.Column_Text (M, 2);
                     Crea  : Sql.Text_Ptr := Sql.Column_Text (M, 3);
                     Head  : Sql.Text_Ptr := Sql.Column_Text (M, 4);
                     Bod   : Sql.Text_Ptr := Sql.Column_Text (M, 5);
                     Kind  : Sql.Text_Ptr := Sql.Column_Text (M, 6);
                     Null_S : constant Boolean := Sql.Column_Is_Null (M, 2);
                     Has_S  : constant Boolean := not Null_S;
                     --  Two steps, as in Fetch_Summary: a volatile column read
                     --  may not be an operand of `not`.
                     Passes : constant Boolean :=
                       (Len_P = 0 or else Contains (Projects, Proj.all))
                       and then (not Has_Since or else Crea.all >= Since)
                       and then (not Has_Until or else Crea.all <= Until_At);
                  begin
                     if Passes then
                        Summary_Hit_Vectors.Append
                          (Result,
                           Summary_Hit'
                             (Project_Len  => Proj.all'Length,
                              Session_Len  => Sess.all'Length,
                              Created_Len  => Crea.all'Length,
                              Headline_Len => Head.all'Length,
                              Body_Len     => Bod.all'Length,
                              Kind_Len     => Kind.all'Length,
                              Id           => Rid,
                              Has_Session  => Has_S,
                              Project      => Proj.all,
                              Session      => Sess.all,
                              Created_At   => Crea.all,
                              Headline     => Head.all,
                              Content      => Bod.all,
                              Kind         => Kind.all,
                              Distance     => Dist));
                        Count := Count + 1;
                     end if;
                     Sql.Free (Proj);
                     Sql.Free (Sess);
                     Sql.Free (Crea);
                     Sql.Free (Head);
                     Sql.Free (Bod);
                     Sql.Free (Kind);
                  end;
               end if;
               if MSt /= Sql.Row and then MSt /= Sql.Done then
                  Failed := True;
               end if;
            end;
            exit when Failed;
         end loop;

         Sql.Finalize (M);
      end;

      Sql.Finalize (K1);
      --  Done means the candidates were exhausted, Row that the loop stopped
      --  early with enough hits or at capacity: both are success, and any other
      --  Step code is a failure.
      if not Failed and then (St = Sql.Done or else St = Sql.Row) then
         Status := Success;
      end if;
   end Search_Summaries;

   -------------------
   -- Search_Chunks --
   -------------------

   Chunk_By_Id_SQL : constant String :=
     "SELECT c.id, c.session_row_id, p.name, c.ordinal, c.body,"
     & " c.created_at, s.session_id FROM chunks c"
     & " JOIN projects p ON p.id = c.project_id"
     & " JOIN sessions s ON s.id = c.session_row_id WHERE c.id = ?";
   --  One chunks row by id, with its project and session ids.

   procedure Search_Chunks
     (S           : Store;
      Query_Emb   : Candle_Spark.Embedding;
      Projects    : Name_List;
      Session_Ids : Name_List;
      Limit       : Natural;
      Has_Since   : Boolean;
      Since       : String;
      Has_Until   : Boolean;
      Until_At    : String;
      Result      : out Chunk_Hit_List;
      Status      : out Op_Status)
   is
      Blob        : constant Packed_Blob := To_Blob (Query_Emb);
      Len_P       : constant Name_Vectors.Capacity_Range :=
        Name_Vectors.Length (Projects);
      Len_S       : constant Name_Vectors.Capacity_Range :=
        Name_Vectors.Length (Session_Ids);
      Has_Filters : constant Boolean :=
        Len_P > 0 or else Len_S > 0 or else Has_Since or else Has_Until;
      Lim         : constant Natural := Natural'Min (Limit, Max_Search_Limit);
      Over        : constant Natural := (if Has_Filters then Lim * 5 else Lim);
      K1          : Sql.Statement;
      St          : Sql.Status;
      Count       : Natural := 0;
      Failed      : Boolean := False;
   begin
      Result := Chunk_Hit_Vectors.Empty_Vector;
      Status := Db_Error;

      if Lim = 0
        or else Len_P > Max_Filter_Terms
        or else Len_S > Max_Filter_Terms
      then
         Status := Success;
         return;
      end if;

      Sql.Prepare
        (S.DB,
         "SELECT rowid, distance FROM chunk_vec"
         & " WHERE embedding MATCH ? ORDER BY distance LIMIT ?", K1, St);
      if St /= Sql.Ok then
         return;
      end if;
      Sql.Bind_Blob (K1, 1, Blob, St);
      if St = Sql.Ok then
         Sql.Bind_Int64 (K1, 2, Row_Id (Over), St);
      end if;
      if St /= Sql.Ok then
         Sql.Finalize (K1);
         return;
      end if;

      --  One prepared per-row fetch, reset and rebound between candidates, as
      --  in Search_Summaries.
      declare
         M   : Sql.Statement;
         MSt : Sql.Status;
      begin
         Sql.Prepare (S.DB, Chunk_By_Id_SQL, M, MSt);
         if MSt /= Sql.Ok then
            Sql.Finalize (K1);
            return;
         end if;

         loop
            Sql.Step (K1, St);
            exit when St /= Sql.Row;
            exit when Count >= Lim;
            exit when Chunk_Hit_Vectors.Length (Result)
                      = Chunk_Hit_Vectors.Last_Count;
            declare
               Rid  : constant Row_Id := Sql.Column_Int64 (K1, 0);
               Dist : constant Interfaces.IEEE_Float_64 :=
                 Sql.Column_Double (K1, 1);
            begin
               Sql.Reset (M, MSt);
               if MSt = Sql.Ok then
                  Sql.Bind_Int64 (M, 1, Rid, MSt);
               end if;
               if MSt = Sql.Ok then
                  Sql.Step (M, MSt);
               end if;
               if MSt = Sql.Row then
                  declare
                     Sr_C  : constant Row_Id := Sql.Column_Int64 (M, 1);
                     Ord_C : constant Row_Id := Sql.Column_Int64 (M, 3);
                     Proj  : Sql.Text_Ptr := Sql.Column_Text (M, 2);
                     Bod   : Sql.Text_Ptr := Sql.Column_Text (M, 4);
                     Crea  : Sql.Text_Ptr := Sql.Column_Text (M, 5);
                     Sess  : Sql.Text_Ptr := Sql.Column_Text (M, 6);
                     Passes : constant Boolean :=
                       (Len_P = 0 or else Contains (Projects, Proj.all))
                       and then
                         (Len_S = 0 or else Contains (Session_Ids, Sess.all))
                       and then (not Has_Since or else Crea.all >= Since)
                       and then (not Has_Until or else Crea.all <= Until_At);
                  begin
                     if Passes then
                        Chunk_Hit_Vectors.Append
                          (Result,
                           Chunk_Hit'
                             (Project_Len    => Proj.all'Length,
                              Body_Len       => Bod.all'Length,
                              Created_Len    => Crea.all'Length,
                              Session_Len    => Sess.all'Length,
                              Id             => Rid,
                              Session_Row_Id => Sr_C,
                              Ordinal        => Ord_C,
                              Project        => Proj.all,
                              Content        => Bod.all,
                              Created_At     => Crea.all,
                              Session        => Sess.all,
                              Distance       => Dist));
                        Count := Count + 1;
                     end if;
                     Sql.Free (Proj);
                     Sql.Free (Bod);
                     Sql.Free (Crea);
                     Sql.Free (Sess);
                  end;
               end if;
               if MSt /= Sql.Row and then MSt /= Sql.Done then
                  Failed := True;
               end if;
            end;
            exit when Failed;
         end loop;

         Sql.Finalize (M);
      end;

      Sql.Finalize (K1);
      --  As in Search_Summaries: Row (stopped early) and Done (exhausted) are
      --  both success, and any other Step code is a failure.
      if not Failed and then (St = Sql.Done or else St = Sql.Row) then
         Status := Success;
      end if;
   end Search_Chunks;

   --------------------
   -- Forget_Summary --
   --------------------

   procedure Forget_Summary
     (S       : Store;
      Id      : Row_Id;
      Deleted : out Boolean;
      Status  : out Op_Status)
   is
      Stmt : Sql.Statement;
      St   : Sql.Status;
      Ok   : Boolean;
      Exists : Boolean := False;
   begin
      Deleted := False;
      Status  := Db_Error;

      Exec (S, "BEGIN", Ok);
      if not Ok then
         return;
      end if;

      --  Does the row exist?
      Sql.Prepare (S.DB, "SELECT id FROM summaries WHERE id = ?", Stmt, St);
      if St = Sql.Ok then
         Sql.Bind_Int64 (Stmt, 1, Id, St);
         if St = Sql.Ok then
            Sql.Step (Stmt, St);
            Exists := St = Sql.Row;
         end if;
      end if;
      Sql.Finalize (Stmt);
      if St /= Sql.Row and then St /= Sql.Done then
         Rollback (S);
         return;
      end if;

      if not Exists then
         Rollback (S);
         Status := (if Ok then Memcp.Store.Success else Db_Error);
         return;
      end if;

      --  Delete embedding (vec0 has no FK), then the summary (diary cascades).
      declare
         D1, D2 : Boolean;
      begin
         Delete_Vec :
         declare
            VS : Sql.Status;
         begin
            Sql.Prepare
              (S.DB, "DELETE FROM summary_vec WHERE rowid = ?", Stmt, VS);
            if VS = Sql.Ok then
               Sql.Bind_Int64 (Stmt, 1, Id, VS);
               if VS = Sql.Ok then
                  Sql.Step (Stmt, VS);
               end if;
            end if;
            Sql.Finalize (Stmt);
            D1 := VS = Sql.Done;
         end Delete_Vec;

         Delete_Summary :
         declare
            DS : Sql.Status;
         begin
            Sql.Prepare
              (S.DB, "DELETE FROM summaries WHERE id = ?", Stmt, DS);
            if DS = Sql.Ok then
               Sql.Bind_Int64 (Stmt, 1, Id, DS);
               if DS = Sql.Ok then
                  Sql.Step (Stmt, DS);
               end if;
            end if;
            Sql.Finalize (Stmt);
            D2 := DS = Sql.Done;
         end Delete_Summary;

         if D1 and then D2 then
            Exec (S, "COMMIT", Ok);
            if Ok then
               Deleted := True;
               Status  := Memcp.Store.Success;
            else
               Rollback (S);
            end if;
         else
            Rollback (S);
         end if;
      end;
   end Forget_Summary;

   ----------
   -- Save --
   ----------

   procedure Save
     (S            : Store;
      Project      : String;
      Diary_Body   : String;
      Summary_Body : String;
      Embedding    : Candle_Spark.Embedding;
      Has_Session  : Boolean;
      Session_Id   : String;
      Has_Created  : Boolean;
      Created_At   : String;
      Surface      : String;
      Surface_Label : String;
      Result       : out Save_Result;
      Status       : out Op_Status)
   is
      Proj_Id : Row_Id;
      Surf_Id : Row_Id;
      TS      : constant String := (if Has_Created then Created_At else Now_Iso);
      Head    : constant String := Parse_Headline (Summary_Body);
      DH      : constant String := Dedup_Hash (Project, Diary_Body, Summary_Body);
      Blob    : constant Packed_Blob := To_Blob (Embedding);

      procedure Put_Vec (Row : Row_Id; Ok : out Boolean);
      --  Attach this call's embedding to summaries row Row.
      --  Delete-then-insert, so it serves both a fresh insert and an
      --  in-place replace.

      procedure Put_Vec (Row : Row_Id; Ok : out Boolean) is
         Vs : Sql.Statement;
         St : Sql.Status;
      begin
         Ok := False;
         Sql.Prepare (S.DB, "DELETE FROM summary_vec WHERE rowid = ?", Vs, St);
         if St = Sql.Ok then
            Sql.Bind_Int64 (Vs, 1, Row, St);
            if St = Sql.Ok then
               Sql.Step (Vs, St);
            end if;
         end if;
         Sql.Finalize (Vs);
         if St /= Sql.Done then
            return;
         end if;
         Sql.Prepare
           (S.DB, "INSERT INTO summary_vec (rowid, embedding) VALUES (?, ?)",
            Vs, St);
         if St = Sql.Ok then
            Sql.Bind_Int64 (Vs, 1, Row, St);
            if St = Sql.Ok then
               Sql.Bind_Blob (Vs, 2, Blob, St);
            end if;
            if St = Sql.Ok then
               Sql.Step (Vs, St);
            end if;
         end if;
         Sql.Finalize (Vs);
         Ok := St = Sql.Done;
      end Put_Vec;
   begin
      Result := (Summary_Id => 0, Diary_Id => 0,
                 Already_Existed => False, Replaced => False);

      Project_Id (S, Project, Proj_Id, Status);
      if Status /= Success then
         return;
      end if;
      Surface_Row_Id (S, Surface, Surface_Label, TS, Surf_Id, Status);
      if Status /= Success then
         return;
      end if;
      Status := Db_Error;

      --  ---- session-scoped upsert path ----
      if Has_Session then
         declare
            Q : Sql.Statement;
            St : Sql.Status;
            Found : Boolean := False;
            Ex_Summary, Ex_Diary : Row_Id := 0;
            Same_Hash : Boolean := False;
         begin
            Sql.Prepare
              (S.DB,
               "SELECT s.id, s.dedup_hash, d.id FROM summaries s"
               & " JOIN diary d ON d.summary_id = s.id"
               & " WHERE s.project_id = ? AND s.session_id = ? LIMIT 1",
               Q, St);
            if St = Sql.Ok then
               Sql.Bind_Int64 (Q, 1, Proj_Id, St);
               if St = Sql.Ok then
                  Sql.Bind_Text (Q, 2, Session_Id, St);
               end if;
               if St = Sql.Ok then
                  Sql.Step (Q, St);
                  if St = Sql.Row then
                     Found := True;
                     Ex_Summary := Sql.Column_Int64 (Q, 0);
                     declare
                        H : Sql.Text_Ptr := Sql.Column_Text (Q, 1);
                     begin
                        Same_Hash := H.all = DH;
                        Sql.Free (H);
                     end;
                     Ex_Diary := Sql.Column_Int64 (Q, 2);
                  end if;
               end if;
            end if;
            Sql.Finalize (Q);
            if St /= Sql.Row and then St /= Sql.Done then
               return;
            end if;

            if Found then
               if Same_Hash then
                  Result := (Summary_Id => Ex_Summary, Diary_Id => Ex_Diary,
                             Already_Existed => True, Replaced => False);
                  Status := Success;
                  return;
               end if;
               --  Replace in place, inside a transaction.
               Update_Existing :
               declare
                  Ok : Boolean;
                  US : Sql.Statement;
                  St2 : Sql.Status;
                  Step_Ok : Boolean;
               begin
                  Exec (S, "BEGIN", Ok);
                  if not Ok then
                     return;
                  end if;

                  Sql.Prepare
                    (S.DB,
                     "UPDATE summaries SET created_at = ?, headline = ?,"
                     & " body = ?, dedup_hash = ?, kind = ?,"
                     & " surface_row_id = ? WHERE id = ?",
                     US, St2);
                  if St2 = Sql.Ok then
                     Sql.Bind_Text (US, 1, TS, St2);
                     if St2 = Sql.Ok then
                        Sql.Bind_Text (US, 2, Head, St2);
                     end if;
                     if St2 = Sql.Ok then
                        Sql.Bind_Text (US, 3, Summary_Body, St2);
                     end if;
                     if St2 = Sql.Ok then
                        Sql.Bind_Text (US, 4, DH, St2);
                     end if;
                     if St2 = Sql.Ok then
                        Sql.Bind_Text (US, 5, Kind_Diary, St2);
                     end if;
                     if St2 = Sql.Ok then
                        --  The replacing write owns the row, so an unattributed
                        --  replace clears an attribution rather than keeping a
                        --  stale one.
                        Bind_Surface (US, 6, Surf_Id, St2);
                     end if;
                     if St2 = Sql.Ok then
                        Sql.Bind_Int64 (US, 7, Ex_Summary, St2);
                     end if;
                     if St2 = Sql.Ok then
                        Sql.Step (US, St2);
                     end if;
                  end if;
                  Sql.Finalize (US);
                  Step_Ok := St2 = Sql.Done;

                  if Step_Ok then
                     Put_Vec (Ex_Summary, Step_Ok);
                  end if;

                  if Step_Ok then
                     Sql.Prepare
                       (S.DB,
                        "UPDATE diary SET created_at = ?, body = ?"
                        & " WHERE id = ?", US, St2);
                     if St2 = Sql.Ok then
                        Sql.Bind_Text (US, 1, TS, St2);
                        if St2 = Sql.Ok then
                           Sql.Bind_Text (US, 2, Diary_Body, St2);
                        end if;
                        if St2 = Sql.Ok then
                           Sql.Bind_Int64 (US, 3, Ex_Diary, St2);
                        end if;
                        if St2 = Sql.Ok then
                           Sql.Step (US, St2);
                        end if;
                     end if;
                     Sql.Finalize (US);
                     Step_Ok := St2 = Sql.Done;
                  end if;

                  if Step_Ok then
                     Exec (S, "COMMIT", Ok);
                     if Ok then
                        Result := (Summary_Id => Ex_Summary,
                                   Diary_Id => Ex_Diary,
                                   Already_Existed => True, Replaced => True);
                        Status := Success;
                        return;
                     end if;
                  end if;
                  Rollback (S);
                  return;
               end Update_Existing;
            end if;
         end;
      end if;

      --  ---- content-dedup path ----
      declare
         Q : Sql.Statement;
         St : Sql.Status;
         Found : Boolean := False;
         Ex_Summary, Ex_Diary : Row_Id := 0;
      begin
         Sql.Prepare
           (S.DB,
            "SELECT s.id, d.id FROM summaries s"
            & " JOIN diary d ON d.summary_id = s.id"
            & " WHERE s.dedup_hash = ? AND s.project_id = ? LIMIT 1",
            Q, St);
         if St = Sql.Ok then
            Sql.Bind_Text (Q, 1, DH, St);
            if St = Sql.Ok then
               Sql.Bind_Int64 (Q, 2, Proj_Id, St);
            end if;
            if St = Sql.Ok then
               Sql.Step (Q, St);
               if St = Sql.Row then
                  Found := True;
                  Ex_Summary := Sql.Column_Int64 (Q, 0);
                  Ex_Diary   := Sql.Column_Int64 (Q, 1);
               end if;
            end if;
         end if;
         Sql.Finalize (Q);
         if St /= Sql.Row and then St /= Sql.Done then
            return;
         end if;
         if Found then
            Result := (Summary_Id => Ex_Summary, Diary_Id => Ex_Diary,
                       Already_Existed => True, Replaced => False);
            Status := Success;
            return;
         end if;
      end;

      --  ---- fresh insert path ----
      Insert_Fresh :
      declare
         Ok : Boolean;
         Ins : Sql.Statement;
         St2 : Sql.Status;
         New_Summary, New_Diary : Row_Id := 0;
         Step_Ok : Boolean;
      begin
         Exec (S, "BEGIN", Ok);
         if not Ok then
            return;
         end if;

         Sql.Prepare
           (S.DB,
            "INSERT INTO summaries (project_id, session_id, created_at,"
            & " headline, body, dedup_hash, kind, surface_row_id)"
            & " VALUES (?, ?, ?, ?, ?, ?, ?, ?)", Ins, St2);
         if St2 = Sql.Ok then
            Sql.Bind_Int64 (Ins, 1, Proj_Id, St2);
            if St2 = Sql.Ok then
               if Has_Session then
                  Sql.Bind_Text (Ins, 2, Session_Id, St2);
               else
                  Sql.Bind_Null (Ins, 2, St2);
               end if;
            end if;
            if St2 = Sql.Ok then
               Sql.Bind_Text (Ins, 3, TS, St2);
            end if;
            if St2 = Sql.Ok then
               Sql.Bind_Text (Ins, 4, Head, St2);
            end if;
            if St2 = Sql.Ok then
               Sql.Bind_Text (Ins, 5, Summary_Body, St2);
            end if;
            if St2 = Sql.Ok then
               Sql.Bind_Text (Ins, 6, DH, St2);
            end if;
            if St2 = Sql.Ok then
               Sql.Bind_Text (Ins, 7, Kind_Diary, St2);
            end if;
            if St2 = Sql.Ok then
               Bind_Surface (Ins, 8, Surf_Id, St2);
            end if;
            if St2 = Sql.Ok then
               Sql.Step (Ins, St2);
            end if;
         end if;
         Sql.Finalize (Ins);
         Step_Ok := St2 = Sql.Done;
         if Step_Ok then
            New_Summary := Sql.Last_Insert_Rowid (S.DB);
            Put_Vec (New_Summary, Step_Ok);
         end if;

         if Step_Ok then
            Sql.Prepare
              (S.DB,
               "INSERT INTO diary (project_id, summary_id, created_at, body)"
               & " VALUES (?, ?, ?, ?)", Ins, St2);
            if St2 = Sql.Ok then
               Sql.Bind_Int64 (Ins, 1, Proj_Id, St2);
               if St2 = Sql.Ok then
                  Sql.Bind_Int64 (Ins, 2, New_Summary, St2);
               end if;
               if St2 = Sql.Ok then
                  Sql.Bind_Text (Ins, 3, TS, St2);
               end if;
               if St2 = Sql.Ok then
                  Sql.Bind_Text (Ins, 4, Diary_Body, St2);
               end if;
               if St2 = Sql.Ok then
                  Sql.Step (Ins, St2);
               end if;
            end if;
            Sql.Finalize (Ins);
            Step_Ok := St2 = Sql.Done;
            if Step_Ok then
               New_Diary := Sql.Last_Insert_Rowid (S.DB);
            end if;
         end if;

         if Step_Ok then
            Exec (S, "COMMIT", Ok);
            if Ok then
               Result := (Summary_Id => New_Summary, Diary_Id => New_Diary,
                          Already_Existed => False, Replaced => False);
               Status := Success;
               return;
            end if;
         end if;
         Rollback (S);
      end Insert_Fresh;
   end Save;

   ------------------
   -- Save_Session --
   ------------------

   procedure Save_Session
     (S           : Store;
      Project     : String;
      Session_Id  : String;
      Transcript  : String;
      Chunks      : Chunk_Input_List;
      Has_Created : Boolean;
      Created_At  : String;
      Surface       : String;
      Surface_Label : String;
      Result      : out Session_Save_Result;
      Status      : out Op_Status)
   is
      Proj_Id : Row_Id;
      Surf_Id : Row_Id;
      TS      : constant String :=
        (if Has_Created then Created_At else Now_Iso);
   begin
      Result := (Session_Row_Id => 0, Chunk_Count => 0,
                 Already_Existed => False, Raw_Path_Set => False);

      Project_Id (S, Project, Proj_Id, Status);
      if Status /= Success then
         return;
      end if;
      Surface_Row_Id (S, Surface, Surface_Label, TS, Surf_Id, Status);
      if Status /= Success then
         return;
      end if;
      Status := Db_Error;

      --  ---- idempotency: existing (project, session) row is a no-op ----
      declare
         Q     : Sql.Statement;
         St    : Sql.Status;
         Found : Boolean := False;
         Ex_Id : Row_Id := 0;
      begin
         Sql.Prepare
           (S.DB,
            "SELECT id FROM sessions WHERE project_id = ? AND session_id = ?",
            Q, St);
         if St = Sql.Ok then
            Sql.Bind_Int64 (Q, 1, Proj_Id, St);
            if St = Sql.Ok then
               Sql.Bind_Text (Q, 2, Session_Id, St);
            end if;
            if St = Sql.Ok then
               Sql.Step (Q, St);
               if St = Sql.Row then
                  Found := True;
                  Ex_Id := Sql.Column_Int64 (Q, 0);
               end if;
            end if;
         end if;
         Sql.Finalize (Q);
         if St /= Sql.Row and then St /= Sql.Done then
            return;
         end if;

         if Found then
            --  Return the existing row's id and its current chunk count,
            --  inserting nothing.
            declare
               C   : Sql.Statement;
               CSt : Sql.Status;
               Cnt : Natural := 0;
            begin
               Sql.Prepare
                 (S.DB,
                  "SELECT id FROM chunks WHERE session_row_id = ?"
                  & " ORDER BY ordinal", C, CSt);
               if CSt = Sql.Ok then
                  Sql.Bind_Int64 (C, 1, Ex_Id, CSt);
               end if;
               if CSt = Sql.Ok then
                  loop
                     Sql.Step (C, CSt);
                     exit when CSt /= Sql.Row;
                     exit when Cnt = Natural'Last;
                     Cnt := Cnt + 1;
                  end loop;
               end if;
               Sql.Finalize (C);
               if CSt = Sql.Done then
                  Result := (Session_Row_Id => Ex_Id, Chunk_Count => Cnt,
                             Already_Existed => True, Raw_Path_Set => False);
                  Status := Success;
               end if;
               return;
            end;
         end if;
      end;

      --  ---- fresh session: write transcript (best-effort) + insert rows ----
      declare
         Raw_Path  : Path_Access := null;
         Ok        : Boolean;
         Ins       : Sql.Statement;
         St2       : Sql.Status;
         New_Sess  : Row_Id := 0;
         Step_Ok   : Boolean;
         Chunks_Ok : Boolean := False;
      begin
         --  A ":memory:" store has no on-disk parent, so skip the transcript
         --  entirely. Otherwise the write is best-effort: Raw_Path stays null
         --  on any I/O failure and the chunks still land.
         if S.DB_Path /= null and then S.DB_Path.all /= ":memory:" then
            Write_Session_File
              (Parent_Dir (S.DB_Path.all), Project, Session_Id, Transcript,
               Raw_Path);
         end if;

         Exec (S, "BEGIN", Ok);
         if Ok then
            Sql.Prepare
              (S.DB,
               "INSERT INTO sessions (project_id, session_id, created_at,"
               & " raw_path, surface_row_id) VALUES (?, ?, ?, ?, ?)",
               Ins, St2);
            if St2 = Sql.Ok then
               Sql.Bind_Int64 (Ins, 1, Proj_Id, St2);
               if St2 = Sql.Ok then
                  Sql.Bind_Text (Ins, 2, Session_Id, St2);
               end if;
               if St2 = Sql.Ok then
                  Sql.Bind_Text (Ins, 3, TS, St2);
               end if;
               if St2 = Sql.Ok then
                  if Raw_Path /= null then
                     Sql.Bind_Text (Ins, 4, Raw_Path.all, St2);
                  else
                     Sql.Bind_Null (Ins, 4, St2);
                  end if;
               end if;
               if St2 = Sql.Ok then
                  Bind_Surface (Ins, 5, Surf_Id, St2);
               end if;
               if St2 = Sql.Ok then
                  Sql.Step (Ins, St2);
               end if;
            end if;
            Sql.Finalize (Ins);
            Step_Ok := St2 = Sql.Done;

            if Step_Ok then
               New_Sess := Sql.Last_Insert_Rowid (S.DB);
               Insert_Chunks (S, New_Sess, Proj_Id, TS, Chunks, Chunks_Ok);
            end if;

            if Step_Ok and then Chunks_Ok then
               Exec (S, "COMMIT", Ok);
               if Ok then
                  Result :=
                    (Session_Row_Id  => New_Sess,
                     Chunk_Count     =>
                       Natural (Chunk_Input_Vectors.Length (Chunks)),
                     Already_Existed => False,
                     Raw_Path_Set    => Raw_Path /= null);
                  Status := Success;
               else
                  Rollback (S);
               end if;
            else
               Rollback (S);
            end if;
         end if;

         Free_Path (Raw_Path);
      end;
   end Save_Session;

   --------------------
   -- Save_Autorecap --
   --------------------

   procedure Save_Autorecap
     (S           : Store;
      Project     : String;
      Session_Id  : String;
      Recap_Text  : String;
      Embedding   : Candle_Spark.Embedding;
      Has_Created : Boolean;
      Created_At  : String;
      Surface       : String;
      Surface_Label : String;
      Result      : out Autorecap_Result;
      Status      : out Op_Status)
   is
      Proj_Id : Row_Id;
      Surf_Id : Row_Id;
      TS   : constant String := (if Has_Created then Created_At else Now_Iso);
      Head : constant String := Recap_Headline (Recap_Text);
      DH   : constant String := Dedup_Hash (Project, Recap_Text, Recap_Text);
      Blob : constant Packed_Blob := To_Blob (Embedding);
   begin
      Result := (Summary_Id => 0, Diary_Id => 0, Written => False);

      Project_Id (S, Project, Proj_Id, Status);
      if Status /= Success then
         return;
      end if;
      Surface_Row_Id (S, Surface, Surface_Label, TS, Surf_Id, Status);
      if Status /= Success then
         return;
      end if;
      Status := Db_Error;

      --  Short-circuit: any existing summary for (project, session) wins.
      declare
         Q     : Sql.Statement;
         St    : Sql.Status;
         Found : Boolean := False;
      begin
         Sql.Prepare
           (S.DB,
            "SELECT id FROM summaries WHERE project_id = ? AND session_id = ?"
            & " LIMIT 1", Q, St);
         if St = Sql.Ok then
            Sql.Bind_Int64 (Q, 1, Proj_Id, St);
            if St = Sql.Ok then
               Sql.Bind_Text (Q, 2, Session_Id, St);
            end if;
            if St = Sql.Ok then
               Sql.Step (Q, St);
               Found := St = Sql.Row;
            end if;
         end if;
         Sql.Finalize (Q);
         if St /= Sql.Row and then St /= Sql.Done then
            return;
         end if;
         if Found then
            --  Leave Written False: declining to write is a successful outcome,
            --  not an error.
            Status := Success;
            return;
         end if;
      end;

      --  ---- fresh insert: summary(kind=autorecap) + embedding + diary ----
      declare
         Ok  : Boolean;
         Ins : Sql.Statement;
         St2 : Sql.Status;
         New_Summary, New_Diary : Row_Id := 0;
         Step_Ok : Boolean;
      begin
         Exec (S, "BEGIN", Ok);
         if not Ok then
            return;
         end if;

         Sql.Prepare
           (S.DB,
            "INSERT INTO summaries (project_id, session_id, created_at,"
            & " headline, body, dedup_hash, kind, surface_row_id)"
            & " VALUES (?, ?, ?, ?, ?, ?, ?, ?)", Ins, St2);
         if St2 = Sql.Ok then
            Sql.Bind_Int64 (Ins, 1, Proj_Id, St2);
         end if;
         if St2 = Sql.Ok then
            Sql.Bind_Text (Ins, 2, Session_Id, St2);
         end if;
         if St2 = Sql.Ok then
            Sql.Bind_Text (Ins, 3, TS, St2);
         end if;
         if St2 = Sql.Ok then
            Sql.Bind_Text (Ins, 4, Head, St2);
         end if;
         if St2 = Sql.Ok then
            Sql.Bind_Text (Ins, 5, Recap_Text, St2);
         end if;
         if St2 = Sql.Ok then
            Sql.Bind_Text (Ins, 6, DH, St2);
         end if;
         if St2 = Sql.Ok then
            Sql.Bind_Text (Ins, 7, Kind_Autorecap, St2);
         end if;
         if St2 = Sql.Ok then
            Bind_Surface (Ins, 8, Surf_Id, St2);
         end if;
         if St2 = Sql.Ok then
            Sql.Step (Ins, St2);
         end if;
         Sql.Finalize (Ins);
         Step_Ok := St2 = Sql.Done;

         if Step_Ok then
            New_Summary := Sql.Last_Insert_Rowid (S.DB);
            Sql.Prepare
              (S.DB,
               "INSERT INTO summary_vec (rowid, embedding) VALUES (?, ?)",
               Ins, St2);
            if St2 = Sql.Ok then
               Sql.Bind_Int64 (Ins, 1, New_Summary, St2);
            end if;
            if St2 = Sql.Ok then
               Sql.Bind_Blob (Ins, 2, Blob, St2);
            end if;
            if St2 = Sql.Ok then
               Sql.Step (Ins, St2);
            end if;
            Sql.Finalize (Ins);
            Step_Ok := St2 = Sql.Done;
         end if;

         if Step_Ok then
            Sql.Prepare
              (S.DB,
               "INSERT INTO diary (project_id, summary_id, created_at, body)"
               & " VALUES (?, ?, ?, ?)", Ins, St2);
            if St2 = Sql.Ok then
               Sql.Bind_Int64 (Ins, 1, Proj_Id, St2);
            end if;
            if St2 = Sql.Ok then
               Sql.Bind_Int64 (Ins, 2, New_Summary, St2);
            end if;
            if St2 = Sql.Ok then
               Sql.Bind_Text (Ins, 3, TS, St2);
            end if;
            if St2 = Sql.Ok then
               Sql.Bind_Text (Ins, 4, Recap_Text, St2);
            end if;
            if St2 = Sql.Ok then
               Sql.Step (Ins, St2);
            end if;
            Sql.Finalize (Ins);
            Step_Ok := St2 = Sql.Done;
            if Step_Ok then
               New_Diary := Sql.Last_Insert_Rowid (S.DB);
            end if;
         end if;

         if Step_Ok then
            Exec (S, "COMMIT", Ok);
            if Ok then
               Result := (Summary_Id => New_Summary,
                          Diary_Id   => New_Diary,
                          Written    => True);
               Status := Success;
               return;
            end if;
         end if;
         Rollback (S);
      end;
   end Save_Autorecap;

   ----------------------
   -- Reindex_Session  --
   ----------------------

   procedure Reindex_Session
     (S          : Store;
      Project    : String;
      Session_Id : String;
      Chunks     : Chunk_Input_List;
      Found      : out Boolean;
      Old_Count  : out Natural;
      New_Count  : out Natural;
      Status     : out Op_Status)
   is
      Proj_Id : Row_Id;
   begin
      Found     := False;
      Old_Count := 0;
      New_Count := 0;

      Project_Id (S, Project, Proj_Id, Status);
      if Status /= Success then
         return;
      end if;
      Status := Db_Error;

      --  Locate the session row + its original created_at (copied out so the
      --  new chunks can inherit it after the cursor is gone).
      declare
         Q       : Sql.Statement;
         St      : Sql.Status;
         Have    : Boolean := False;
         Sess_Id : Row_Id := 0;
         TS_Copy : Path_Access := null;
      begin
         Sql.Prepare
           (S.DB,
            "SELECT id, created_at FROM sessions"
            & " WHERE project_id = ? AND session_id = ?", Q, St);
         if St = Sql.Ok then
            Sql.Bind_Int64 (Q, 1, Proj_Id, St);
            if St = Sql.Ok then
               Sql.Bind_Text (Q, 2, Session_Id, St);
            end if;
            if St = Sql.Ok then
               Sql.Step (Q, St);
               if St = Sql.Row then
                  Have    := True;
                  Sess_Id := Sql.Column_Int64 (Q, 0);
                  declare
                     T : Sql.Text_Ptr := Sql.Column_Text (Q, 1);
                  begin
                     TS_Copy := new String'(T.all);
                     Sql.Free (T);
                  end;
               end if;
            end if;
         end if;
         Sql.Finalize (Q);

         if St /= Sql.Row and then St /= Sql.Done then
            null;  --  DB error: Status stays Db_Error
         elsif not Have then
            Status := Success;   --  no such session
         else
            --  Replace the chunks in one transaction: delete each old chunk's
            --  embedding (vec0 has no FK cascade), bulk-delete the chunk rows,
            --  then insert the new ones with the session's original timestamp.
            declare
               Ok        : Boolean;
               Step_Ok   : Boolean;
               Chunks_Ok : Boolean;
            begin
               Exec (S, "BEGIN", Ok);
               if Ok then
                  --  delete old chunk_vec rows, counting them
                  declare
                     Sel : Sql.Statement;
                     SSt : Sql.Status;
                     Cnt : Natural := 0;
                  begin
                     Sql.Prepare
                       (S.DB,
                        "SELECT id FROM chunks WHERE session_row_id = ?",
                        Sel, SSt);
                     if SSt = Sql.Ok then
                        Sql.Bind_Int64 (Sel, 1, Sess_Id, SSt);
                     end if;
                     if SSt = Sql.Ok then
                        loop
                           Sql.Step (Sel, SSt);
                           exit when SSt /= Sql.Row;
                           exit when Cnt = Natural'Last;
                           declare
                              Old_Id : constant Row_Id :=
                                Sql.Column_Int64 (Sel, 0);
                              DV  : Sql.Statement;
                              DSt : Sql.Status;
                           begin
                              Sql.Prepare
                                (S.DB,
                                 "DELETE FROM chunk_vec WHERE rowid = ?",
                                 DV, DSt);
                              if DSt = Sql.Ok then
                                 Sql.Bind_Int64 (DV, 1, Old_Id, DSt);
                              end if;
                              if DSt = Sql.Ok then
                                 Sql.Step (DV, DSt);
                              end if;
                              Sql.Finalize (DV);
                              if DSt /= Sql.Done then
                                 SSt := Sql.Error;
                                 exit;
                              end if;
                              Cnt := Cnt + 1;
                           end;
                        end loop;
                     end if;
                     Sql.Finalize (Sel);
                     Old_Count := Cnt;
                     Step_Ok   := SSt = Sql.Done;
                  end;

                  --  bulk-delete the old chunk rows
                  if Step_Ok then
                     declare
                        D   : Sql.Statement;
                        DSt : Sql.Status;
                     begin
                        Sql.Prepare
                          (S.DB,
                           "DELETE FROM chunks WHERE session_row_id = ?",
                           D, DSt);
                        if DSt = Sql.Ok then
                           Sql.Bind_Int64 (D, 1, Sess_Id, DSt);
                        end if;
                        if DSt = Sql.Ok then
                           Sql.Step (D, DSt);
                        end if;
                        Sql.Finalize (D);
                        Step_Ok := DSt = Sql.Done;
                     end;
                  end if;

                  --  insert the replacement chunks (TS_Copy is non-null here)
                  if Step_Ok then
                     if TS_Copy /= null then
                        Insert_Chunks
                          (S, Sess_Id, Proj_Id, TS_Copy.all, Chunks, Chunks_Ok);
                        Step_Ok := Chunks_Ok;
                     else
                        Step_Ok := False;
                     end if;
                  end if;

                  if Step_Ok then
                     Exec (S, "COMMIT", Ok);
                     if Ok then
                        Found     := True;
                        New_Count :=
                          Natural (Chunk_Input_Vectors.Length (Chunks));
                        Status    := Success;
                     else
                        Rollback (S);
                     end if;
                  else
                     Rollback (S);
                  end if;
               end if;
            end;
         end if;

         Free_Path (TS_Copy);
      end;
   end Reindex_Session;

end Memcp.Store;
