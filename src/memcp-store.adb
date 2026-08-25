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
     (Project, Header_Text, Summary_Body : String) return String
     with Global => null;
   --  SHA-256 hex over Project, Header_Text and Summary_Body, NUL-delimited so
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
     "  header TEXT NOT NULL, body TEXT NOT NULL,"                    & LF &
     "  dedup_hash TEXT, kind TEXT NOT NULL DEFAULT 'authored');"     & LF &
     "CREATE INDEX IF NOT EXISTS idx_summaries_project_date"          & LF &
     "  ON summaries(project_id, created_at DESC);"                   & LF &
     "CREATE INDEX IF NOT EXISTS idx_summaries_session"               & LF &
     "  ON summaries(session_id);"                                    & LF &
     "CREATE INDEX IF NOT EXISTS idx_summaries_dedup"                 & LF &
     "  ON summaries(dedup_hash);"                                    & LF &
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
   --  The relational schema: meta, projects, surfaces, summaries, sessions
   --  and chunks, with their indexes. Every statement is IF NOT
   --  EXISTS, so applying it to an existing database is a no-op. The
   --  surface_row_id columns and what a surface reports about itself are added
   --  by Add_Column instead, which no CREATE can express for a table that
   --  already exists.

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
     (Project, Header_Text, Summary_Body : String) return String
     with SPARK_Mode => Off
   is
      Ctx : GNAT.SHA256.Context := GNAT.SHA256.Initial_Context;
      Nul : constant String := [1 => ASCII.NUL];
   begin
      GNAT.SHA256.Update (Ctx, Project);
      GNAT.SHA256.Update (Ctx, Nul);
      GNAT.SHA256.Update (Ctx, Header_Text);
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

   -----------------------------
   -- Checked statement layer --
   -----------------------------

   Sql_Error : exception;
   --  A SQLite status that is a failure rather than an answer. An operation
   --  catches it once, at the frame that owns the transaction. A non-Ok status
   --  that is an answer -- no such row, the end of a result set -- comes back
   --  as an out parameter instead, and never reaches here.

   procedure Check (St : Sql.Status)
     with --  St rather than True: stated as True the handle facts do not
          --  survive the raise, and Prepare's own exceptional case goes
          --  unproved.
          Post => St = Sql.Ok,
          Exceptional_Cases => (Sql_Error => St /= Sql.Ok);
   --  Let an Ok status through, and turn any other into Sql_Error.

   procedure Check (St : Sql.Status) is
   begin
      if St /= Sql.Ok then
         raise Sql_Error;
      end if;
   end Check;

   procedure Prepare (S : Store; Text : String; Stmt : out Sql.Statement)
     with Pre  => Is_Open (S) and then Text'Length > 0,
          Post => Sql.Is_Valid (Stmt),
          Exceptional_Cases => (Sql_Error => Sql.Is_Reclaimed (Stmt));
   --  Compile Text against S. A statement that comes back valid belongs to the
   --  frame that asked for it, and that frame releases it in its `finally`
   --  part: only a raise from Prepare itself reclaims.

   procedure Prepare (S : Store; Text : String; Stmt : out Sql.Statement) is
      St : Sql.Status;
   begin
      Sql.Prepare (S.DB, Text, Stmt, St);
      Check (St);
   end Prepare;

   procedure Bind (Stmt : Sql.Statement; Index : Positive; Value : String)
     with Pre => Sql.Is_Valid (Stmt),
          Exceptional_Cases => (Sql_Error => True);
   --  Bind text at the 1-based Index.

   procedure Bind (Stmt : Sql.Statement; Index : Positive; Value : String) is
      St : Sql.Status;
   begin
      Sql.Bind_Text (Stmt, Index, Value, St);
      Check (St);
   end Bind;

   procedure Bind (Stmt : Sql.Statement; Index : Positive; Value : Row_Id)
     with Pre => Sql.Is_Valid (Stmt),
          Exceptional_Cases => (Sql_Error => True);
   --  Bind a rowid at the 1-based Index.

   procedure Bind (Stmt : Sql.Statement; Index : Positive; Value : Row_Id) is
      St : Sql.Status;
   begin
      Sql.Bind_Int64 (Stmt, Index, Value, St);
      Check (St);
   end Bind;

   procedure Bind
     (Stmt : Sql.Statement; Index : Positive; Value : Packed_Blob)
     with Pre => Sql.Is_Valid (Stmt),
          Exceptional_Cases => (Sql_Error => True);
   --  Bind a packed embedding at the 1-based Index.

   procedure Bind
     (Stmt : Sql.Statement; Index : Positive; Value : Packed_Blob)
   is
      St : Sql.Status;
   begin
      Sql.Bind_Blob (Stmt, Index, Value, St);
      Check (St);
   end Bind;

   procedure Reset (Stmt : Sql.Statement)
     with Pre => Sql.Is_Valid (Stmt),
          Exceptional_Cases => (Sql_Error => True);
   --  Return a stepped statement to its initial state, bindings intact.

   procedure Reset (Stmt : Sql.Statement) is
      St : Sql.Status;
   begin
      Sql.Reset (Stmt, St);
      Check (St);
   end Reset;

   procedure Step_Row (Stmt : Sql.Statement; Have_Row : out Boolean)
     with Pre => Sql.Is_Valid (Stmt),
          Exceptional_Cases => (Sql_Error => True);
   --  Advance a query one row. Have_Row is False at the end of the result set,
   --  which is the one non-Ok outcome that is an answer.

   procedure Step_Row (Stmt : Sql.Statement; Have_Row : out Boolean) is
      St : Sql.Status;
   begin
      Sql.Step (Stmt, St);
      if St /= Sql.Row and then St /= Sql.Done then
         raise Sql_Error;
      end if;
      Have_Row := St = Sql.Row;
   end Step_Row;

   procedure Step_Done (Stmt : Sql.Statement)
     with Pre => Sql.Is_Valid (Stmt),
          Exceptional_Cases => (Sql_Error => True);
   --  Advance a statement that yields no rows. Anything but Done raises, a
   --  Row included.

   procedure Step_Done (Stmt : Sql.Statement) is
      St : Sql.Status;
   begin
      Sql.Step (Stmt, St);
      if St /= Sql.Done then
         raise Sql_Error;
      end if;
   end Step_Done;

   procedure Bind_Null (Stmt : Sql.Statement; Index : Positive)
     with Pre => Sql.Is_Valid (Stmt),
          Exceptional_Cases => (Sql_Error => True);
   --  Bind SQL NULL at the 1-based Index.

   procedure Bind_Null (Stmt : Sql.Statement; Index : Positive) is
      St : Sql.Status;
   begin
      Sql.Bind_Null (Stmt, Index, St);
      Check (St);
   end Bind_Null;

   procedure Bind_Surface
     (Stmt : Sql.Statement; Index : Positive; Id : Row_Id)
     with Pre => Sql.Is_Valid (Stmt),
          Exceptional_Cases => (Sql_Error => True);
   --  Bind the surfaces-row id at Index, or NULL for the unattributed write.

   procedure Bind_Surface
     (Stmt : Sql.Statement; Index : Positive; Id : Row_Id) is
   begin
      if Id = 0 then
         Bind_Null (Stmt, Index);
      else
         Bind (Stmt, Index, Id);
      end if;
   end Bind_Surface;

   procedure Exec (S : Store; Text : String)
     with Pre => Is_Open (S)
                 and then Text'Length > 0
                 and then Text'Last < Natural'Last,
          Exceptional_Cases => (Sql_Error => True);
   --  Run a resultless statement -- BEGIN, COMMIT, ROLLBACK, simple DML --
   --  as a whole.

   procedure Exec (S : Store; Text : String) is
      St : Sql.Status;
   begin
      Sql.Execute (S.DB, Text, St);
      Check (St);
   end Exec;

   procedure Rollback (S : Store)
     with Pre => Is_Open (S);
   --  Abandon the current transaction. It is reached from a handler, with
   --  nothing left to try, so a ROLLBACK that itself fails is logged rather
   --  than raised: promising not to raise is what makes it callable there.

   procedure Rollback (S : Store) is
   begin
      Exec (S, "ROLLBACK");
   exception
      when Sql_Error =>
         Memcp.Log.Error
           ("transaction ROLLBACK failed; database may be left "
            & "mid-transaction");
   end Rollback;
   -------------------
   -- Insert_Chunks --
   -------------------

   procedure Insert_Chunks
     (S           : Store;
      Session_Row : Row_Id;
      Proj_Id     : Row_Id;
      TS          : String;
      Chunks      : Chunk_Input_List)
     with Pre => Is_Open (S),
          Exceptional_Cases => (Sql_Error => True);
   --  Insert every element of Chunks, body and embedding, against one
   --  session row: shared by Save_Session and Reindex_Session. Ordinal is
   --  the 0-based position within Chunks. Runs inside the caller's
   --  transaction, and raises at the first SQLite failure.

   procedure Insert_Chunks
     (S           : Store;
      Session_Row : Row_Id;
      Proj_Id     : Row_Id;
      TS          : String;
      Chunks      : Chunk_Input_List)
   is
   begin
      for I in Chunk_Input_Vectors.First_Index (Chunks)
               .. Chunk_Input_Vectors.Last_Index (Chunks)
      loop
         declare
            El   : constant Chunk_Input :=
              Chunk_Input_Vectors.Element (Chunks, I);
            Ord  : constant Row_Id :=
              Row_Id (I - Chunk_Input_Vectors.First_Index (Chunks));
            Blob : constant Packed_Blob := To_Blob (El.Embedding);
            New_Chunk : Row_Id;
         begin
            Insert_Row :
            declare
               Ins : Sql.Statement;
            begin
               Prepare
                 (S,
                  "INSERT INTO chunks (session_row_id, project_id, ordinal,"
                  & " body, created_at) VALUES (?, ?, ?, ?, ?)", Ins);
               Bind (Ins, 1, Session_Row);
               Bind (Ins, 2, Proj_Id);
               Bind (Ins, 3, Ord);
               Bind (Ins, 4, El.Content);
               Bind (Ins, 5, TS);
               Step_Done (Ins);
            finally
               Sql.Finalize (Ins);
            end Insert_Row;

            New_Chunk := Sql.Last_Insert_Rowid (S.DB);

            Insert_Vec :
            declare
               Ins : Sql.Statement;
            begin
               Prepare
                 (S,
                  "INSERT INTO chunk_vec (rowid, embedding) VALUES (?, ?)",
                  Ins);
               Bind (Ins, 1, New_Chunk);
               Bind (Ins, 2, Blob);
               Step_Done (Ins);
            finally
               Sql.Finalize (Ins);
            end Insert_Vec;
         end;
      end loop;
   end Insert_Chunks;

   --------------------
   -- Filter helpers --
   --------------------

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

   procedure Project_Id (S : Store; Name : String; Id : out Row_Id)
     with Pre => Is_Open (S),
          Exceptional_Cases => (Sql_Error => True);
   --  The id of the project named Name, inserting the projects row when it
   --  does not exist yet.

   procedure Project_Id (S : Store; Name : String; Id : out Row_Id) is
      Found : Boolean;
   begin
      Id := 0;

      Look_Up :
      declare
         Stmt : Sql.Statement;
      begin
         Prepare (S, "SELECT id FROM projects WHERE name = ?", Stmt);
         Bind (Stmt, 1, Name);
         Step_Row (Stmt, Found);
         if Found then
            Id := Sql.Column_Int64 (Stmt, 0);
         end if;
      finally
         Sql.Finalize (Stmt);
      end Look_Up;

      if Found then
         return;
      end if;

      --  Not present: insert it.
      Add_Row :
      declare
         Stmt : Sql.Statement;
      begin
         Prepare (S, "INSERT INTO projects (name) VALUES (?)", Stmt);
         Bind (Stmt, 1, Name);
         Step_Done (Stmt);
      finally
         Sql.Finalize (Stmt);
      end Add_Row;

      Id := Sql.Last_Insert_Rowid (S.DB);
   end Project_Id;

   ----------------
   -- Add_Column --
   ----------------

   procedure Column_Present
     (S : Store; Table, Column : String; Present : out Boolean)
     with Pre => Is_Open (S)
                 and then Table'Length in 1 .. 64
                 and then Column'Length in 1 .. 64,
          Exceptional_Cases => (Sql_Error => True);
   --  Whether Table already carries Column.

   procedure Column_Present
     (S : Store; Table, Column : String; Present : out Boolean)
   is
      Stmt : Sql.Statement;
   begin
      Prepare (S, "SELECT 1 FROM pragma_table_info(?) WHERE name = ?", Stmt);
      Bind (Stmt, 1, Table);
      Bind (Stmt, 2, Column);
      Step_Row (Stmt, Present);
   finally
      Sql.Finalize (Stmt);
   end Column_Present;

   procedure Table_Present
     (S : Store; Table : String; Present : out Boolean)
     with Pre => Is_Open (S) and then Table'Length in 1 .. 64,
          Exceptional_Cases => (Sql_Error => True);
   --  Whether the database holds a table named Table.

   procedure Table_Present
     (S : Store; Table : String; Present : out Boolean)
   is
      Stmt : Sql.Statement;
   begin
      Prepare
        (S,
         "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
         Stmt);
      Bind (Stmt, 1, Table);
      Step_Row (Stmt, Present);
   finally
      Sql.Finalize (Stmt);
   end Table_Present;

   procedure Add_Column (S : Store; Table, Column, Decl : String)
     with Pre => Is_Open (S)
                 --  Bounded so the ALTER built below cannot overflow; every
                 --  caller passes a literal well inside these.
                 and then Table'Length in 1 .. 64
                 and then Column'Length in 1 .. 64
                 and then Decl'Length in 1 .. 128,
          Exceptional_Cases => (Sql_Error => True);
   --  Add Column to Table when it is absent, leaving an already-migrated
   --  database untouched. Absence is established first so that a failing ALTER
   --  is a real error rather than the expected duplicate-column refusal.

   procedure Add_Column (S : Store; Table, Column, Decl : String) is
      Present : Boolean;
   begin
      Column_Present (S, Table, Column, Present);

      --  An already-migrated database is a success, so the ALTER is the only
      --  statement that can fail here.
      if not Present then
         Exec
           (S, "ALTER TABLE " & Table & " ADD COLUMN " & Column & " " & Decl);
      end if;
   end Add_Column;

   -------------------------
   -- Migrate_To_Headers --
   -------------------------

   Cap_Image : constant String := "400";
   --  Max_Header as the text the migration's SQL compares lengths against.

   pragma Assert (Max_Header = 400);

   procedure Migrate_To_Headers (S : Store)
     with Pre => Is_Open (S),
          Exceptional_Cases => (Sql_Error => True);
   --  Fold the shape this schema replaced -- a summaries.headline derived from
   --  the summary body, beside a diary table 1:1 with summaries holding the
   --  line the model actually authored -- into one authored summaries.header,
   --  and drop what is left over. A no-op once summaries has no headline
   --  column, so a fresh or already-migrated database passes straight through.
   --
   --  The Header a row ends up with, in order of preference:
   --    * an autorecap's own body, which is what makes Header = Summary hold;
   --    * the diary line, where it is the one line within Max_Header that a
   --      Header is;
   --    * the headline it already had, which on a row whose diary line is a
   --      whole body is the marker-authored text that predates the split.
   --  A diary line that is neither promoted nor already contained in its
   --  summary body is appended to that body first, so nothing is dropped that
   --  no other column holds. A database carrying the old column but no diary
   --  table keeps every headline it had.

   procedure Migrate_To_Headers (S : Store) is
      Legacy     : Boolean;
      Have_Diary : Boolean;
   begin
      Column_Present (S, "summaries", "headline", Legacy);
      if not Legacy then
         return;
      end if;

      Table_Present (S, "diary", Have_Diary);
      Add_Column (S, "summaries", "header", "TEXT NOT NULL DEFAULT ''");

      Exec (S, "BEGIN");

      --  No handler: a migration that fails fails the open, and the failure
      --  path closes the connection, which is what discards the transaction.
      Exec
        (S,
         "UPDATE summaries SET header = body WHERE kind = 'autorecap'");

      if Have_Diary then
         Exec
           (S,
            "UPDATE summaries SET body = body || char(10) || char(10) ||"
            & " (SELECT d.body FROM diary d"
            & " WHERE d.summary_id = summaries.id)"
            & " WHERE kind <> 'autorecap' AND EXISTS"
            & " (SELECT 1 FROM diary d WHERE d.summary_id = summaries.id"
            & " AND NOT (length(d.body) <= " & Cap_Image
            & " AND instr(d.body, char(10)) = 0)"
            & " AND instr(summaries.body, d.body) = 0)");

         Exec
           (S,
            "UPDATE summaries SET header ="
            & " (SELECT d.body FROM diary d"
            & " WHERE d.summary_id = summaries.id)"
            & " WHERE kind <> 'autorecap' AND EXISTS"
            & " (SELECT 1 FROM diary d WHERE d.summary_id = summaries.id"
            & " AND length(d.body) <= " & Cap_Image
            & " AND instr(d.body, char(10)) = 0)");
      end if;

      --  Left empty above: a summary with no diary row behind it.
      Exec (S, "UPDATE summaries SET header = headline WHERE header = ''");

      Exec
        (S, "UPDATE summaries SET kind = 'authored' WHERE kind = 'diary'");

      Exec (S, "DROP INDEX IF EXISTS idx_diary_project_date");
      Exec (S, "DROP TABLE IF EXISTS diary");
      Exec (S, "ALTER TABLE summaries DROP COLUMN headline");

      Exec
        (S,
         "UPDATE meta SET value = '" & Schema_Version
         & "' WHERE key = 'schema_version'");

      Exec (S, "COMMIT");
   end Migrate_To_Headers;

   --------------------
   -- Surface_Row_Id --
   --------------------

   procedure Surface_Row_Id
     (S     : Store;
      Uuid  : String;
      Label : String;
      Now   : String;
      Id    : out Row_Id)
     with Pre => Is_Open (S),
          Exceptional_Cases => (Sql_Error => True);
   --  The id of the surfaces row for Uuid, inserting it when new and
   --  refreshing its label and last_seen when not. An empty Uuid is the
   --  unattributed write: Id comes back 0, which every caller binds as NULL.

   procedure Surface_Row_Id
     (S     : Store;
      Uuid  : String;
      Label : String;
      Now   : String;
      Id    : out Row_Id)
   is
      Found : Boolean;
   begin
      Id := 0;

      if Uuid'Length = 0 then
         return;
      end if;

      Look_Up :
      declare
         Stmt : Sql.Statement;
      begin
         Prepare (S, "SELECT id FROM surfaces WHERE surface_id = ?", Stmt);
         Bind (Stmt, 1, Uuid);
         Step_Row (Stmt, Found);
         if Found then
            Id := Sql.Column_Int64 (Stmt, 0);
         end if;
      finally
         Sql.Finalize (Stmt);
      end Look_Up;

      if Found then
         --  The label is config on the surface, so the newest write wins.
         Refresh :
         declare
            Stmt : Sql.Statement;
         begin
            Prepare
              (S,
               "UPDATE surfaces SET label = ?, last_seen = ? WHERE id = ?",
               Stmt);
            Bind (Stmt, 1, Label);
            Bind (Stmt, 2, Now);
            Bind (Stmt, 3, Id);
            Step_Done (Stmt);
         finally
            Sql.Finalize (Stmt);
         end Refresh;
      else
         Add_Row :
         declare
            Stmt : Sql.Statement;
         begin
            Prepare
              (S,
               "INSERT INTO surfaces (surface_id, label, first_seen,"
               & " last_seen) VALUES (?, ?, ?, ?)", Stmt);
            Bind (Stmt, 1, Uuid);
            Bind (Stmt, 2, Label);
            Bind (Stmt, 3, Now);
            Bind (Stmt, 4, Now);
            Step_Done (Stmt);
         finally
            Sql.Finalize (Stmt);
         end Add_Row;

         Id := Sql.Last_Insert_Rowid (S.DB);
      end if;
   end Surface_Row_Id;

   ----------
   -- Open --
   ----------

   procedure Open
     (S : out Store; DB_Path : String; Result : out Open_Status)
   is
      St : Sql.Status;

      procedure Assert_Meta (Key, Value : String; Outcome : out Open_Status)
        with Pre => Is_Open (S),
             Exceptional_Cases => (Sql_Error => True);
      --  Assert one meta (key, value) pair: insert it when absent, and
      --  report Meta_Mismatch when the stored value differs.

      procedure Assert_Meta (Key, Value : String; Outcome : out Open_Status) is
         Have_Row : Boolean;
         Matches  : Boolean := False;
      begin
         Look_Up :
         declare
            Stmt : Sql.Statement;
         begin
            Prepare (S, "SELECT value FROM meta WHERE key = ?", Stmt);
            Bind (Stmt, 1, Key);
            Step_Row (Stmt, Have_Row);
            if Have_Row then
               declare
                  Existing : Sql.Text_Ptr := Sql.Column_Text (Stmt, 0);
               begin
                  Matches := Existing.all = Value;
                  Sql.Free (Existing);
               end;
            end if;
         finally
            Sql.Finalize (Stmt);
         end Look_Up;

         if Have_Row then
            Outcome := (if Matches then Opened else Meta_Mismatch);
            return;
         end if;

         --  Absent: insert the default.
         Add_Row :
         declare
            Stmt : Sql.Statement;
         begin
            Prepare (S, "INSERT INTO meta (key, value) VALUES (?, ?)", Stmt);
            Bind (Stmt, 1, Key);
            Bind (Stmt, 2, Value);
            Step_Done (Stmt);
         finally
            Sql.Finalize (Stmt);
         end Add_Row;

         Outcome := Opened;
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

      Apply_Schema :
      begin
         Exec (S, Schema_SQL);
         Exec (S, Vec_Summary_SQL);
         Exec (S, Vec_Chunk_SQL);
         Add_Column
           (S, "summaries", "surface_row_id",
            "INTEGER REFERENCES surfaces(id)");
         Add_Column
           (S, "sessions", "surface_row_id",
            "INTEGER REFERENCES surfaces(id)");

         --  What a surface says about itself, all nullable: a row predating
         --  them is a surface that has not checked in since, not a surface at
         --  fault.
         Add_Column (S, "surfaces", "hook_version", "TEXT");
         Add_Column (S, "surfaces", "host", "TEXT");
         Add_Column (S, "surfaces", "install_host", "TEXT");

         Migrate_To_Headers (S);

         Assert_Meta ("schema_version", Schema_Version, Result);
         if Result = Opened then
            Assert_Meta ("embedding_model", Embedding_Model, Result);
         end if;
         if Result = Opened then
            Assert_Meta ("embedding_dim", Dim_Image, Result);
         end if;
      exception
         when Sql_Error =>
            Result := Schema_Error;
      end Apply_Schema;

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
     "SELECT s.id, p.name, s.session_id, s.created_at, s.header,"
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
      Stmt     : Sql.Statement;
      Have_Row : Boolean;
   begin
      Result := null;

      Prepare (S, Fetch_Summary_SQL, Stmt);
      Bind (Stmt, 1, Id);
      Step_Row (Stmt, Have_Row);

      if Have_Row then
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
               Header_Len   => Head.all'Length,
               Body_Len     => Bod.all'Length,
               Kind_Len     => Kind.all'Length,
               Id           => Id_C,
               Has_Session  => Has_S,
               Project      => Proj.all,
               Session      => Sess.all,
               Created_At   => Crea.all,
               Header       => Head.all,
               Content      => Bod.all,
               Kind         => Kind.all);
            Sql.Free (Proj);
            Sql.Free (Sess);
            Sql.Free (Crea);
            Sql.Free (Head);
            Sql.Free (Bod);
            Sql.Free (Kind);
         end;
      end if;

      --  No such id: Result stays null, which is an answer rather than a
      --  failure.
      Status := Success;
   exception
      when Sql_Error =>
         Status := Db_Error;
   finally
      Sql.Finalize (Stmt);
   end Fetch_Summary;

   ---------------------
   -- Recent_Headers --
   ---------------------

   procedure Recent_Headers
     (S        : Store;
      Projects : Name_List;
      N        : Natural;
      Result   : out Header_List;
      Status   : out Op_Status)
   is
      Len_CT : constant Name_Vectors.Capacity_Range :=
        Name_Vectors.Length (Projects);
   begin
      Result := Header_Vectors.Empty_Vector;

      --  No projects, or a filter too long to spell as a bounded IN clause:
      --  both return an empty list with Success.
      if Len_CT = 0 or else Len_CT > Max_Filter_Terms then
         Status := Success;
         return;
      end if;

      declare
         K        : constant Positive := Positive (Len_CT);
         Query    : constant String :=
           "SELECT s.id, p.name, s.session_id, s.created_at,"
           & " s.header, s.kind FROM summaries s"
           & " JOIN projects p ON p.id = s.project_id"
           & " WHERE p.name IN (" & Placeholders (K) & ")"
           & " ORDER BY s.created_at DESC LIMIT ?";
         Stmt     : Sql.Statement;
         Have_Row : Boolean;
      begin
         Prepare (S, Query, Stmt);

         --  The K project names go to params 1 .. K, the 1-based vector index
         --  doubling as the bind position, and N to the LIMIT param at K + 1.
         for I in Name_Vectors.First_Index (Projects)
                  .. Name_Vectors.Last_Index (Projects)
         loop
            pragma Loop_Invariant (Sql.Is_Valid (Stmt));
            --  The enclosing frame's `finally` writes Stmt, which puts it in
            --  this loop's frame: without the invariant, Prepare's Post does
            --  not survive the back edge.
            Bind (Stmt, I, Name_Vectors.Element (Projects, I).Value);
         end loop;
         Bind (Stmt, K + 1, Row_Id (N));

         --  One Header_Entry per row; the Length guard discharges Append's
         --  capacity precondition.
         loop
            pragma Loop_Invariant (Sql.Is_Valid (Stmt));
            --  As on the bind loop above.
            Step_Row (Stmt, Have_Row);
            exit when not Have_Row;
            exit when Header_Vectors.Length (Result) = Header_Vectors.Last_Count;
            declare
               Id_C  : constant Row_Id := Sql.Column_Int64 (Stmt, 0);
               Proj  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 1);
               Sess  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 2);
               Crea  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 3);
               Head  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 4);
               Kind  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 5);
               Null_S : constant Boolean := Sql.Column_Is_Null (Stmt, 2);
               Has_S  : constant Boolean := not Null_S;
               --  Two steps, as in Fetch_Summary: a volatile column read may
               --  not be an operand of `not`.
            begin
               Header_Vectors.Append
                 (Result,
                  Header_Entry'
                    (Project_Len => Proj.all'Length,
                     Session_Len => Sess.all'Length,
                     Created_Len => Crea.all'Length,
                     Header_Len  => Head.all'Length,
                     Kind_Len    => Kind.all'Length,
                     Summary_Id  => Id_C,
                     Has_Session => Has_S,
                     Project     => Proj.all,
                     Session     => Sess.all,
                     Created_At  => Crea.all,
                     Header      => Head.all,
                     Kind        => Kind.all));
               Sql.Free (Proj);
               Sql.Free (Sess);
               Sql.Free (Crea);
               Sql.Free (Head);
               Sql.Free (Kind);
            end;
         end loop;

         --  Leaving the loop with a row still pending is the vector filling
         --  up: the caller would be handed a truncated list, which is not a
         --  success.
         Status := (if Have_Row then Db_Error else Success);
      finally
         Sql.Finalize (Stmt);
      end;
   exception
      when Sql_Error =>
         Status := Db_Error;
   end Recent_Headers;

   -------------------
   -- List_Projects --
   -------------------

   procedure List_Projects
     (S      : Store;
      Result : out Project_Info_List;
      Status : out Op_Status)
   is
      Query : constant String :=
        "SELECT p.name, COUNT(s.id), MAX(s.created_at)"
        & " FROM projects p LEFT JOIN summaries s ON s.project_id = p.id"
        & " GROUP BY p.id, p.name"
        & " ORDER BY MAX(s.created_at) IS NULL,"
        & " MAX(s.created_at) DESC, p.name";
      Stmt     : Sql.Statement;
      Have_Row : Boolean;
   begin
      Result := Project_Vectors.Empty_Vector;

      Prepare (S, Query, Stmt);

      loop
         Step_Row (Stmt, Have_Row);
         exit when not Have_Row;
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
                  Header_Count => Cnt,
                  Has_Latest  => Has_L,
                  Name        => Nm.all,
                  Latest_At   => Lat.all));
            Sql.Free (Nm);
            Sql.Free (Lat);
         end;
      end loop;

      --  As in Recent_Headers: a row still pending means the vector filled.
      Status := (if Have_Row then Db_Error else Success);
   exception
      when Sql_Error =>
         Status := Db_Error;
   finally
      Sql.Finalize (Stmt);
   end List_Projects;

   ------------------
   -- Fleet_Health --
   ------------------

   procedure Fleet_Health
     (S      : Store;
      Window : Positive;
      Result : out Surface_Health_List;
      Status : out Op_Status)
   is
      Query : constant String :=
        "WITH ranked AS ("
        & " SELECT m.surface_row_id AS srf, m.project_id AS pid,"
        & " m.session_id AS sid,"
        & " ROW_NUMBER() OVER (PARTITION BY m.surface_row_id"
        & " ORDER BY m.created_at DESC) AS rn"
        & " FROM summaries m WHERE m.session_id IS NOT NULL),"
        & " win AS ("
        & " SELECT r.srf AS srf, COUNT(DISTINCT r.sid) AS sessions,"
        & " COUNT(DISTINCT CASE WHEN x.id IS NULL THEN r.sid END) AS missing"
        & " FROM ranked r"
        & " LEFT JOIN sessions x"
        & " ON x.project_id = r.pid AND x.session_id = r.sid"
        & " WHERE r.rn <= ?"
        & " GROUP BY r.srf)"
        & " SELECT f.label, f.surface_id, f.last_seen, f.hook_version,"
        & " f.host, f.install_host,"
        & " COALESCE (w.sessions, 0), COALESCE (w.missing, 0),"
        & " (SELECT MAX (m.created_at) FROM summaries m"
        & "  WHERE m.surface_row_id = f.id),"
        & " (SELECT MAX (x.created_at) FROM sessions x"
        & "  WHERE x.surface_row_id = f.id)"
        & " FROM surfaces f LEFT JOIN win w ON w.srf = f.id"
        & " UNION ALL"
        & " SELECT NULL, NULL, NULL, NULL, NULL, NULL,"
        & " w.sessions, w.missing,"
        & " (SELECT MAX (m.created_at) FROM summaries m"
        & "  WHERE m.surface_row_id IS NULL),"
        & " (SELECT MAX (x.created_at) FROM sessions x"
        & "  WHERE x.surface_row_id IS NULL)"
        & " FROM win w WHERE w.srf IS NULL"
        & " ORDER BY 8 DESC, 3 DESC";
      --  A summary whose session has no sessions row is a session that saved
      --  and was never uploaded. The roster is driven from surfaces, so a
      --  surface that has checked in and written nothing still appears; the
      --  second branch adds the sessions that named no surface, windowed
      --  together as one group because no row can tell them apart.

      Stmt     : Sql.Statement;
      Have_Row : Boolean;
   begin
      Result := Surface_Health_Vectors.Empty_Vector;

      Prepare (S, Query, Stmt);
      Bind (Stmt, 1, Row_Id (Window));

      loop
         Step_Row (Stmt, Have_Row);
         exit when not Have_Row;
         exit when Surface_Health_Vectors.Length (Result)
                   = Surface_Health_Vectors.Last_Count;
         declare
            Sess_C : constant Row_Id := Sql.Column_Int64 (Stmt, 6);
            Miss_C : constant Row_Id := Sql.Column_Int64 (Stmt, 7);
            Lab    : Sql.Text_Ptr := Sql.Column_Text (Stmt, 0);
            Uid    : Sql.Text_Ptr := Sql.Column_Text (Stmt, 1);
            Seen   : Sql.Text_Ptr := Sql.Column_Text (Stmt, 2);
            Ver    : Sql.Text_Ptr := Sql.Column_Text (Stmt, 3);
            Hst    : Sql.Text_Ptr := Sql.Column_Text (Stmt, 4);
            Inst   : Sql.Text_Ptr := Sql.Column_Text (Stmt, 5);
            Saved  : Sql.Text_Ptr := Sql.Column_Text (Stmt, 8);
            Upl    : Sql.Text_Ptr := Sql.Column_Text (Stmt, 9);
            Null_L : constant Boolean := Sql.Column_Is_Null (Stmt, 0);
            Attr   : constant Boolean := not Null_L;
            --  Two steps, as in Recent_Headers: a volatile column read may not
            --  be an operand of `not`.
         begin
            Surface_Health_Vectors.Append
              (Result,
               Surface_Health'
                 (Label_Len     => Lab.all'Length,
                  Uuid_Len      => Uid.all'Length,
                  Seen_Len      => Seen.all'Length,
                  Version_Len   => Ver.all'Length,
                  Host_Len      => Hst.all'Length,
                  Install_Len   => Inst.all'Length,
                  Saved_Len     => Saved.all'Length,
                  Uploaded_Len  => Upl.all'Length,
                  Attributed    => Attr,
                  Sessions      => Sess_C,
                  Missing       => Miss_C,
                  Label         => Lab.all,
                  Uuid          => Uid.all,
                  Last_Seen     => Seen.all,
                  Hook_Version  => Ver.all,
                  Host          => Hst.all,
                  Install_Host  => Inst.all,
                  Last_Saved    => Saved.all,
                  Last_Uploaded => Upl.all));
            Sql.Free (Lab);
            Sql.Free (Uid);
            Sql.Free (Seen);
            Sql.Free (Ver);
            Sql.Free (Hst);
            Sql.Free (Inst);
            Sql.Free (Saved);
            Sql.Free (Upl);
         end;
      end loop;

      --  As in Recent_Headers: a row still pending means the vector filled.
      Status := (if Have_Row then Db_Error else Success);
   exception
      when Sql_Error =>
         Status := Db_Error;
   finally
      Sql.Finalize (Stmt);
   end Fleet_Health;

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
      Fleet : Surface_Health_List;
   begin
      Result := Surface_Health_Vectors.Empty_Vector;
      Fleet_Health (S, Window, Fleet, Status);
      if Status /= Success then
         return;
      end if;

      for I in Surface_Health_Vectors.First_Index (Fleet)
               .. Surface_Health_Vectors.Last_Index (Fleet)
      loop
         exit when Surface_Health_Vectors.Length (Result)
                   = Surface_Health_Vectors.Last_Count;
         declare
            E : constant Surface_Health :=
              Surface_Health_Vectors.Element (Fleet, I);
         begin
            if E.Missing >= Row_Id (Least) then
               Surface_Health_Vectors.Append (Result, E);
            end if;
         end;
      end loop;
   end Degraded_Surfaces;

   -------------------
   -- Touch_Surface --
   -------------------

   procedure Touch_Surface
     (S            : Store;
      Uuid         : String;
      Label        : String;
      Hook_Version : String;
      Host         : String;
      Install_Host : String;
      Status       : out Op_Status)
   is
      Report : constant String :=
        "UPDATE surfaces SET"
        & " hook_version = COALESCE (NULLIF (?, ''), hook_version),"
        & " host = COALESCE (NULLIF (?, ''), host),"
        & " install_host = COALESCE (NULLIF (?, ''), install_host)"
        & " WHERE id = ?";
      --  NULLIF ahead of COALESCE is what makes a field the caller does not
      --  know keep the value already on record: only Surface_Row_Id's own
      --  columns are unconditional.

      Id : Row_Id;
   begin
      Surface_Row_Id (S, Uuid, Label, Now_Iso, Id);

      --  Id is 0 only for the empty Uuid, which is the caller asking for
      --  nothing. A named surface that resolved to no row means the upsert
      --  reported a success it did not achieve.
      if Uuid'Length > 0 and then Id = 0 then
         Status := Db_Error;
         return;
      end if;

      if Id = 0 then
         Status := Success;
         return;
      end if;

      declare
         Stmt : Sql.Statement;
      begin
         Prepare (S, Report, Stmt);
         Bind (Stmt, 1, Hook_Version);
         Bind (Stmt, 2, Host);
         Bind (Stmt, 3, Install_Host);
         Bind (Stmt, 4, Id);
         Step_Done (Stmt);
         Status := Success;
      finally
         Sql.Finalize (Stmt);
      end;
   exception
      when Sql_Error =>
         Status := Db_Error;
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

      Stmt     : Sql.Statement;
      Have_Row : Boolean;

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

      Prepare (S, Query, Stmt);

      Bind (Stmt, 1, Session_Id);
      if Has_Project then
         Bind (Stmt, P_Project, Project);
      end if;
      if Has_Start then
         Bind (Stmt, P_Start, Start_Ord);
      end if;
      if Has_End then
         Bind (Stmt, P_End, End_Ord);
      end if;
      if Has_Tail then
         Bind (Stmt, P_Tail, Row_Id (Tail));
      end if;

      loop
         Step_Row (Stmt, Have_Row);
         exit when not Have_Row;
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

      --  As in Recent_Headers: a row still pending means the vector filled.
      Status := (if Have_Row then Db_Error else Success);
   exception
      when Sql_Error =>
         Status := Db_Error;
   finally
      Sql.Finalize (Stmt);
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
      Count       : Natural := 0;
   begin
      Result := Summary_Hit_Vectors.Empty_Vector;

      if Lim = 0 or else Len_P > Max_Filter_Terms then
         Status := Success;
         return;
      end if;

      declare
         K1        : Sql.Statement;
         Have_Cand : Boolean;
      begin
         Prepare
           (S,
            "SELECT rowid, distance FROM summary_vec"
            & " WHERE embedding MATCH ? ORDER BY distance LIMIT ?", K1);
         Bind (K1, 1, Blob);
         Bind (K1, 2, Row_Id (Over));

         --  One prepared per-row fetch, reset and rebound between candidates:
         --  the filtered over-fetch runs to Lim * 5 rows.
         declare
            M : Sql.Statement;
         begin
            Prepare (S, Fetch_Summary_SQL, M);

            loop
               pragma Loop_Invariant
                 (Sql.Is_Valid (K1) and then Sql.Is_Valid (M));
               --  Both handles are written by a `finally`, as in Recent_Headers,
               --  and so are in this loop's frame.
               Step_Row (K1, Have_Cand);
               exit when not Have_Cand;
               exit when Count >= Lim;
               exit when Summary_Hit_Vectors.Length (Result)
                         = Summary_Hit_Vectors.Last_Count;
               declare
                  Rid  : constant Row_Id := Sql.Column_Int64 (K1, 0);
                  Dist : constant Interfaces.IEEE_Float_64 :=
                    Sql.Column_Double (K1, 1);
                  Have_Meta : Boolean;
               begin
                  Reset (M);
                  Bind (M, 1, Rid);
                  Step_Row (M, Have_Meta);
                  if Have_Meta then
                     declare
                        Proj  : Sql.Text_Ptr := Sql.Column_Text (M, 1);
                        Sess  : Sql.Text_Ptr := Sql.Column_Text (M, 2);
                        Crea  : Sql.Text_Ptr := Sql.Column_Text (M, 3);
                        Head  : Sql.Text_Ptr := Sql.Column_Text (M, 4);
                        Bod   : Sql.Text_Ptr := Sql.Column_Text (M, 5);
                        Kind  : Sql.Text_Ptr := Sql.Column_Text (M, 6);
                        Null_S : constant Boolean := Sql.Column_Is_Null (M, 2);
                        Has_S  : constant Boolean := not Null_S;
                        --  Two steps, as in Fetch_Summary: a volatile column
                        --  read may not be an operand of `not`.
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
                                 Header_Len   => Head.all'Length,
                                 Body_Len     => Bod.all'Length,
                                 Kind_Len     => Kind.all'Length,
                                 Id           => Rid,
                                 Has_Session  => Has_S,
                                 Project      => Proj.all,
                                 Session      => Sess.all,
                                 Created_At   => Crea.all,
                                 Header       => Head.all,
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
               end;
            end loop;
         finally
            Sql.Finalize (M);
         end;

         --  Stopping early -- enough hits, or at capacity -- is as much a
         --  success as exhausting the candidates: a partial read is still a
         --  read. Only an unreadable row is a failure, and that raises.
         Status := Success;
      finally
         Sql.Finalize (K1);
      end;
   exception
      when Sql_Error =>
         Status := Db_Error;
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
      Count       : Natural := 0;
   begin
      Result := Chunk_Hit_Vectors.Empty_Vector;

      if Lim = 0
        or else Len_P > Max_Filter_Terms
        or else Len_S > Max_Filter_Terms
      then
         Status := Success;
         return;
      end if;

      declare
         K1        : Sql.Statement;
         Have_Cand : Boolean;
      begin
         Prepare
           (S,
            "SELECT rowid, distance FROM chunk_vec"
            & " WHERE embedding MATCH ? ORDER BY distance LIMIT ?", K1);
         Bind (K1, 1, Blob);
         Bind (K1, 2, Row_Id (Over));

         --  One prepared per-row fetch, reset and rebound between candidates,
         --  as in Search_Summaries.
         declare
            M : Sql.Statement;
         begin
            Prepare (S, Chunk_By_Id_SQL, M);

            loop
               pragma Loop_Invariant
                 (Sql.Is_Valid (K1) and then Sql.Is_Valid (M));
               --  As in Search_Summaries.
               Step_Row (K1, Have_Cand);
               exit when not Have_Cand;
               exit when Count >= Lim;
               exit when Chunk_Hit_Vectors.Length (Result)
                         = Chunk_Hit_Vectors.Last_Count;
               declare
                  Rid  : constant Row_Id := Sql.Column_Int64 (K1, 0);
                  Dist : constant Interfaces.IEEE_Float_64 :=
                    Sql.Column_Double (K1, 1);
                  Have_Meta : Boolean;
               begin
                  Reset (M);
                  Bind (M, 1, Rid);
                  Step_Row (M, Have_Meta);
                  if Have_Meta then
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
                            (Len_S = 0
                             or else Contains (Session_Ids, Sess.all))
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
               end;
            end loop;
         finally
            Sql.Finalize (M);
         end;

         --  As in Search_Summaries: stopping early is still a read.
         Status := Success;
      finally
         Sql.Finalize (K1);
      end;
   exception
      when Sql_Error =>
         Status := Db_Error;
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
      Exists : Boolean;
   begin
      Deleted := False;

      Exec (S, "BEGIN");

      Transaction :
      begin
         Row_Present :
         declare
            Stmt : Sql.Statement;
         begin
            Prepare (S, "SELECT id FROM summaries WHERE id = ?", Stmt);
            Bind (Stmt, 1, Id);
            Step_Row (Stmt, Exists);
         finally
            Sql.Finalize (Stmt);
         end Row_Present;

         if Exists then
            --  Delete the embedding (vec0 has no FK), then the summary.
            Delete_Vec :
            declare
               Stmt : Sql.Statement;
            begin
               Prepare (S, "DELETE FROM summary_vec WHERE rowid = ?", Stmt);
               Bind (Stmt, 1, Id);
               Step_Done (Stmt);
            finally
               Sql.Finalize (Stmt);
            end Delete_Vec;

            Delete_Summary :
            declare
               Stmt : Sql.Statement;
            begin
               Prepare (S, "DELETE FROM summaries WHERE id = ?", Stmt);
               Bind (Stmt, 1, Id);
               Step_Done (Stmt);
            finally
               Sql.Finalize (Stmt);
            end Delete_Summary;

            Exec (S, "COMMIT");
            Deleted := True;
         else
            --  Nothing to forget is a successful forget; the transaction is
            --  closed rather than committed.
            Rollback (S);
         end if;
      exception
         when Sql_Error =>
            Rollback (S);
            raise;
      end Transaction;

      Status := Success;
   exception
      when Sql_Error =>
         Status := Db_Error;
   end Forget_Summary;

   ----------
   -- Save --
   ----------

   procedure Save
     (S            : Store;
      Project      : String;
      Header_Text  : String;
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
      DH      : constant String := Dedup_Hash (Project, Header_Text, Summary_Body);
      Blob    : constant Packed_Blob := To_Blob (Embedding);

      procedure Put_Vec (Row : Row_Id)
        with Pre => Is_Open (S),
             Exceptional_Cases => (Sql_Error => True);
      --  Attach this call's embedding to summaries row Row.
      --  Delete-then-insert, so it serves both a fresh insert and an
      --  in-place replace.

      procedure Put_Vec (Row : Row_Id) is
      begin
         Drop_Old :
         declare
            Vs : Sql.Statement;
         begin
            Prepare (S, "DELETE FROM summary_vec WHERE rowid = ?", Vs);
            Bind (Vs, 1, Row);
            Step_Done (Vs);
         finally
            Sql.Finalize (Vs);
         end Drop_Old;

         Put_New :
         declare
            Vs : Sql.Statement;
         begin
            Prepare
              (S, "INSERT INTO summary_vec (rowid, embedding) VALUES (?, ?)",
               Vs);
            Bind (Vs, 1, Row);
            Bind (Vs, 2, Blob);
            Step_Done (Vs);
         finally
            Sql.Finalize (Vs);
         end Put_New;
      end Put_Vec;
   begin
      Result := (Summary_Id => 0,
                 Already_Existed => False, Replaced => False);

      Project_Id (S, Project, Proj_Id);
      Surface_Row_Id (S, Surface, Surface_Label, TS, Surf_Id);

      --  ---- session-scoped upsert path ----
      if Has_Session then
         declare
            Found      : Boolean;
            Ex_Summary : Row_Id := 0;
            Same_Hash  : Boolean := False;
         begin
            Look_Up :
            declare
               Q : Sql.Statement;
            begin
               Prepare
                 (S,
                  "SELECT s.id, s.dedup_hash FROM summaries s"
                  & " WHERE s.project_id = ? AND s.session_id = ? LIMIT 1",
                  Q);
               Bind (Q, 1, Proj_Id);
               Bind (Q, 2, Session_Id);
               Step_Row (Q, Found);
               if Found then
                  Ex_Summary := Sql.Column_Int64 (Q, 0);
                  declare
                     H : Sql.Text_Ptr := Sql.Column_Text (Q, 1);
                  begin
                     Same_Hash := H.all = DH;
                     Sql.Free (H);
                  end;
               end if;
            finally
               Sql.Finalize (Q);
            end Look_Up;

            if Found and then Same_Hash then
               Result := (Summary_Id => Ex_Summary,
                          Already_Existed => True, Replaced => False);
               Status := Success;
               return;
            end if;

            if Found then
               --  Replace in place, inside a transaction.
               Exec (S, "BEGIN");

               Update_Existing :
               begin
                  Update_Summary :
                  declare
                     US : Sql.Statement;
                  begin
                     Prepare
                       (S,
                        "UPDATE summaries SET created_at = ?, header = ?,"
                        & " body = ?, dedup_hash = ?, kind = ?,"
                        & " surface_row_id = ? WHERE id = ?", US);
                     Bind (US, 1, TS);
                     Bind (US, 2, Header_Text);
                     Bind (US, 3, Summary_Body);
                     Bind (US, 4, DH);
                     Bind (US, 5, Kind_Authored);
                     --  The replacing write owns the row, so an unattributed
                     --  replace clears an attribution rather than keeping a
                     --  stale one.
                     Bind_Surface (US, 6, Surf_Id);
                     Bind (US, 7, Ex_Summary);
                     Step_Done (US);
                  finally
                     Sql.Finalize (US);
                  end Update_Summary;

                  Put_Vec (Ex_Summary);

                  Exec (S, "COMMIT");
               exception
                  when Sql_Error =>
                     Rollback (S);
                     raise;
               end Update_Existing;

               Result := (Summary_Id => Ex_Summary,
                          Already_Existed => True, Replaced => True);
               Status := Success;
               return;
            end if;
         end;
      end if;

      --  ---- content-dedup path ----
      declare
         Found      : Boolean;
         Ex_Summary : Row_Id := 0;
      begin
         Dedup_Look_Up :
         declare
            Q : Sql.Statement;
         begin
            Prepare
              (S,
               "SELECT s.id FROM summaries s"
               & " WHERE s.dedup_hash = ? AND s.project_id = ? LIMIT 1", Q);
            Bind (Q, 1, DH);
            Bind (Q, 2, Proj_Id);
            Step_Row (Q, Found);
            if Found then
               Ex_Summary := Sql.Column_Int64 (Q, 0);
            end if;
         finally
            Sql.Finalize (Q);
         end Dedup_Look_Up;

         if Found then
            Result := (Summary_Id => Ex_Summary,
                       Already_Existed => True, Replaced => False);
            Status := Success;
            return;
         end if;
      end;

      --  ---- fresh insert path ----
      Insert_Fresh :
      declare
         New_Summary : Row_Id;
      begin
         Exec (S, "BEGIN");

         Transaction :
         begin
            Insert_Summary :
            declare
               Ins : Sql.Statement;
            begin
               Prepare
                 (S,
                  "INSERT INTO summaries (project_id, session_id, created_at,"
                  & " header, body, dedup_hash, kind, surface_row_id)"
                  & " VALUES (?, ?, ?, ?, ?, ?, ?, ?)", Ins);
               Bind (Ins, 1, Proj_Id);
               if Has_Session then
                  Bind (Ins, 2, Session_Id);
               else
                  Bind_Null (Ins, 2);
               end if;
               Bind (Ins, 3, TS);
               Bind (Ins, 4, Header_Text);
               Bind (Ins, 5, Summary_Body);
               Bind (Ins, 6, DH);
               Bind (Ins, 7, Kind_Authored);
               Bind_Surface (Ins, 8, Surf_Id);
               Step_Done (Ins);
            finally
               Sql.Finalize (Ins);
            end Insert_Summary;

            New_Summary := Sql.Last_Insert_Rowid (S.DB);
            Put_Vec (New_Summary);

            Exec (S, "COMMIT");
         exception
            when Sql_Error =>
               Rollback (S);
               raise;
         end Transaction;

         Result := (Summary_Id => New_Summary,
                    Already_Existed => False, Replaced => False);
         Status := Success;
      end Insert_Fresh;
   exception
      when Sql_Error =>
         Status := Db_Error;
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

      Project_Id (S, Project, Proj_Id);
      Surface_Row_Id (S, Surface, Surface_Label, TS, Surf_Id);

      --  ---- idempotency: existing (project, session) row is a no-op ----
      declare
         Found : Boolean;
         Ex_Id : Row_Id := 0;
      begin
         Look_Up :
         declare
            Q : Sql.Statement;
         begin
            Prepare
              (S,
               "SELECT id FROM sessions WHERE project_id = ?"
               & " AND session_id = ?", Q);
            Bind (Q, 1, Proj_Id);
            Bind (Q, 2, Session_Id);
            Step_Row (Q, Found);
            if Found then
               Ex_Id := Sql.Column_Int64 (Q, 0);
            end if;
         finally
            Sql.Finalize (Q);
         end Look_Up;

         if Found then
            --  Return the existing row's id and its current chunk count,
            --  inserting nothing.
            Count_Chunks :
            declare
               C        : Sql.Statement;
               Have_Row : Boolean;
               Cnt      : Natural := 0;
            begin
               Prepare
                 (S,
                  "SELECT id FROM chunks WHERE session_row_id = ?"
                  & " ORDER BY ordinal", C);
               Bind (C, 1, Ex_Id);
               loop
                  pragma Loop_Invariant (Sql.Is_Valid (C));
                  --  The frame's `finally` writes C; see Recent_Headers.
                  Step_Row (C, Have_Row);
                  exit when not Have_Row;
                  --  A session holding more chunks than Natural can count is
                  --  one this code cannot report on.
                  if Cnt = Natural'Last then
                     raise Sql_Error;
                  end if;
                  Cnt := Cnt + 1;
               end loop;
               Result := (Session_Row_Id => Ex_Id, Chunk_Count => Cnt,
                          Already_Existed => True, Raw_Path_Set => False);
               Status := Success;
            finally
               Sql.Finalize (C);
            end Count_Chunks;
            return;
         end if;
      end;

      --  ---- fresh session: write transcript (best-effort) + insert rows ----
      declare
         Raw_Path : Path_Access := null;
         New_Sess : Row_Id;
      begin
         --  A ":memory:" store has no on-disk parent, so skip the transcript
         --  entirely. Otherwise the write is best-effort: Raw_Path stays null
         --  on any I/O failure and the chunks still land.
         if S.DB_Path /= null and then S.DB_Path.all /= ":memory:" then
            Write_Session_File
              (Parent_Dir (S.DB_Path.all), Project, Session_Id, Transcript,
               Raw_Path);
         end if;

         Exec (S, "BEGIN");

         Transaction :
         begin
            Insert_Session :
            declare
               Ins : Sql.Statement;
            begin
               Prepare
                 (S,
                  "INSERT INTO sessions (project_id, session_id, created_at,"
                  & " raw_path, surface_row_id) VALUES (?, ?, ?, ?, ?)", Ins);
               Bind (Ins, 1, Proj_Id);
               Bind (Ins, 2, Session_Id);
               Bind (Ins, 3, TS);
               if Raw_Path /= null then
                  Bind (Ins, 4, Raw_Path.all);
               else
                  Bind_Null (Ins, 4);
               end if;
               Bind_Surface (Ins, 5, Surf_Id);
               Step_Done (Ins);
            finally
               Sql.Finalize (Ins);
            end Insert_Session;

            New_Sess := Sql.Last_Insert_Rowid (S.DB);
            Insert_Chunks (S, New_Sess, Proj_Id, TS, Chunks);
            Exec (S, "COMMIT");
         exception
            when Sql_Error =>
               Rollback (S);
               raise;
         end Transaction;

         Result :=
           (Session_Row_Id  => New_Sess,
            Chunk_Count     => Natural (Chunk_Input_Vectors.Length (Chunks)),
            Already_Existed => False,
            Raw_Path_Set    => Raw_Path /= null);
         Status := Success;
      finally
         Free_Path (Raw_Path);
      end;
   exception
      when Sql_Error =>
         Status := Db_Error;
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
      DH   : constant String := Dedup_Hash (Project, Recap_Text, Recap_Text);
      Blob : constant Packed_Blob := To_Blob (Embedding);
   begin
      Result := (Summary_Id => 0, Written => False);

      Project_Id (S, Project, Proj_Id);
      Surface_Row_Id (S, Surface, Surface_Label, TS, Surf_Id);

      --  Short-circuit: any existing summary for (project, session) wins.
      declare
         Found : Boolean;
      begin
         Look_Up :
         declare
            Q : Sql.Statement;
         begin
            Prepare
              (S,
               "SELECT id FROM summaries WHERE project_id = ?"
               & " AND session_id = ? LIMIT 1", Q);
            Bind (Q, 1, Proj_Id);
            Bind (Q, 2, Session_Id);
            Step_Row (Q, Found);
         finally
            Sql.Finalize (Q);
         end Look_Up;

         if Found then
            --  Leave Written False: declining to write is a successful
            --  outcome, not an error.
            Status := Success;
            return;
         end if;
      end;

      --  ---- fresh insert: summary(kind=autorecap) + embedding ----
      Insert_Fresh :
      declare
         New_Summary : Row_Id;
      begin
         Exec (S, "BEGIN");

         Transaction :
         begin
            Insert_Summary :
            declare
               Ins : Sql.Statement;
            begin
               Prepare
                 (S,
                  "INSERT INTO summaries (project_id, session_id, created_at,"
                  & " header, body, dedup_hash, kind, surface_row_id)"
                  & " VALUES (?, ?, ?, ?, ?, ?, ?, ?)", Ins);
               Bind (Ins, 1, Proj_Id);
               Bind (Ins, 2, Session_Id);
               Bind (Ins, 3, TS);
               --  Both, so Header = Summary holds and a reader can take the
               --  kind at its word and skip the fetch.
               Bind (Ins, 4, Recap_Text);
               Bind (Ins, 5, Recap_Text);
               Bind (Ins, 6, DH);
               Bind (Ins, 7, Kind_Autorecap);
               Bind_Surface (Ins, 8, Surf_Id);
               Step_Done (Ins);
            finally
               Sql.Finalize (Ins);
            end Insert_Summary;

            New_Summary := Sql.Last_Insert_Rowid (S.DB);

            Insert_Vec :
            declare
               Ins : Sql.Statement;
            begin
               Prepare
                 (S,
                  "INSERT INTO summary_vec (rowid, embedding) VALUES (?, ?)",
                  Ins);
               Bind (Ins, 1, New_Summary);
               Bind (Ins, 2, Blob);
               Step_Done (Ins);
            finally
               Sql.Finalize (Ins);
            end Insert_Vec;

            Exec (S, "COMMIT");
         exception
            when Sql_Error =>
               Rollback (S);
               raise;
         end Transaction;

         Result := (Summary_Id => New_Summary, Written => True);
         Status := Success;
      end Insert_Fresh;
   exception
      when Sql_Error =>
         Status := Db_Error;
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

      Project_Id (S, Project, Proj_Id);

      --  Locate the session row + its original created_at (copied out so the
      --  new chunks can inherit it after the cursor is gone). The copy doubles
      --  as the found flag: no row, no copy.
      declare
         Sess_Id : Row_Id := 0;
         TS_Copy : Path_Access := null;
      begin
         Look_Up :
         declare
            Q    : Sql.Statement;
            Have : Boolean;
         begin
            Prepare
              (S,
               "SELECT id, created_at FROM sessions"
               & " WHERE project_id = ? AND session_id = ?", Q);
            Bind (Q, 1, Proj_Id);
            Bind (Q, 2, Session_Id);
            Step_Row (Q, Have);
            if Have then
               Sess_Id := Sql.Column_Int64 (Q, 0);
               declare
                  T : Sql.Text_Ptr := Sql.Column_Text (Q, 1);
               begin
                  TS_Copy := new String'(T.all);
                  Sql.Free (T);
               end;
            end if;
         finally
            Sql.Finalize (Q);
         end Look_Up;

         if TS_Copy = null then
            --  No such session: Found stays False, which is an answer.
            Status := Success;
         else
            --  Replace the chunks in one transaction: delete each old chunk's
            --  embedding (vec0 has no FK cascade), bulk-delete the chunk rows,
            --  then insert the new ones with the session's original timestamp.
            Exec (S, "BEGIN");

            Transaction :
            begin
               Drop_Vectors :
               declare
                  Sel      : Sql.Statement;
                  Have_Row : Boolean;
                  Cnt      : Natural := 0;
               begin
                  Prepare
                    (S, "SELECT id FROM chunks WHERE session_row_id = ?", Sel);
                  Bind (Sel, 1, Sess_Id);
                  loop
                     pragma Loop_Invariant (Sql.Is_Valid (Sel));
                     --  The frame's `finally` writes Sel; see Recent_Headers.
                     Step_Row (Sel, Have_Row);
                     exit when not Have_Row;
                     --  A session holding more chunks than Natural can count
                     --  is one this code cannot reindex.
                     if Cnt = Natural'Last then
                        raise Sql_Error;
                     end if;
                     declare
                        Old_Id : constant Row_Id := Sql.Column_Int64 (Sel, 0);
                        DV     : Sql.Statement;
                     begin
                        Prepare
                          (S, "DELETE FROM chunk_vec WHERE rowid = ?", DV);
                        Bind (DV, 1, Old_Id);
                        Step_Done (DV);
                     finally
                        Sql.Finalize (DV);
                     end;
                     Cnt := Cnt + 1;
                  end loop;
                  Old_Count := Cnt;
               finally
                  Sql.Finalize (Sel);
               end Drop_Vectors;

               Drop_Chunks :
               declare
                  D : Sql.Statement;
               begin
                  Prepare
                    (S, "DELETE FROM chunks WHERE session_row_id = ?", D);
                  Bind (D, 1, Sess_Id);
                  Step_Done (D);
               finally
                  Sql.Finalize (D);
               end Drop_Chunks;

               Insert_Chunks (S, Sess_Id, Proj_Id, TS_Copy.all, Chunks);
               Exec (S, "COMMIT");
            exception
               when Sql_Error =>
                  Rollback (S);
                  raise;
            end Transaction;

            Found     := True;
            New_Count := Natural (Chunk_Input_Vectors.Length (Chunks));
            Status    := Success;
         end if;
      finally
         Free_Path (TS_Copy);
      end;
   exception
      when Sql_Error =>
         Status := Db_Error;
   end Reindex_Session;

end Memcp.Store;
