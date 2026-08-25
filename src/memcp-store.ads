--  memcp's storage layer over the sqlite_vec_spark primitives: the schema, the
--  record types the tools hand back, and the queries behind them. One SQLite
--  file, one vec0 table per embedded record type.

with Ada.Unchecked_Deallocation;
with Interfaces;

with SPARK.Containers.Formal.Unbounded_Vectors;

with Sqlite_Vec_Spark;
with Candle_Spark;

package Memcp.Store with SPARK_Mode => On is

   Embedding_Dim  : constant := 384;
   --  Vector dimension; must match Candle_Spark's Dimension and sqlite-vec's
   --  packed float[384].

   Schema_Version : constant String := "2";
   --  Schema version stamped into the meta row.

   Embedding_Model : constant String :=
     "sentence-transformers/all-MiniLM-L6-v2";
   --  Embedding model id stamped into the meta row.

   Kind_Authored : constant String := "authored";
   --  Header kind for a Header and Summary the model wrote itself.

   Kind_Autorecap : constant String := "autorecap";
   --  Header kind for the SessionEnd fallback recap.

   subtype Row_Id is Interfaces.Integer_64;
   --  A SQLite rowid: signed 64-bit.

   type Store is limited private
     with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
          Default_Initial_Condition =>
            not Is_Open (Store) and then Is_Reclaimed (Store);
   --  The storage handle: owns one SQLite connection, with vec0 registered,
   --  foreign_keys ON and WAL. Limited, because a copy would double-close that
   --  connection.

   function Is_Open (S : Store) return Boolean;
   --  Whether the store's connection is currently open.
   --  @param S The store to test.
   --  @return True iff S holds an open SQLite connection.

   function Is_Reclaimed (S : Store) return Boolean
     with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
   --  Reclamation predicate for Store: reclaimed once the connection is
   --  reclaimed and the remembered path released.
   --  @param S The store to test.
   --  @return True iff S owns no connection and no path.

   -----------------------
   -- Connection / init --
   -----------------------

   type Open_Status is (Opened, Cannot_Open, Schema_Error, Meta_Mismatch);
   --  Outcome of opening a store.
   --  @enum Opened The connection opened and the schema/meta row are valid.
   --  @enum Cannot_Open The SQLite connection could not be opened.
   --  @enum Schema_Error Applying the schema or vec0 tables failed.
   --  @enum Meta_Mismatch An existing DB's recorded schema/model disagrees with
   --    this build; the open is refused, nothing is rewritten.

   procedure Open
     (S : out Store; DB_Path : String; Result : out Open_Status)
     with Pre  => DB_Path'Length > 0 and then DB_Path'Last < Natural'Last,
          Post => (Is_Open (S) = (Result = Opened))
                  and then (Is_Reclaimed (S) = (Result /= Opened));
   --  Open (or create) the store at DB_Path: open the connection, apply the
   --  full schema plus the two vec0 virtual tables, migrate a database written
   --  against an older schema, then assert the meta row. On any failure the
   --  connection is closed and S is left reclaimed -- which is also what
   --  discards a migration that did not finish.
   --  @param S The store to open (initialized on return).
   --  @param DB_Path Filesystem path to the SQLite DB (or ":memory:").
   --  @param Result The outcome of the open attempt.

   procedure Close (S : in out Store)
     with Post    => not Is_Open (S) and then Is_Reclaimed (S),
          Global  => (In_Out => Sqlite_Vec_Spark.DBMS),
          --  S's old connection reaches C only as an address, flowing nowhere
          --  SPARK models, and its old path is freed -- so a caller that
          --  finalizes a Store and never reads it back needs no "set but not
          --  used" suppression.
          Depends => (Sqlite_Vec_Spark.DBMS =>+ null, S => null, null => S);
   --  Close the store's connection, releasing all owned resources. Idempotent;
   --  leaves S reclaimed.
   --  @param S The store to close; left reclaimed.

   type Op_Status is (Success, Db_Error);
   --  Generic outcome for the row-touching operations below.
   --  @enum Success The operation completed.
   --  @enum Db_Error A SQLite error surfaced from the primitives layer
   --    (prepare/step/commit failure).

   ----------------------
   -- List parameters  --
   ----------------------

   type Name (Len : Natural) is record
      Value : String (1 .. Len);   --  The name text.
   end record;
   --  A single variable-length name (project name or session id), indefinite so
   --  a list of them can live in a SPARKlib vector. Project and session names
   --  are UNIQUE, so a filter binds the name straight into `WHERE ... IN (?, ?,
   --  ...)` instead of resolving it to an id first.
   --  @field Len Length of the name text.

   package Name_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Name);
   --  SPARKlib vector instance over Name, for name-filter lists.

   subtype Name_List is Name_Vectors.Vector;
   --  A list of names (project or session-id filter terms).

   Max_Filter_Terms : constant := 1024;
   --  Upper bound on how many terms a dynamically built `IN (...)` clause may
   --  carry. Keeps the placeholder string (2*N - 1 characters) well clear of
   --  Integer'Last, and sits far above any real filter. A longer filter is
   --  refused, not truncated.

   Max_Header : constant := 400;
   --  Longest Header, in characters, that save takes without warning. A budget
   --  reported back to the caller, not a cut: an over-budget Header is stored
   --  whole, since the alternative is losing text no one else holds.

   Max_Search_Limit : constant := 1000;
   --  Ceiling on a search's requested result count. The KNN over-fetch factor
   --  is applied to the clamped value, so this also bounds the candidate scan.
   --  A larger request is clamped, not rejected.

   ------------------
   -- Record types --
   ------------------

   type Summary
     (Project_Len  : Natural;   --  Length of Project.
      Session_Len  : Natural;   --  Length of Session.
      Created_Len  : Natural;   --  Length of Created_At.
      Header_Len   : Natural;   --  Length of Header.
      Body_Len     : Natural;   --  Length of Content.
      Kind_Len     : Natural) is   --  Length of Kind.
      record
         Id          : Row_Id;    --  The summary's rowid.
         Has_Session : Boolean;   --  session_id IS NOT NULL.
         Project     : String (1 .. Project_Len);    --  Project name.
         Session     : String (1 .. Session_Len);    --  Session id ("" if none).
         Created_At  : String (1 .. Created_Len);    --  ISO-8601 creation time.
         Header      : String (1 .. Header_Len);     --  The Header line.
         Content     : String (1 .. Body_Len);       --  The summary body.
         Kind        : String (1 .. Kind_Len);        --  Header kind.
      end record;
   --  A full summary row, as returned by Fetch_Summary. Indefinite: each
   --  variable-length text field carries its own Len discriminant.

   type Summary_Ptr is access Summary;
   --  Ownership handle for a single-row Summary read: null == no such row.

   procedure Free is new Ada.Unchecked_Deallocation (Summary, Summary_Ptr);
   --  Reclaim a Summary_Ptr returned by Fetch_Summary.

   type Header_Entry
     (Project_Len : Natural;   --  Length of Project.
      Session_Len : Natural;   --  Length of Session.
      Created_Len : Natural;   --  Length of Created_At.
      Header_Len  : Natural;   --  Length of Header.
      Kind_Len    : Natural) is   --  Length of Kind.
      record
         Summary_Id  : Row_Id;    --  The summary's rowid.
         Has_Session : Boolean;   --  session_id IS NOT NULL.
         Project     : String (1 .. Project_Len);     --  Project name.
         Session     : String (1 .. Session_Len);     --  Session id ("" if none).
         Created_At  : String (1 .. Created_Len);     --  ISO-8601 creation time.
         Header      : String (1 .. Header_Len);      --  The Header line.
         Kind        : String (1 .. Kind_Len);        --  Header kind.
      end record;
   --  One Header, the unit Recent_Headers returns: a summaries row without its
   --  body, which is what fetch_summary is for.

   package Header_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Header_Entry);
   --  SPARKlib vector instance over Header_Entry.

   subtype Header_List is Header_Vectors.Vector;
   --  A list of Headers, as returned by Recent_Headers.

   type Project_Info
     (Name_Len   : Natural;   --  Length of Name.
      Latest_Len : Natural) is   --  Length of Latest_At.
      record
         Header_Count : Row_Id;   --  Raw COUNT of Headers (non-negative).
         Has_Latest  : Boolean;   --  Whether Latest_At is present (non-null).
         Name        : String (1 .. Name_Len);      --  Project name.
         Latest_At   : String (1 .. Latest_Len);    --  Newest-Header time ("" if none).
      end record;
   --  One row of List_Projects: a project with its Header count and the
   --  timestamp of its newest Header. Latest_At is nullable -- a project may
   --  have no Headers -- carried as Has_Latest plus a 0-length string.

   package Project_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Project_Info);
   --  SPARKlib vector instance over Project_Info.

   subtype Project_Info_List is Project_Vectors.Vector;
   --  A list of project rows, as returned by List_Projects.

   type Surface_Health
     (Label_Len    : Natural;   --  Length of Label.
      Uuid_Len     : Natural;   --  Length of Uuid.
      Seen_Len     : Natural;   --  Length of Last_Seen.
      Version_Len  : Natural;   --  Length of Hook_Version.
      Host_Len     : Natural;   --  Length of Host.
      Install_Len  : Natural;   --  Length of Install_Host.
      Saved_Len    : Natural;   --  Length of Last_Saved.
      Uploaded_Len : Natural) is   --  Length of Last_Uploaded.
      record
         Attributed    : Boolean;   --  Whether the sessions counted named a surface.
         Sessions      : Row_Id;    --  Distinct sessions examined.
         Missing       : Row_Id;    --  Of those, the ones with no transcript.
         Label         : String (1 .. Label_Len);   --  Surface label ("" when unattributed).
         Uuid          : String (1 .. Uuid_Len);    --  Surface id ("" when unattributed).
         Last_Seen     : String (1 .. Seen_Len);    --  Newest check-in ("" if never).
         Hook_Version  : String (1 .. Version_Len);   --  Reported hook release ("" if none).
         Host          : String (1 .. Host_Len);      --  Host name as of that check-in.
         Install_Host  : String (1 .. Install_Len);   --  Host name when the identity was minted.
         Last_Saved    : String (1 .. Saved_Len);     --  Newest summary written ("" if none).
         Last_Uploaded : String (1 .. Uploaded_Len);  --  Newest transcript written ("" if none).
      end record;
   --  One surface as the corpus has it: what it last reported about itself, and
   --  how many of its recent sessions saved a summary that no transcript
   --  followed. Sessions written with no surface at all are counted together as
   --  one group, which comes back with Attributed False and every text empty.
   --  An empty Hook_Version is a surface that has not checked in since memcp
   --  began recording one, which reads the same as hooks too old to report it.

   package Surface_Health_Vectors is new
     SPARK.Containers.Formal.Unbounded_Vectors
       (Index_Type => Positive, Element_Type => Surface_Health);
   --  SPARKlib vector instance over Surface_Health.

   subtype Surface_Health_List is Surface_Health_Vectors.Vector;
   --  A list of surfaces, as returned by Fleet_Health and Degraded_Surfaces.

   Health_Window : constant := 20;
   --  How many of a surface's most recent summary-bearing sessions Fleet_Health
   --  weighs. Bounds the lookback, so a surface that has been retired stops
   --  being reported once its last sessions age out.

   Health_Threshold : constant := 3;
   --  How many sessions in that window must lack a transcript before the
   --  surface is reported. Absorbs sessions that are still open, whose
   --  transcripts are not late but unwritten.

   type Chunk
     (Project_Len : Natural;   --  Length of Project.
      Body_Len    : Natural;   --  Length of Content.
      Created_Len : Natural) is   --  Length of Created_At.
      record
         Id             : Row_Id;   --  chunks.id
         Session_Row_Id : Row_Id;   --  Owning sessions-row id.
         Ordinal        : Row_Id;   --  0-based turn index within the session.
         Project        : String (1 .. Project_Len);    --  Project name.
         Content        : String (1 .. Body_Len);       --  chunks.body
         Created_At     : String (1 .. Created_Len);    --  ISO-8601 turn time.
      end record;
   --  One transcript turn, the unit Fetch_Turns returns.

   package Chunk_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Chunk);
   --  SPARKlib vector instance over Chunk.

   subtype Chunk_List is Chunk_Vectors.Vector;
   --  A list of transcript turns, as returned by Fetch_Turns.

   type Summary_Hit
     (Project_Len  : Natural;   --  Length of Project.
      Session_Len  : Natural;   --  Length of Session.
      Created_Len  : Natural;   --  Length of Created_At.
      Header_Len   : Natural;   --  Length of Header.
      Body_Len     : Natural;   --  Length of Content.
      Kind_Len     : Natural) is   --  Length of Kind.
      record
         Id          : Row_Id;    --  The summary's rowid.
         Has_Session : Boolean;   --  session_id IS NOT NULL.
         Project     : String (1 .. Project_Len);     --  Project name.
         Session     : String (1 .. Session_Len);     --  Session id ("" if none).
         Created_At  : String (1 .. Created_Len);     --  ISO-8601 creation time.
         Header      : String (1 .. Header_Len);      --  The Header line.
         Content     : String (1 .. Body_Len);        --  The summary body.
         Kind        : String (1 .. Kind_Len);         --  Header kind.
         Distance    : Interfaces.IEEE_Float_64;      --  vec0 KNN L2 distance.
      end record;
   --  A summary search hit: a Summary's fields, flattened, plus the vec0 KNN L2
   --  distance. Smaller distance == closer; hits come back in ascending-distance
   --  order.

   package Summary_Hit_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Summary_Hit);
   --  SPARKlib vector instance over Summary_Hit.

   subtype Summary_Hit_List is Summary_Hit_Vectors.Vector;
   --  A list of summary search hits, as returned by Search_Summaries.

   type Chunk_Hit
     (Project_Len : Natural;   --  Length of Project.
      Body_Len    : Natural;   --  Length of Content.
      Created_Len : Natural;   --  Length of Created_At.
      Session_Len : Natural) is   --  Length of Session.
      record
         Id             : Row_Id;   --  chunks.id
         Session_Row_Id : Row_Id;   --  Owning sessions-row id.
         Ordinal        : Row_Id;   --  0-based turn index within the session.
         Project        : String (1 .. Project_Len);    --  Project name.
         Content        : String (1 .. Body_Len);       --  chunks.body
         Created_At     : String (1 .. Created_Len);    --  ISO-8601 turn time.
         Session        : String (1 .. Session_Len);    --  Owning session id.
         Distance       : Interfaces.IEEE_Float_64;     --  vec0 KNN L2 distance.
      end record;
   --  A chunk search hit: a Chunk's fields, flattened, plus its owning session
   --  id (sessions.session_id is NOT NULL) and the KNN distance.

   package Chunk_Hit_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Chunk_Hit);
   --  SPARKlib vector instance over Chunk_Hit.

   subtype Chunk_Hit_List is Chunk_Hit_Vectors.Vector;
   --  A list of chunk search hits, as returned by Search_Chunks.

   --------------------
   -- Session inputs --
   --------------------

   type Chunk_Input (Body_Len : Natural) is record
      Content   : String (1 .. Body_Len);          --  Verbatim turn body.
      Embedding : Candle_Spark.Embedding;    --  Its precomputed [384] vector.
   end record;
   --  One turn to be stored: its verbatim body plus its precomputed [384]
   --  embedding. Bundling the two makes a chunks/embeddings length mismatch
   --  structurally impossible -- every body carries exactly one vector.
   --  @field Body_Len Length of Content.

   package Chunk_Input_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Chunk_Input);
   --  SPARKlib vector instance over Chunk_Input.

   subtype Chunk_Input_List is Chunk_Input_Vectors.Vector;
   --  A list of turns to store, as passed to Save_Session / Reindex_Session.

   ---------------
   -- Mutations --
   ---------------

   type Save_Result is record
      Summary_Id      : Row_Id;   --  Rowid of the saved summary.
      Already_Existed : Boolean;  --  An identical row already existed (no-op retry).
      Replaced        : Boolean;  --  An existing session-scoped row was replaced.
   end record;
   --  Save's outcome: the rowid plus the dedup and replace flags.

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
     with Pre => Is_Open (S)
                 and then Project'Length > 0
                 and then Project'Last < Natural'Last
                 and then Summary_Body'Last < Integer'Last;
   --  Insert or session-scoped upsert a (Header, Summary) pair, with its
   --  summary embedding. Header_Text is stored as authored -- never derived,
   --  never trimmed; Max_Header is a budget the caller is told about, not a
   --  cut applied here.
   --
   --    * Has_Session and a prior row for (project, session): identical
   --      content (same dedup hash) is a no-op (Already_Existed, not Replaced);
   --      new content UPDATEs the row in place and REPLACEs the embedding,
   --      preserving the id (Already_Existed and Replaced), also promoting an
   --      autorecap row to kind='authored'.
   --    * otherwise content-dedup on (project, Header, Summary): identical
   --      returns the existing id (Already_Existed); else a fresh INSERT.
   --
   --  Created_At overrides the "now" timestamp when Has_Created.
   --  @param S The open store to write to.
   --  @param Project The project name.
   --  @param Header_Text The Header line, stored as authored.
   --  @param Summary_Body The summary body text.
   --  @param Embedding The summary's [384] embedding.
   --  @param Has_Session Whether Session_Id is present (session-scoped upsert).
   --  @param Session_Id The session id (ignored when Has_Session is False).
   --  @param Has_Created Whether Created_At overrides the "now" timestamp.
   --  @param Created_At The ISO-8601 timestamp to use when Has_Created.
   --  @param Surface The writing surface's id; empty leaves the row
   --    unattributed.
   --  @param Surface_Label The writing surface's human-readable name.
   --  @param Result The rowids and dedup/replace flags of the save.
   --  @param Status Success, or Db_Error on a SQLite failure.

   type Session_Save_Result is record
      Session_Row_Id  : Row_Id;    --  The sessions-row id.
      Chunk_Count     : Natural;   --  How many chunks are stored for it.
      Already_Existed : Boolean;   --  The (project, session_id) row already existed.
      Raw_Path_Set    : Boolean;   --  The raw transcript reached disk (raw_path set).
   end record;
   --  Save_Session's outcome: the sessions-row id, the stored chunk count, and
   --  the idempotency and transcript-write flags. Chunks are tallied, not
   --  enumerated -- no chunk ids come back.

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
     with Pre => Is_Open (S)
                 and then Project'Length > 0
                 and then Project'Last < Natural'Last
                 and then Session_Id'Last < Natural'Last;
   --  Insert a session row + its chunks (each with its embedding), and write
   --  the raw transcript to <db_parent>/sessions/<Project>/<Session_Id>.jsonl:
   --
   --    * Idempotent on (Project, Session_Id): if a row already exists, its id
   --      and current chunk count come back with Already_Existed => True and
   --      nothing is re-inserted or rewritten.
   --    * The transcript write is best-effort: on any I/O failure raw_path stays
   --      NULL and the chunks still land -- Raw_Path_Set reports which happened.
   --      A ":memory:" store never writes, having no on-disk parent to anchor to.
   --    * Chunk ordinals are the 0-based position within Chunks. Created_At
   --      overrides "now" when Has_Created.
   --
   --  On Db_Error the transaction is rolled back and Result is the zero value.
   --  @param S The open store to write to.
   --  @param Project The project name.
   --  @param Session_Id The session id.
   --  @param Transcript The raw transcript to persist (best-effort).
   --  @param Chunks The turns to store, each with its embedding.
   --  @param Has_Created Whether Created_At overrides the "now" timestamp.
   --  @param Created_At The ISO-8601 timestamp to use when Has_Created.
   --  @param Surface The uploading surface's id; empty leaves the row
   --    unattributed.
   --  @param Surface_Label The uploading surface's human-readable name.
   --  @param Result The session id, chunk count, and idempotency/write flags.
   --  @param Status Success, or Db_Error on a SQLite failure.

   type Autorecap_Result is record
      Summary_Id : Row_Id;    --  Rowid of the written summary.
      Written    : Boolean;   --  A new autorecap row was written.
   end record;
   --  Save_Autorecap's outcome: the rowid plus the write flag.

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
     with Pre => Is_Open (S)
                 and then Project'Length > 0
                 and then Project'Last < Natural'Last
                 and then Recap_Text'Last < Integer'Last;
   --  Write a kind='autorecap' Header + Summary for a session that has none --
   --  the SessionEnd fallback when the model never called save. Short-circuits
   --  (Written => False, no write) if ANY Header already exists for (Project,
   --  Session_Id), so an authored Header is never overwritten. Recap_Text goes
   --  in whole as both, so Header text == Summary text holds exactly and a
   --  reader can skip the fetch on that promise.
   --  @param S The open store to write to.
   --  @param Project The project name.
   --  @param Session_Id The session id.
   --  @param Recap_Text The recap text (used as both Header and Summary text).
   --  @param Embedding The recap's [384] embedding.
   --  @param Has_Created Whether Created_At overrides the "now" timestamp.
   --  @param Created_At The ISO-8601 timestamp to use when Has_Created.
   --  @param Surface The writing surface's id; empty leaves the row
   --    unattributed.
   --  @param Surface_Label The writing surface's human-readable name.
   --  @param Result The rowid written and whether a write happened.
   --  @param Status Success, or Db_Error on a SQLite failure.

   procedure Reindex_Session
     (S          : Store;
      Project    : String;
      Session_Id : String;
      Chunks     : Chunk_Input_List;
      Found      : out Boolean;
      Old_Count  : out Natural;
      New_Count  : out Natural;
      Status     : out Op_Status)
     with Pre => Is_Open (S)
                 and then Project'Length > 0
                 and then Project'Last < Natural'Last;
   --  Replace a stored session's chunks (+ embeddings) in place: delete the
   --  session's existing chunks and their chunk_vec rows, then insert Chunks
   --  with fresh 0-based ordinals. The session row and the raw transcript are
   --  left as-is, and the new chunks inherit the session's original created_at
   --  so date-window filters keep working. Found => False (with Success) when no
   --  session row exists for (Project, Session_Id); otherwise Old_Count /
   --  New_Count report the swap.
   --  @param S The open store to modify.
   --  @param Project The project name.
   --  @param Session_Id The session id.
   --  @param Chunks The replacement turns, each with its embedding.
   --  @param Found True iff a session row existed for (Project, Session_Id).
   --  @param Old_Count Number of chunks present before the swap.
   --  @param New_Count Number of chunks present after the swap.
   --  @param Status Success, or Db_Error on a SQLite failure.

   procedure Forget_Summary
     (S       : Store;
      Id      : Row_Id;
      Deleted : out Boolean;
      Status  : out Op_Status)
     with Pre => Is_Open (S);
   --  Delete a summary and its embedding row.
   --  @param S The open store to modify.
   --  @param Id The rowid of the summary to delete.
   --  @param Deleted True iff a matching summary existed and was deleted.
   --  @param Status Success, or Db_Error on a SQLite failure.

   ------------
   -- Reads  --
   ------------

   procedure Fetch_Summary
     (S      : Store;
      Id     : Row_Id;
      Result : out Summary_Ptr;
      Status : out Op_Status)
     with Pre => Is_Open (S);
   --  Fetch one full Summary by id; Result is null (and Status Success) when
   --  the id is unknown. Caller Frees a non-null Result.
   --  @param S The open store to read.
   --  @param Id The rowid of the summary to fetch.
   --  @param Result The fetched Summary, or null when the id is unknown.
   --  @param Status Success, or Db_Error on a SQLite failure.

   procedure Recent_Headers
     (S        : Store;
      Projects : Name_List;
      N        : Natural;
      Result   : out Header_List;
      Status   : out Op_Status)
     with Pre => Is_Open (S);
   --  The N most recent Headers across the given Projects, newest first
   --  (created_at DESC). An empty Projects list, or one longer than
   --  Max_Filter_Terms, yields an empty Result with Success rather than an
   --  unbounded IN clause. Result is always initialized; on Db_Error it is
   --  empty.
   --  @param S The open store to read.
   --  @param Projects The project-name filter (empty yields an empty Result).
   --  @param N The maximum number of Headers to return.
   --  @param Result The matching Headers, newest first.
   --  @param Status Success, or Db_Error on a SQLite failure.

   procedure List_Projects
     (S      : Store;
      Result : out Project_Info_List;
      Status : out Op_Status)
     with Pre => Is_Open (S);
   --  Every known project with its Header count and newest-Header timestamp,
   --  ordered newest-activity first, empty projects last. Result is empty on
   --  Db_Error.
   --  @param S The open store to read.
   --  @param Result One row per known project.
   --  @param Status Success, or Db_Error on a SQLite failure.

   procedure Fleet_Health
     (S      : Store;
      Window : Positive;
      Result : out Surface_Health_List;
      Status : out Op_Status)
     with Pre => Is_Open (S);
   --  Every known surface, plus the group of sessions that named none, each
   --  with what it last reported and how many of its last Window
   --  summary-bearing sessions have no transcript. Counted per distinct
   --  session, so a session that saves repeatedly weighs once. Fleet-wide
   --  rather than project-scoped: a surface whose hooks have stopped cannot
   --  report on itself, so the answer must be the same from wherever it is
   --  asked. Worst gap first. Result is empty on Db_Error.
   --  @param S The open store to read.
   --  @param Window How many of a surface's recent sessions to weigh.
   --  @param Result One row per known surface, worst gap first.
   --  @param Status Success, or Db_Error on a SQLite failure.

   procedure Degraded_Surfaces
     (S      : Store;
      Window : Positive;
      Least  : Positive;
      Result : out Surface_Health_List;
      Status : out Op_Status)
     with Pre => Is_Open (S);
   --  Fleet_Health narrowed to the surfaces with at least Least sessions
   --  missing a transcript, which is a stopped SessionEnd as the corpus sees
   --  it. One query behind both, so what is reported unasked and what a
   --  diagnosis reports cannot disagree. Empty is the healthy answer.
   --  @param S The open store to read.
   --  @param Window How many of a surface's recent sessions to weigh.
   --  @param Least How many of those must lack a transcript to be reported.
   --  @param Result One row per degraded surface, worst first.
   --  @param Status Success, or Db_Error on a SQLite failure.

   procedure Touch_Surface
     (S            : Store;
      Uuid         : String;
      Label        : String;
      Hook_Version : String;
      Host         : String;
      Install_Host : String;
      Status       : out Op_Status)
     with Pre => Is_Open (S);
   --  Record surface Uuid as in use now, inserting it when new and refreshing
   --  what it reports about itself when not. An empty Uuid does nothing and
   --  succeeds; any other field left empty keeps whatever is already on
   --  record, so a caller that knows less than the last one erases nothing.
   --  The only path that records a surface without it writing a row of its
   --  own, which is what separates a surface that has stopped working from one
   --  that has merely stopped saving.
   --  @param S The open store to write.
   --  @param Uuid The surface's UUID; empty does nothing.
   --  @param Label The surface's label, refreshed on every call.
   --  @param Hook_Version The hook release the surface reports running.
   --  @param Host The surface's host name now.
   --  @param Install_Host The host name when the surface's identity was minted.
   --  @param Status Success, or Db_Error on a SQLite failure.

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
     with Pre => Is_Open (S)
                 and then (if Has_Tail then not (Has_Start or else Has_End));
   --  A session's turns by ordinal position -- the positional counterpart to a
   --  chunk search, no vectors involved. Three optional filters, each a Has_*
   --  flag plus its value:
   --    * Has_Project scopes by project name (a session id may repeat across
   --      projects); omit to match on session id alone.
   --    * Has_Start / Has_End give a half-open [Start_Ord, End_Ord) ordinal
   --      window; either may be omitted.
   --    * Has_Tail requests the last Tail turns instead (Tail > 0), still
   --      returned in ascending ordinal order.
   --  Tail is mutually exclusive with Start/End, per the precondition. An
   --  unknown session yields an empty Result with Success.
   --  @param S The open store to read.
   --  @param Session_Id The session id whose turns are requested.
   --  @param Has_Project Whether the Project filter applies.
   --  @param Project The project name (ignored when Has_Project is False).
   --  @param Has_Start Whether Start_Ord bounds the window below.
   --  @param Start_Ord Inclusive lower ordinal bound (when Has_Start).
   --  @param Has_End Whether End_Ord bounds the window above.
   --  @param End_Ord Exclusive upper ordinal bound (when Has_End).
   --  @param Has_Tail Whether to return the last Tail turns instead.
   --  @param Tail Number of trailing turns to return (when Has_Tail).
   --  @param Result The matching turns, in ascending ordinal order.
   --  @param Status Success, or Db_Error on a SQLite failure.

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
     with Pre => Is_Open (S);
   --  KNN search over summary embeddings: fetch the nearest candidates from
   --  summary_vec (over-fetching x5 when filters are present, since vec0 applies
   --  its LIMIT before the metadata filters), then keep the first Limit that
   --  pass the filters, in ascending-distance order. Filtering is done in Ada: a
   --  summary passes when its project is in Projects (empty Projects == no
   --  project filter), and its created_at is within the optional [Since, Until]
   --  window (ISO-8601 strings compare lexically, exactly as SQLite would). A
   --  Projects filter longer than Max_Filter_Terms, or Limit = 0, yields an
   --  empty Result with Success.
   --  @param S The open store to read.
   --  @param Query_Emb The query [384] embedding.
   --  @param Projects The project-name filter (empty == no project filter).
   --  @param Limit The maximum number of hits to return.
   --  @param Has_Since Whether Since bounds the created_at window below.
   --  @param Since Inclusive lower ISO-8601 bound (when Has_Since).
   --  @param Has_Until Whether Until_At bounds the created_at window above.
   --  @param Until_At Inclusive upper ISO-8601 bound (when Has_Until).
   --  @param Result The matching hits, in ascending-distance order.
   --  @param Status Success, or Db_Error on a SQLite failure.

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
     with Pre => Is_Open (S);
   --  KNN search over chunk embeddings: as Search_Summaries, with an extra
   --  Session_Ids filter (a chunk passes when its session is in Session_Ids;
   --  empty == no session filter).
   --  @param S The open store to read.
   --  @param Query_Emb The query [384] embedding.
   --  @param Projects The project-name filter (empty == no project filter).
   --  @param Session_Ids The session-id filter (empty == no session filter).
   --  @param Limit The maximum number of hits to return.
   --  @param Has_Since Whether Since bounds the created_at window below.
   --  @param Since Inclusive lower ISO-8601 bound (when Has_Since).
   --  @param Has_Until Whether Until_At bounds the created_at window above.
   --  @param Until_At Inclusive upper ISO-8601 bound (when Has_Until).
   --  @param Result The matching hits, in ascending-distance order.
   --  @param Status Success, or Db_Error on a SQLite failure.

