with Ada.Streams;             use Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Conversion;
with Ada.Directories;

with GNAT.SHA256;
with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Calendar.Time_Zones;

with SPARK.Containers.Types;

with Memcp_Log;

package body Memcp_Store with SPARK_Mode => On is

   --  A finalized SQLite statement handle is deliberately left with no readable
   --  value: Sql.Finalize is `in out` with Post => not Is_Valid precisely so
   --  that any use-after-finalize is caught as a precondition failure. The
   --  resulting "set but not used" is the price of that protection, so we
   --  silence exactly that message (the nulled handle is genuinely never read).
   --  This is a flow observation about the ineffective final write, orthogonal
   --  to the Needs_Reclamation ownership proof (which shows the resource IS
   --  released); the ownership work does not make this message go away.
   pragma Warnings
     (GNATprove, Off, "*is set by ""Finalize"" but not used after the call",
      Reason => "the statement handle is nulled by Finalize by design and is "
                & "never read afterwards");

   package Sql renames Sqlite_Vec_Spark;
   use type Sql.Status;

   --  Make the arithmetic/relational operators on the vectors' Capacity_Range
   --  (a subtype of Count_Type) directly visible -- Length/Last_Count compares.
   use type SPARK.Containers.Types.Count_Type;

   --  Reclaim a remembered DB path (Store.DB_Path) / a transcript-path copy.
   procedure Free_Path is
     new Ada.Unchecked_Deallocation (String, Path_Access);

   --  Trusted helpers: the spec is SPARK-visible (so their String results may
   --  flow into proved code) while the body carries SPARK_Mode => Off (SHA-256
   --  / wall-clock are outside SPARK). Global => null mirrors how the FFI
   --  imports declare themselves effect-free at the boundary.
   function Dedup_Hash
     (Project, Diary_Body, Summary_Body : String) return String
     with Global => null;

   function Now_Iso return String with Global => null;

   ------------------------------------------------------------------
   -- Schema (store.py _SCHEMA + _VEC_SCHEMAS). Applied once by Open --
   ------------------------------------------------------------------

   LF : constant Character := ASCII.LF;

   Schema_SQL : constant String :=
     "CREATE TABLE IF NOT EXISTS meta ("                              & LF &
     "  key TEXT PRIMARY KEY, value TEXT NOT NULL);"                  & LF &
     "CREATE TABLE IF NOT EXISTS projects ("                          & LF &
     "  id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);"          & LF &
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

   Vec_Summary_SQL : constant String :=
     "CREATE VIRTUAL TABLE IF NOT EXISTS summary_vec"
     & " USING vec0(embedding float[384])";
   Vec_Chunk_SQL   : constant String :=
     "CREATE VIRTUAL TABLE IF NOT EXISTS chunk_vec"
     & " USING vec0(embedding float[384])";

   -------------------------------------------------------------
   --  Trusted, non-SPARK helpers (isolated behind SPARK_Mode Off)
   -------------------------------------------------------------

   --  Content hash short-circuiting save() retries. NUL-delimited so field
   --  boundaries can't collide ("ab"+"c" vs "a"+"bc"); SHA-256 hex so it
   --  matches store.py byte-for-byte (the conformance seed DBs store these).
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

   --  Wall-clock timestamp in ISO-8601 with the local UTC offset, store.py
   --  _utcnow_iso's shape (e.g. "2026-07-13T14:12:13-04:00"). Sub-second
   --  precision is dropped -- exactness only matters on the replay path, which
   --  injects Created_At instead of calling this.
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
   begin
      Iso (Iso'First + 10) := 'T';
      return Iso & Sign & D2 (HH) & ":" & D2 (MM);
   end Now_Iso;

   ----------------------------------------------------------------
   --  Raw session-file location + write (store.py _session_path /
   --  _write_session_file). The write is disk I/O -- SPARK_Mode => Off,
   --  Global => null at the boundary, exactly like Now_Iso above.
   ----------------------------------------------------------------

   --  Directory portion of Path (everything before the last '/'). Mirrors
   --  pathlib's `.parent`: "/a/b/x" -> "/a/b", "/x" -> "/", "x" and ":memory:"
   --  -> "." (no separator). Pure SPARK -- returns a slice, never a
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

   --  Write Content to <Parent>/sessions/<Project>/<Session_Id>.jsonl, creating
   --  the parent directories first (store.py _session_path +
   --  _write_session_file). Best-effort: on success Path_Out is an owning copy
   --  of the path written (the caller stores it in sessions.raw_path, then
   --  Frees it); any I/O failure leaves Path_Out null and the chunks still
   --  land. The path is built here, off-SPARK, so its (unbounded) construction
   --  raises no proof obligation in the caller; Stream_IO writes the exact
   --  bytes (Character = 1 byte), matching write_text's UTF-8 passthrough.
   procedure Write_Session_File
     (Parent, Project, Session_Id, Content : String;
      Path_Out : out Path_Access)
     with Global => null;

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

   -----------------------------------------------------------
   --  Headline extraction (store.py _parse_headline), pure SPARK
   -----------------------------------------------------------

   function Is_Space (C : Character) return Boolean is
     (C = ' ' or else C = ASCII.HT or else C = ASCII.LF
      or else C = ASCII.CR or else C = ASCII.FF or else C = ASCII.VT);

   Headline_Cap : constant := 100;
   Prefix       : constant String := "HEADLINE:";

   function To_Upper (C : Character) return Character is
     (if C in 'a' .. 'z'
      then Character'Val (Character'Pos (C) - 32) else C);

   --  Return the [First, Last] slice bounds of S with leading/trailing
   --  whitespace removed; First > Last signals an all-blank string.
   procedure Strip_Bounds (S : String; First : out Integer; Last : out Integer)
     with Pre  => S'Last < Integer'Last,
          Post => (First > Last) or else
                    (First in S'Range and then Last in S'Range),
          Always_Terminates
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

   --  first_line.upper().startswith("HEADLINE:"). The Post lets a caller that
   --  gets True conclude S is at least Prefix'Length long (so slicing off the
   --  prefix cannot overflow or run past the end).
   function Starts_With_Prefix (S : String) return Boolean
     with Pre  => S'Last < Integer'Last,
          Post => (if Starts_With_Prefix'Result then S'Length >= Prefix'Length)
   is
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
     with Pre => Body_Text'Last < Integer'Last
   is
      First : Integer;
      Last  : Integer;
   begin
      Strip_Bounds (Body_Text, First, Last);
      if First > Last then
         return "";
      end if;

      --  first_line = Body_Text (First .. Line_Last): the stripped body up to
      --  the first LF (leading whitespace, incl. LF, is already gone, so the
      --  first line is non-empty: Line_Last >= First).
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
            --  Remainder of the first line after "HEADLINE:", stripped.
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

      --  Fallback: whole stripped body, newlines -> spaces, capped at 100.
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

   --  Autorecap headline: store.py recap_text.strip().replace("\n"," ")[:100]
   --  -- no HEADLINE: parsing, just the stripped body with newlines flattened
   --  to spaces, capped at 100 (the fallback branch of Parse_Headline).
   function Recap_Headline (Text : String) return String
     with Pre => Text'Last < Integer'Last
   is
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

   -----------------------------------------------------------
   --  Embedding -> packed float32 blob (store.py _pack_embedding)
   -----------------------------------------------------------

   Blob_Bytes : constant := Embedding_Dim * 4;
   subtype Packed_Blob is Stream_Element_Array (1 .. Blob_Bytes);

   --  The Store and the embedder must agree on the dimension, else the copy
   --  loop below would index past the embedding.
   pragma Compile_Time_Error
     (Embedding_Dim /= Candle_Spark.Dimension,
      "Store embedding dimension disagrees with the embedder");

   --  Zero-copy reinterpretation of the embedding as the packed little-endian
   --  float32 blob sqlite-vec stores and compares against (the same bytes
   --  struct.pack('384f', ...) produces on this machine).
   --
   --  TODO(embed-blob): the local-subtype dance below is a gnatprove quirk
   --  workaround, not an idiom -- revisit with the team; there may be a
   --  cleaner spelling (or it may be worth a gnatprove report).
   --
   --  Note the local subtype. gnatprove confirms an unchecked conversion is
   --  size-exact and suitable only when the type's representation is anchored
   --  in the current unit; an instance taken *directly* on the withed
   --  Candle_Spark.Embedding is flagged "size not confirmed / unsuitable
   --  source", but the identical instance on a locally declared subtype of it
   --  proves clean. So we anchor it with Store_Embedding. (This holds
   --  regardless of -u / -U analysis scope.)
   subtype Store_Embedding is Candle_Spark.Embedding;
   function To_Blob is new Ada.Unchecked_Conversion
     (Store_Embedding, Packed_Blob);

   -------------------
   -- Insert_Chunks --
   -------------------

   --  Insert every Chunk (body + embedding) for one session row -- shared by
   --  save_session (fresh) and reindex_session (replace). Ordinal is the
   --  0-based position within Chunks. Runs inside the caller's transaction; Ok
   --  is False on the first SQLite failure.
   procedure Insert_Chunks
     (S           : Store;
      Session_Row : Row_Id;
      Proj_Id     : Row_Id;
      TS          : String;
      Chunks      : Chunk_Input_List;
      Ok          : out Boolean)
     with Pre => Is_Open (S)
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

   --  Run a resultless statement (BEGIN/COMMIT/ROLLBACK/simple DML) as a
   --  whole. Ok when SQLite accepted it.
   procedure Exec (S : Store; Text : String; Ok : out Boolean)
     with Pre => Is_Open (S)
                 and then Text'Length > 0
                 and then Text'Last < Natural'Last
   is
      St : Sql.Status;
   begin
      Sql.Execute (S.DB, Text, St);
      Ok := St = Sql.Ok;
   end Exec;

   --  Roll a transaction back, recording the (irrecoverable) failure if the
   --  ROLLBACK itself does not succeed. Callers reach here only on an error
   --  path where they can do nothing more than abandon the transaction, so the
   --  status would otherwise be discarded -- but a failed rollback can leave
   --  the database mid-transaction, which is exactly the kind of silent fault
   --  worth surfacing on the diagnostic channel.
   procedure Rollback (S : Store)
     with Pre => Is_Open (S)
   is
      Ok : Boolean;
   begin
      Exec (S, "ROLLBACK", Ok);
      if not Ok then
         Memcp_Log.Error
           ("transaction ROLLBACK failed; database may be left "
            & "mid-transaction");
      end if;
   end Rollback;

   --  "?,?,...,?" -- the parameter list for an IN clause of K bound values
   --  (K '?' separated by K-1 ','). K is capped at Max_Filter_Terms by every
   --  caller, so the length 2*K - 1 and the indices below cannot overflow.
   function Placeholders (K : Positive) return String
     with Pre  => K <= Max_Filter_Terms,
          Post => Placeholders'Result'First = 1
                  and then Placeholders'Result'Length = 2 * K - 1
   is
      Buf : String (1 .. 2 * K - 1) := [others => '?'];
   begin
      --  Overwrite the even positions with commas; odd positions stay '?'.
      for I in 2 .. K loop
         Buf (2 * I - 2) := ',';
      end loop;
      return Buf;
   end Placeholders;

   --  Ada-side membership test for the search metadata filters: is Value one
   --  of the names in L? A full scan (filter lists are tiny). Iterating
   --  First_Index .. Last_Index makes Element's index precondition trivial and
   --  needs no index arithmetic, so it discharges cleanly.
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

   --  get-or-insert projects(name) -> id. store.py _project_id.
   procedure Project_Id
     (S : Store; Name : String; Id : out Row_Id; Status : out Op_Status)
     with Pre => Is_Open (S)
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

   ----------
   -- Open --
   ----------

   procedure Open
     (S : out Store; DB_Path : String; Result : out Open_Status)
   is
      St : Sql.Status;
      Ok : Boolean;

      --  Assert one meta (key,value): insert if absent, refuse on mismatch.
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
   begin
      --  Initialize the owning field before S is read anywhere (it is set to
      --  the real path only once the store is fully Opened, below).
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
         --  Remember the path so save_session can anchor its sessions dir.
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
            Has_S : constant Boolean := not Sql.Column_Is_Null (Stmt, 2);
         begin
            Result := new Summary'
              (Project_Len  => Proj.all'Length,
               Session_Len  => Sess.all'Length,
               Created_Len  => Crea.all'Length,
               Headline_Len => Head.all'Length,
               Body_Len     => Bod.all'Length,
               Kind_Len     => Kind.all'Length,
               Id           => Sql.Column_Int64 (Stmt, 0),
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

      --  store.py: no projects -> []. Also refuse an over-long filter rather
      --  than build an unbounded IN clause (both cases: empty, Success).
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

         --  Bind the K project names to params 1 .. K (Index_Type'First is 1,
         --  so the vector index doubles as the 1-based bind position), then N
         --  to the LIMIT param at K + 1.
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

         --  One Diary_Entry per row. The Length guard keeps Append's
         --  capacity precondition trivially discharged on the path to it.
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
               Has_S : constant Boolean := not Sql.Column_Is_Null (Stmt, 3);
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
            Has_L : constant Boolean := not Sql.Column_Is_Null (Stmt, 2);
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
      --  Inner SELECT: session_id filter, then whichever optional filters are
      --  present. Columns are aliased so the tail form can re-order them in an
      --  outer query (SQLite reverses the DESC+LIMIT window back to ascending,
      --  so no Ada-side reversal is needed).
      Where_SQL : constant String :=
        " WHERE s.session_id = ?"
        & (if Has_Project then " AND p.name = ?" else "")
        & (if Has_Start then " AND c.ordinal >= ?" else "")
        & (if Has_End then " AND c.ordinal < ?" else "");
      Sel : constant String :=
        "SELECT c.id AS id, c.session_row_id AS srid, p.name AS project,"
        & " c.ordinal AS ordinal, c.body AS body, c.created_at AS created_at"
        & " FROM chunks c JOIN projects p ON p.id = c.project_id"
        & " JOIN sessions s ON s.id = c.session_row_id"
        & Where_SQL;
      Query : constant String :=
        (if Has_Tail
         then "SELECT id, srid, project, ordinal, body, created_at FROM ("
              & Sel & " ORDER BY ordinal DESC LIMIT ?) ORDER BY ordinal ASC"
         else Sel & " ORDER BY ordinal ASC");
      Stmt : Sql.Statement;
      St   : Sql.Status;
      Idx  : Positive := 1;

      --  The bind helpers advance Idx after every bind, including the last;
      --  that final advance is never read back, which is inherent to the
      --  running-position idiom rather than a real dead store.
      pragma Warnings
        (GNATprove, Off, "unused assignment",
         Reason => "the final Idx advance in a bind helper is never read");

      --  Bind Value at the running parameter position, then advance it.
      procedure Bind_Str (Value : String) is
      begin
         Sql.Bind_Text (Stmt, Idx, Value, St);
         Idx := Idx + 1;
      end Bind_Str;

      procedure Bind_Num (Value : Row_Id) is
      begin
         Sql.Bind_Int64 (Stmt, Idx, Value, St);
         Idx := Idx + 1;
      end Bind_Num;
   begin
      Result := Chunk_Vectors.Empty_Vector;
      Status := Db_Error;

      Sql.Prepare (S.DB, Query, Stmt, St);
      if St /= Sql.Ok then
         return;
      end if;

      --  Bind in the same order the placeholders appear above.
      Bind_Str (Session_Id);
      if St = Sql.Ok and then Has_Project then
         Bind_Str (Project);
      end if;
      if St = Sql.Ok and then Has_Start then
         Bind_Num (Start_Ord);
      end if;
      if St = Sql.Ok and then Has_End then
         Bind_Num (End_Ord);
      end if;
      if St = Sql.Ok and then Has_Tail then
         Bind_Num (Row_Id (Tail));
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

      --  One prepared per-row fetch, reused across candidates: the filtered
      --  over-fetch can be Lim*5, so recompiling Fetch_Summary_SQL per row is a
      --  needless recompile. Reset + rebind between rows instead.
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
                     Has_S : constant Boolean := not Sql.Column_Is_Null (M, 2);
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
      --  St = Done means the candidate set was exhausted; St = Row means we
      --  stopped early with enough hits (Count = Lim) or at capacity. Both are
      --  success -- only a genuine Step error (any other code) is a failure.
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

      --  One prepared per-row fetch, reused across candidates (see
      --  Search_Summaries): reset + rebind between rows rather than recompiling
      --  Chunk_By_Id_SQL once per candidate.
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
      --  As Search_Summaries: Row (stopped early) and Done (exhausted) are
      --  both success; any other Step code is a failure.
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
         Status := (if Ok then Memcp_Store.Success else Db_Error);
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
               Status  := Memcp_Store.Success;
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
      Result       : out Save_Result;
      Status       : out Op_Status)
   is
      Proj_Id : Row_Id;
      TS      : constant String := (if Has_Created then Created_At else Now_Iso);
      Head    : constant String := Parse_Headline (Summary_Body);
      DH      : constant String := Dedup_Hash (Project, Diary_Body, Summary_Body);
      Blob    : constant Packed_Blob := To_Blob (Embedding);

      --  Insert the summary_vec row for Row (delete-then-insert form so it
      --  works for both fresh insert and in-place replace).
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
                     & " body = ?, dedup_hash = ?, kind = ? WHERE id = ?",
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
                        Sql.Bind_Int64 (US, 6, Ex_Summary, St2);
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
            & " headline, body, dedup_hash, kind)"
            & " VALUES (?, ?, ?, ?, ?, ?, ?)", Ins, St2);
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
      Result      : out Session_Save_Result;
      Status      : out Op_Status)
   is
      Proj_Id : Row_Id;
      TS      : constant String :=
        (if Has_Created then Created_At else Now_Iso);
   begin
      Result := (Session_Row_Id => 0, Chunk_Count => 0,
                 Already_Existed => False, Raw_Path_Set => False);

      Project_Id (S, Project, Proj_Id, Status);
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
            --  Return the existing row's id + current chunk count, insert
            --  nothing (store.py counts the existing chunk ids).
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
         --  A ":memory:" store has no on-disk parent; skip it (store.py notes
         --  no :memory: test writes sessions). Otherwise the write is
         --  best-effort: Raw_Path stays null on any I/O failure.
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
               & " raw_path) VALUES (?, ?, ?, ?)", Ins, St2);
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
      Summary_Id  : out Row_Id;
      Diary_Id    : out Row_Id;
      Written     : out Boolean;
      Status      : out Op_Status)
   is
      Proj_Id : Row_Id;
      TS   : constant String := (if Has_Created then Created_At else Now_Iso);
      Head : constant String := Recap_Headline (Recap_Text);
      DH   : constant String := Dedup_Hash (Project, Recap_Text, Recap_Text);
      Blob : constant Packed_Blob := To_Blob (Embedding);
   begin
      Summary_Id := 0;
      Diary_Id   := 0;
      Written    := False;

      Project_Id (S, Project, Proj_Id, Status);
      if Status /= Success then
         return;
      end if;
      Status := Db_Error;

      --  Short-circuit: any existing Header for (project, session) wins.
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
            --  store.py returns None: leave Written False, but this is a
            --  successful (non-error) outcome.
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
            & " headline, body, dedup_hash, kind)"
            & " VALUES (?, ?, ?, ?, ?, ?, ?)", Ins, St2);
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
               Summary_Id := New_Summary;
               Diary_Id   := New_Diary;
               Written    := True;
               Status     := Success;
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
            Status := Success;   --  no such session (store.py None)
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

end Memcp_Store;
