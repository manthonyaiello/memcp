--  memcp's storage layer: store.py ported onto the sqlite_vec_spark
--  primitives. One SQLite file, one vec0 table per embedded record type. This
--  is where store.py's schema, record types, and the queries behind the 9
--  tools live -- sqlite_vec_spark stays the thin, memcp-agnostic C bind.
--
--  SPARK_Mode On: the query logic is proven (AoRTE, ownership/leak-freedom on
--  every path). The genuinely non-SPARK bits -- the SHA-256 dedup hash and the
--  wall-clock ISO timestamp -- are isolated in small SPARK_Mode => Off helpers
--  in the body, mirroring how the binding crates quarantine their foreign
--  bodies.
--
--  Design (see README "Design decisions" + the sparklib memory):
--
--    * List-valued queries (recent/search/fetch_chunks/fetch_turns/
--      list_projects) return a SPARKlib Unbounded_Vector of an indefinite
--      record. The formal vector's `Element_Type (<>)` formal takes the
--      multi-`Len`-discriminant String records below directly -- no ownership
--      list, no JSON-in-Store.
--    * Single-row queries (fetch_summary) return an ownership access
--      (Summary_Ptr, null = not found), the Result_Ptr/Text_Ptr idiom already
--      used across the tree, because a value-returning SPARK function may not
--      have the side effect of stepping a cursor.
--    * Nullable columns (session_id) are carried as a `Has_Session : Boolean`
--      field plus a 0-length string when absent -- SQL NULL is distinguished
--      from "" via sqlite_vec_spark's Column_Is_Null.

with Ada.Unchecked_Deallocation;
with Interfaces;

with SPARK.Containers.Formal.Unbounded_Vectors;

with Sqlite_Vec_Spark;
with Candle_Spark;