private

   pragma Annotate (GNATprove, Hide_Info, "Private_Part");
   --  Required for the Ownership annotation on Store, and keeps the body's query
   --  logic in SPARK.

   type Path_Access is access String;
   --  Owning handle for the opened DB path, remembered at Open so a session
   --  save can place raw transcripts under <db_parent>/sessions/... null before
   --  Open and after Close, which frees it.

   type Store is limited record
      DB      : Sqlite_Vec_Spark.Database;   --  The owned SQLite connection.
      DB_Path : Path_Access := null;         --  Opened DB path (null when closed).
   end record;
   --  Full view of the storage handle: the SQLite connection plus the
   --  remembered DB path.

   function Is_Open (S : Store) return Boolean is
     (Sqlite_Vec_Spark.Is_Open (S.DB));
   --  Whether the store's connection is currently open.
   --  @param S The store to test.
   --  @return True iff S holds an open SQLite connection.

   function Is_Reclaimed (S : Store) return Boolean is
     (Sqlite_Vec_Spark.Is_Reclaimed (S.DB) and then S.DB_Path = null);
   --  Completion of the reclamation predicate: reclaimed exactly when the owned
   --  connection is reclaimed and the remembered path has been released.
   --  @param S The store to test.
   --  @return True iff S owns neither a connection nor a path allocation.

end Memcp.Store;