package Memcp.Store with SPARK_Mode => On is

   Embedding_Dim  : constant := 384;
   --  Vector dimension. Mirrors store.py's module constant; must match
   --  Candle_Spark's Dimension and sqlite-vec's packed float[384].
   Schema_Version : constant String := "1";
   --  Schema version stamped into the meta row. Mirrors store.py.
   Embedding_Model : constant String :=
     "sentence-transformers/all-MiniLM-L6-v2";
   --  Embedding model id stamped into the meta row. Mirrors store.py.

   Kind_Diary    : constant String := "diary";
   --  Header kind for a real, model-authored diary summary (store.py KIND_*).
   Kind_Autorecap : constant String := "autorecap";
   --  Header kind for the SessionEnd fallback recap (store.py KIND_*).

   subtype Row_Id is Interfaces.Integer_64;
   --  A SQLite rowid: signed 64-bit.

   type Store is limited private
     with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
          Default_Initial_Condition =>
            not Is_Open (Store) and then Is_Reclaimed (Store);
   --  The storage handle: owns one SQLite connection (with vec0 registered,
   --  foreign_keys ON, WAL). Limited because Sqlite_Vec_Spark.Database is
   --  (it owns a raw C pointer; a copy would double-close).
   --
   --  Needs_Reclamation: a Store owns its Sqlite_Vec_Spark.Database connection
   --  (and the remembered DB path). Unlike Database/Statement/Embedder, whose
   --  resource is a bare C address needing the access-token device, a Store's
   --  ownership is carried by its own owning components -- so its Is_Reclaimed
   --  is just "the connection is reclaimed and the path is released". Promoting
   --  the partial view to an ownership type is what lets a holder of a Store
   --  (Memcp.Resources) see the reclamation obligation and have GNATprove check
   --  that a Store is Closed before it is dropped or re-Opened.

   function Is_Open (S : Store) return Boolean;
   --  Whether the store's connection is currently open.
   --  @param S The store to test.
   --  @return True iff S holds an open SQLite connection.

   function Is_Reclaimed (S : Store) return Boolean
     with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
   --  Reclamation predicate for the Needs_Reclamation annotation above. A Store
   --  is reclaimed once its connection is reclaimed and its remembered path is
   --  released -- the state GNATprove requires before the Store is dropped.
   --  Ghost: it exists only for proof, never at run time.
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
   --    this build (store.py's _init_meta RuntimeError); refused, not corrupted.

   --  Open (or create) the store at DB_Path: open the connection, apply the
   --  full schema + the two vec0 virtual tables, then assert the meta row.
   procedure Open
     (S : out Store; DB_Path : String; Result : out Open_Status)
     with Pre  => DB_Path'Length > 0 and then DB_Path'Last < Natural'Last,
          Post => (Is_Open (S) = (Result = Opened))
                  and then (Is_Reclaimed (S) = (Result /= Opened));
   --  Is_Open (S) iff Result = Opened; on any failure the connection is closed
   --  (and S reclaimed). S is an out parameter, so any prior value is dropped;
   --  callers therefore establish Is_Reclaimed (S) first (a fresh Store is
   --  reclaimed by its Default_Initial_Condition).
   --  (Migrations for pre-existing older DBs -- store.py _migrate -- are out
   --  of scope for now; fresh DBs need none.)
   --  @param S The store to open (initialized on return).
   --  @param DB_Path Filesystem path to the SQLite DB (or ":memory:").
   --  @param Result The outcome of the open attempt.

   procedure Close (S : in out Store)
     with Post    => not Is_Open (S) and then Is_Reclaimed (S),
          Global  => (In_Out => Sqlite_Vec_Spark.DBMS),
          Depends => (Sqlite_Vec_Spark.DBMS =>+ null, S => null, null => S);
   --  Close the store's connection, releasing all owned resources. Idempotent;
   --  leaves S reclaimed. Depends spells out the finalizer data flow (as for
   --  Sqlite_Vec_Spark.Close): S's new value is a constant, its old connection
   --  reaches C only as an address (flowing nowhere in SPARK) and its old path
   --  is freed, while DBMS is updated in place -- so a caller that finalizes a
   --  Store and never reads it back needs no "set but not used" suppression.
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
   --  A single variable-length name (project name or session id) carried as an
   --  indefinite record so a list of them can live in a SPARKlib vector. The
   --  read queries bind these straight into `WHERE ... IN (?, ?, ...)`; project
   --  and session names are UNIQUE, so binding the name is equivalent to
   --  store.py's _project_ids name->id resolution but without the extra lookup.
   --  @field Len Length of the name text.

   package Name_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Name);
   --  SPARKlib vector instance over Name, for name-filter lists.
   subtype Name_List is Name_Vectors.Vector;
   --  A list of names (project or session-id filter terms).

   Max_Filter_Terms : constant := 1024;
   --  Upper bound on how many terms a dynamically built `IN (...)` clause may
   --  carry. Keeps the placeholder-string length (2*N - 1) well clear of
   --  Integer'Last so its construction is overflow-free; far above any real
   --  projects/session_ids filter. A longer filter is refused, not truncated.

   Max_Search_Limit : constant := 1000;
   --  Ceiling on a search's requested result count. The KNN over-fetch factor
   --  (x5 when metadata filters are present) is applied to the clamped value,
   --  so this bounds the candidate scan and keeps it overflow-free. Far above
   --  any sensible limit; a larger request is clamped, not rejected.

   ------------------
   -- Record types --
   ------------------

   type Summary
     (Project_Len  : Natural;   --  Length of Project.
      Session_Len  : Natural;   --  Length of Session.
      Created_Len  : Natural;   --  Length of Created_At.
      Headline_Len : Natural;   --  Length of Headline.
      Body_Len     : Natural;   --  Length of Content.
      Kind_Len     : Natural) is   --  Length of Kind.
      record
         Id          : Row_Id;    --  The summary's rowid.
         Has_Session : Boolean;   --  session_id IS NOT NULL.
         Project     : String (1 .. Project_Len);    --  Project name.
         Session     : String (1 .. Session_Len);    --  Session id ("" if none).
         Created_At  : String (1 .. Created_Len);    --  ISO-8601 creation time.
         Headline    : String (1 .. Headline_Len);   --  The headline line.
         Content     : String (1 .. Body_Len);       --  The summary body.
         Kind        : String (1 .. Kind_Len);        --  Header kind (diary/autorecap).
      end record;
   --  A full Summary (fetch_summary / search hit). Indefinite: each
   --  variable-length text field carries its own Len discriminant.

   type Summary_Ptr is access Summary;
   --  Ownership handle for a single-row Summary read: null == no such row.

   procedure Free is new Ada.Unchecked_Deallocation (Summary, Summary_Ptr);
   --  Reclaim a Summary_Ptr returned by Fetch_Summary.

   type Diary_Entry
     (Project_Len  : Natural;   --  Length of Project.
      Session_Len  : Natural;   --  Length of Session.
      Created_Len  : Natural;   --  Length of Created_At.
      Body_Len     : Natural;   --  Length of Content.
      Headline_Len : Natural;   --  Length of Headline.
      Kind_Len     : Natural) is   --  Length of Kind.
      record
         Id          : Row_Id;    --  diary.id
         Summary_Id  : Row_Id;    --  diary.summary_id
         Has_Session : Boolean;   --  summaries.session_id IS NOT NULL
         Project     : String (1 .. Project_Len);     --  Project name.
         Session     : String (1 .. Session_Len);     --  Session id ("" if none).
         Created_At  : String (1 .. Created_Len);     --  ISO-8601 diary time.
         Content     : String (1 .. Body_Len);        --  diary.body
         Headline    : String (1 .. Headline_Len);    --  The summary's headline.
         Kind        : String (1 .. Kind_Len);        --  Header kind (diary/autorecap).
      end record;
   --  A diary Header (recent()'s unit). store.py DiaryEntry: the diary row's
   --  own id/body/created_at joined to its summary's session/headline/kind.
   --  Indefinite, like Summary; a list of these is a Diary_Vectors.Vector.

   package Diary_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Diary_Entry);
   --  SPARKlib vector instance over Diary_Entry.
   subtype Diary_Entry_List is Diary_Vectors.Vector;
   --  A list of diary Headers, as returned by Recent_Diary.

   type Project_Info
     (Name_Len   : Natural;   --  Length of Name.
      Latest_Len : Natural) is   --  Length of Latest_At.
      record
         Diary_Count : Row_Id;    --  Raw COUNT of diary entries (non-negative).
         Has_Latest  : Boolean;   --  Whether Latest_At is present (non-null).
         Name        : String (1 .. Name_Len);      --  Project name.
         Latest_At   : String (1 .. Latest_Len);    --  Newest-Header time ("" if none).
      end record;
   --  One row of list_projects: a project with its diary count and the
   --  timestamp of its newest Header. store.py ProjectInfo. Latest_At is
   --  nullable (a project with no diary entries), carried as Has_Latest + a
   --  0-length string, like Summary.Session. Diary_Count is the raw COUNT (an
   --  Integer_64 to avoid a range check; it is a non-negative tally).

   package Project_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Project_Info);
   --  SPARKlib vector instance over Project_Info.
   subtype Project_Info_List is Project_Vectors.Vector;
   --  A list of project rows, as returned by List_Projects.

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
   --  One transcript turn (search_chunks / fetch_turns unit). store.py Chunk.
   --  Ordinal is the 0-based turn index within the session (Integer_64, as
   --  above -- no range check, and it is what SQLite hands back).

   package Chunk_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Chunk);
   --  SPARKlib vector instance over Chunk.
   subtype Chunk_List is Chunk_Vectors.Vector;
   --  A list of transcript turns, as returned by Fetch_Turns.

   type Summary_Hit
     (Project_Len  : Natural;   --  Length of Project.
      Session_Len  : Natural;   --  Length of Session.
      Created_Len  : Natural;   --  Length of Created_At.
      Headline_Len : Natural;   --  Length of Headline.
      Body_Len     : Natural;   --  Length of Content.
      Kind_Len     : Natural) is   --  Length of Kind.
      record
         Id          : Row_Id;    --  The summary's rowid.
         Has_Session : Boolean;   --  session_id IS NOT NULL.
         Project     : String (1 .. Project_Len);     --  Project name.
         Session     : String (1 .. Session_Len);     --  Session id ("" if none).
         Created_At  : String (1 .. Created_Len);     --  ISO-8601 creation time.
         Headline    : String (1 .. Headline_Len);    --  The headline line.
         Content     : String (1 .. Body_Len);        --  The summary body.
         Kind        : String (1 .. Kind_Len);         --  Header kind (diary/autorecap).
         Distance    : Interfaces.IEEE_Float_64;      --  vec0 KNN L2 distance.
      end record;
   --  A summary search hit: the Summary's fields (flattened, so no nested
   --  indefinite component) plus the vec0 KNN L2 distance. store.py
   --  SummarySearchHit. Smaller distance == closer; hits come back in
   --  ascending-distance order.

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
   --  A chunk search hit: the Chunk's fields (flattened) plus its owning
   --  session id (sessions.session_id is NOT NULL) and the KNN distance.
   --  store.py ChunkSearchHit.

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
   --  embedding. Bundling the two makes store.py's "chunks/embeddings length
   --  mismatch" ValueError structurally impossible -- every body carries
   --  exactly one vector. Embedding is a definite array, so the record stays
   --  indefinite only in Body_Len (no nested indefinite component, per the
   --  design rule above). A list of these is what save_session / reindex store.
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
      Summary_Id     : Row_Id;    --  Rowid of the saved summary.
      Diary_Id       : Row_Id;    --  Rowid of the saved diary line.
      Already_Existed : Boolean;  --  An identical row already existed (no-op retry).
      Replaced        : Boolean;  --  An existing session-scoped row was replaced.
   end record;
   --  save()'s four-value return: the summary + diary rowids, whether an
   --  identical row already existed (no-op retry), and whether an existing
   --  session-scoped row was replaced in place.

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
     with Pre => Is_Open (S)
                 and then Project'Length > 0
                 and then Project'Last < Natural'Last
                 and then Summary_Body'Last < Integer'Last;
   --  Insert or session-scoped upsert a (diary line, summary) pair, with its
   --  summary embedding. store.py Store.save, 1:1:
   --
   --    * Has_Session and a prior row for (project, session): identical
   --      content (same dedup hash) is a no-op (Already_Existed, not Replaced);
   --      new content UPDATEs the summary/diary in place and REPLACEs the
   --      embedding, preserving ids (Already_Existed and Replaced), also
   --      promoting an autorecap row to kind='diary'.
   --    * otherwise content-dedup on (project, diary, summary): identical
   --      returns the existing ids (Already_Existed); else a fresh INSERT.
   --
   --  Created_At overrides the "now" timestamp when Has_Created (the mempalace
   --  importer / conformance replay path). The embedding is a fixed [384]
   --  vector, packed to a float32 blob for summary_vec.
   --  @param S The open store to write to.
   --  @param Project The project name.
   --  @param Diary_Body The diary line text.
   --  @param Summary_Body The summary body text.
   --  @param Embedding The summary's [384] embedding.
   --  @param Has_Session Whether Session_Id is present (session-scoped upsert).
   --  @param Session_Id The session id (ignored when Has_Session is False).
   --  @param Has_Created Whether Created_At overrides the "now" timestamp.
   --  @param Created_At The ISO-8601 timestamp to use when Has_Created.
   --  @param Result The rowids and dedup/replace flags of the save.
   --  @param Status Success, or Db_Error on a SQLite failure.

   type Session_Save_Result is record
      Session_Row_Id  : Row_Id;    --  The sessions-row id.
      Chunk_Count     : Natural;   --  How many chunks are stored for it.
      Already_Existed : Boolean;   --  The (project, session_id) row already existed.
      Raw_Path_Set    : Boolean;   --  The raw transcript reached disk (raw_path set).
   end record;
   --  save_session's return: the sessions-row id, how many chunks are stored
   --  for it, whether the (project, session_id) row already existed (an
   --  idempotent no-op -- no chunks re-inserted, no transcript rewritten), and
   --  whether the raw transcript reached disk (raw_path set). store.py returns
   --  (session_row_id, [chunk_id, ...], already_existed); the server only needs
   --  the count, so we tally rather than hand back every id.

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
     with Pre => Is_Open (S)
                 and then Project'Length > 0
                 and then Project'Last < Natural'Last
                 and then Session_Id'Last < Natural'Last;
   --  Insert a session row + its chunks (each with its embedding), and write
   --  the raw transcript to <db_parent>/sessions/<Project>/<Session_Id>.jsonl.
   --  store.py save_session, 1:1:
   --
   --    * Idempotent on (Project, Session_Id): if a row already exists, its id
   --      and current chunk count come back with Already_Existed => True and
   --      nothing is re-inserted or rewritten.
   --    * The transcript write is best-effort (a new SPARK_Mode => Off region):
   --      on any I/O failure raw_path stays NULL and the chunks still land --
   --      Raw_Path_Set reports whether it succeeded. A ":memory:" store never
   --      writes (there is no on-disk parent to anchor to).
   --    * Chunk ordinals are the 0-based position within Chunks. Created_At
   --      overrides "now" when Has_Created (the replay / importer path).
   --
   --  On Db_Error the transaction is rolled back and Result is the zero value.
   --  @param S The open store to write to.
   --  @param Project The project name.
   --  @param Session_Id The session id.
   --  @param Transcript The raw transcript to persist (best-effort).
   --  @param Chunks The turns to store, each with its embedding.
   --  @param Has_Created Whether Created_At overrides the "now" timestamp.
   --  @param Created_At The ISO-8601 timestamp to use when Has_Created.
   --  @param Result The session id, chunk count, and idempotency/write flags.
   --  @param Status Success, or Db_Error on a SQLite failure.

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
     with Pre => Is_Open (S)
                 and then Project'Length > 0
                 and then Project'Last < Natural'Last
                 and then Recap_Text'Last < Integer'Last;
   --  Write a kind='autorecap' Header + Summary for a session that has none --
   --  the SessionEnd fallback when the model saved no diary. store.py
   --  save_autorecap. Short-circuits (Written => False, no write) if ANY Header
   --  already exists for (Project, Session_Id), so a real save() is never
   --  overwritten. Header text == Summary text == Recap_Text; the headline is
   --  the stripped first 100 chars (no HEADLINE: parsing). On a fresh write
   --  Written => True and Summary_Id / Diary_Id are the new rowids.
   --  @param S The open store to write to.
   --  @param Project The project name.
   --  @param Session_Id The session id.
   --  @param Recap_Text The recap text (used as both Header and Summary text).
   --  @param Embedding The recap's [384] embedding.
   --  @param Has_Created Whether Created_At overrides the "now" timestamp.
   --  @param Created_At The ISO-8601 timestamp to use when Has_Created.
   --  @param Summary_Id On a fresh write, the new summary rowid.
   --  @param Diary_Id On a fresh write, the new diary rowid.
   --  @param Written True iff a new autorecap row was written.
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
   --  Replace a stored session's chunks (+ embeddings) in place. store.py
   --  reindex_session -- re-derives the Details after a chunking-policy change.
   --  Deletes the session's existing chunks and their chunk_vec rows, then
   --  inserts Chunks with fresh 0-based ordinals; the session row and the raw
   --  transcript are left as-is, and the new chunks inherit the session's
   --  original created_at so date-window filters keep working. Found => False
   --  (with Success) when no session row exists for (Project, Session_Id)
   --  (store.py None); otherwise Old_Count / New_Count report the swap.
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
   --  Delete a summary, its diary line (FK cascade), and its embedding row.
   --  store.py forget_summary.
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
   --  the id is unknown. Caller Frees a non-null Result. store.py
   --  fetch_summary.
   --  @param S The open store to read.
   --  @param Id The rowid of the summary to fetch.
   --  @param Result The fetched Summary, or null when the id is unknown.
   --  @param Status Success, or Db_Error on a SQLite failure.

   procedure Recent_Diary
     (S        : Store;
      Projects : Name_List;
      N        : Natural;
      Result   : out Diary_Entry_List;
      Status   : out Op_Status)
     with Pre => Is_Open (S);
   --  The N most recent diary Headers across the given Projects, newest first
   --  (diary.created_at DESC). store.py recent_diary. An empty Projects list,
   --  or one longer than Max_Filter_Terms, yields an empty Result with Success
   --  (store.py returns [] for no projects; we also refuse an over-long filter
   --  rather than build an unbounded IN clause). Result is always initialized;
   --  on Db_Error it is empty.
   --  @param S The open store to read.
   --  @param Projects The project-name filter (empty yields an empty Result).
   --  @param N The maximum number of Headers to return.
   --  @param Result The matching diary Headers, newest first.
   --  @param Status Success, or Db_Error on a SQLite failure.

   procedure List_Projects
     (S      : Store;
      Result : out Project_Info_List;
      Status : out Op_Status)
     with Pre => Is_Open (S);
   --  Every known project with its diary count and newest-Header timestamp,
   --  ordered newest-activity first, empty projects last. store.py
   --  list_projects. Result is empty on Db_Error.
   --  @param S The open store to read.
   --  @param Result One row per known project.
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
   --  A session's turns by ordinal position (store.py fetch_turns) -- the
   --  positional counterpart to a chunk search, no vectors involved. Three
   --  optional filters, each a Has_* flag plus its value:
   --    * Has_Project scopes by project name (a session id may repeat across
   --      projects); omit to match on session id alone.
   --    * Has_Start / Has_End give a half-open [Start_Ord, End_Ord) ordinal
   --      window; either may be omitted.
   --    * Has_Tail requests the last Tail turns instead (Tail > 0), still
   --      returned in ascending ordinal order.
   --  Tail is mutually exclusive with Start/End (enforced by the precondition;
   --  the tools layer rejects the bad combination before calling). An unknown
   --  session yields an empty Result with Success.
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
   --  KNN search over summary embeddings. store.py search_summaries: fetch the
   --  nearest candidates from summary_vec (over-fetching x5 when filters are
   --  present, since vec0 applies its LIMIT before the metadata filters), then
   --  keep the first Limit that pass the filters, in ascending-distance order.
   --  Filtering is done in Ada: a summary passes when its project is in
   --  Projects (empty Projects == no project filter), and its created_at is
   --  within the optional [Since, Until] window (ISO-8601 strings compare
   --  lexically, exactly as SQLite would). A Projects filter longer than
   --  Max_Filter_Terms, or Limit = 0, yields an empty Result with Success.
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
   --  KNN search over chunk embeddings. store.py search_chunks -- as
   --  Search_Summaries, with an extra Session_Ids filter (a chunk passes when
   --  its session is in Session_Ids; empty == no session filter).
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

   --  Hide the representation from clients' proof context: the Ownership
   --  annotation on Store requires its private part to be either SPARK_Mode
   --  (Off) or hidden, and hiding keeps this body's query logic IN SPARK.
   --  Clients (Memcp.Resources) reason about Store abstractly -- through
   --  Is_Open, the Needs_Reclamation obligation, and the operation contracts --
   --  exactly as this crate's clients do for Sqlite_Vec_Spark.Database.
   pragma Annotate (GNATprove, Hide_Info, "Private_Part");

   type Path_Access is access String;
   --  Owning handle for the opened DB path, remembered at Open so save_session
   --  can place raw transcripts under <db_parent>/sessions/... (store.py
   --  derives this from self.db_path.parent). null before Open / after Close;
   --  Close frees it. A pool-specific access type, like the Text_Ptr /
   --  Summary_Ptr the tree already proves leak-free.

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
   --  connection is reclaimed and the remembered path has been released. Both
   --  owning components must be reclaimed before a Store is dropped.

end Memcp.Store;
