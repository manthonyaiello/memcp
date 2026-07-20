--  The composition-root resources the tool layer runs against: one opened
--  Store and one loaded Embedder, bundled in a single owning object. The tool
--  layer (and the -gnata test drivers) reach them ONLY through the total
--  operations below -- SPARK forbids handing out an access to an owned object,
--  so a caller passes the Resources object in and the operation reads the
--  Store/Embedder from it. Every operation is a thin, precondition-free
--  pass-through to the proved units beneath (Memcp_Store, Candle_Spark): it
--  guards the Store's own preconditions internally (Is_Open, non-empty
--  project, ...) and degrades to Db_Error / an empty result rather than
--  requiring the caller to establish them.
--
--  Why an object, not a package singleton: a Store and an Embedder are both
--  owned resources (Needs_Reclamation), and SPARK's leak/ownership analysis
--  tracks reclamation through the flow of a *data object*, not through package
--  state (which every subprogram must conservatively assume the worst about at
--  entry, since SPARK does not do whole-program analysis). Holding them in a
--  Resources object makes the open-once lifecycle explicit and proof-enforced:
--  Open's Pre => Is_Reclaimed (R) licenses the re-(over)write of the owned
--  handles with no pre-reclaim dance and no "statement has no effect"
--  suppression, and Close's Post => Is_Reclaimed (R) discharges the drop at
--  end of scope. The singleton form could prove neither (see issue #20).
--
--  SPARK_Mode On throughout; the verified work is in the units beneath.
--
--  Every store operation -- read or write -- carries In_Out on
--  Sqlite_Vec_Spark.DBMS, the external abstract state modelling the SQLite
--  subsystem across the FFI (see its note). The Resources object itself is
--  only observed (an `in` parameter): opening the connection once fixes the
--  handle, and thereafter running any query mutates DBMS, not the handle. A
--  read like Fetch_Summary is In_Out on DBMS because stepping a cursor mutates
--  connection state, and SPARK does not attempt to prove that one statement
--  cannot influence another over the same connection (the Ada.Text_IO
--  File_System stance). This effect propagates on up: through Memcp_Tools.Invoke
--  into the generic Spark_Mcp.Server.Dispatch seam and the Spark_Mcp.Http.Serve
--  loop, each re-analysed at memcp's instantiation, so the DBMS mutation stays
--  visible to flow analysis rather than hidden behind the seam.

with Ada.Text_IO;

with Memcp_Store;
with Candle_Spark;
with Sqlite_Vec_Spark;

package Memcp_Resources with SPARK_Mode => On is

   package MS renames Memcp_Store;

   type Resources is limited private
     with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
          Default_Initial_Condition =>
            not Is_Open (Resources) and then Is_Reclaimed (Resources);
   --  The bundled composition-root resources: an owned Store and an owned
   --  Embedder. Limited because its components are (each owns a raw C handle;
   --  a copy would double-free).
   --
   --  Needs_Reclamation: a Resources owns its two constituents, so it must be
   --  Closed before it is dropped or re-Opened. Its ownership is carried by its
   --  owning components (Store, Embedder) -- promoting the partial view to an
   --  ownership type is what lets its holders (memcp's main, the test drivers)
   --  see the obligation and have GNATprove check the lifecycle at every call.

   function Is_Open (R : Resources) return Boolean;
   --  Whether the bundled Store is currently open.
   --  @param R The resources to test.
   --  @return True while the Store is open, False otherwise.

   function Is_Reclaimed (R : Resources) return Boolean
     with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
   --  Reclamation predicate for the Needs_Reclamation annotation above. A
   --  Resources is reclaimed once both constituents are -- the state GNATprove
   --  requires before it is dropped or re-Opened. Ghost: proof only.
   --  @param R The resources to test.
   --  @return True iff both the Store and the Embedder are reclaimed.

   function Embedder_Loaded (R : Resources) return Boolean;
   --  True once a model has been loaded (Open with a non-empty Model_Path that
   --  succeeded). The embedding-dependent tools gate on this.
   --  @param R The resources to test.
   --  @return True when an embedding model is loaded, False otherwise.

   type Status is (Ready, Store_Failed);
   --  How Open ended. A failed embedder load is not fatal to serving: the
   --  read/list tools work without an embedder; only save/search/fetch_chunks
   --  need one and they report an error when it is absent (Embedder_Loaded is
   --  False).
   --  @enum Ready The Store opened; serving can begin.
   --  @enum Store_Failed The Store could not be opened -- nothing is usable.

   procedure Open
     (R          : in out Resources;
      DB_Path    : String;
      Model_Path : String;
      Result     : out Status)
     with Pre    => DB_Path'Length > 0 and then DB_Path'Last < Natural'Last
                    and then Is_Reclaimed (R),
          Post   => (if Result = Ready then Is_Open (R)),
          Global => (In_Out => Sqlite_Vec_Spark.DBMS);
   --  Open the Store at DB_Path (":memory:" for a throwaway) and, when
   --  Model_Path is non-empty, load the Embedder from it. Store_Failed means
   --  the Store could not be opened -- nothing is usable. A failed or skipped
   --  embedder load is not reported here; query Embedder_Loaded.
   --
   --  Pre => Is_Reclaimed (R): Open (over)writes both owned handles, so R must
   --  arrive reclaimed -- a fresh Resources is reclaimed by its
   --  Default_Initial_Condition; a re-Open requires a Close first. This is the
   --  proof-enforced open-once protocol; it is what lets Candle_Spark.Load keep
   --  its natural `out` mode with no caller-side pre-Unload and no "statement
   --  has no effect" suppression. The DB_Path precondition (rather than an
   --  internal guard that would skip the open) keeps the store-open on every
   --  path.
   --  @param R The resources to open; must arrive reclaimed.
   --  @param DB_Path Filesystem path to the SQLite database, ":memory:" for a
   --    throwaway; the precondition requires it non-empty and DB_Path'Last below
   --    Natural'Last.
   --  @param Model_Path Path to the embedding model; when non-empty the Embedder
   --    is loaded from it, otherwise the embedder load is skipped.
   --  @param Result How the open ended: Ready or Store_Failed.

   procedure Close (R : in out Resources)
     with Post    => Is_Reclaimed (R),
          Global  => (In_Out => Sqlite_Vec_Spark.DBMS),
          Depends => (Sqlite_Vec_Spark.DBMS =>+ null, R => null, null => R);
   --  Close the Store and unload the Embedder, leaving R reclaimed. Idempotent
   --  -- safe on an already-reclaimed R -- so a caller may Close on every exit
   --  path (including after a Store_Failed Open) to discharge R at end of scope.
   --  Depends (as for Memcp_Store.Close): R's new value is a constant and its
   --  old handles reach C only as addresses, so a caller that Closes R and
   --  never reads it back needs no "set but not used" flow suppression.
   --  @param R The resources to close; left reclaimed.

   function Embed
     (R : Resources; Text : String) return Candle_Spark.Embedding;
   --  Embed Text with the loaded model; the zero vector when no model is loaded
   --  or Text is empty (the caller decides whether that is an error). The replay
   --  path (recorded vectors) lives in the tool layer, not here.
   --  @param R The resources holding the embedder.
   --  @param Text The text to embed.
   --  @return The embedding vector, or the zero vector when no model is loaded
   --    or Text is empty.

   ---------------------------------------------------------------------------
   --  Store operations. Each guards Is_Open (and the Store's other
   --  preconditions) and degrades to Db_Error / an empty result, so callers
   --  need no precondition of their own. R is observed (an `in` parameter);
   --  the mutation lands on DBMS, not on R.
   ---------------------------------------------------------------------------

   procedure Recent_Diary
     (R        : Resources;
      Projects : MS.Name_List;
      N        : Natural;
      Result   : out MS.Diary_Entry_List;
      Status   : out MS.Op_Status)
     with Global => (In_Out => Sqlite_Vec_Spark.DBMS);
   --  Return the most recent diary entries across the given projects.
   --  @param R The resources holding the store.
   --  @param Projects The projects to draw diary entries from (empty for all).
   --  @param N Maximum number of entries to return.
   --  @param Result The diary entries, most recent first.
   --  @param Status Outcome of the query (Db_Error on failure).

   procedure List_Projects
     (R      : Resources;
      Result : out MS.Project_Info_List;
      Status : out MS.Op_Status)
     with Global => (In_Out => Sqlite_Vec_Spark.DBMS);
   --  List the known projects with their per-project info.
   --  @param R The resources holding the store.
   --  @param Result The per-project information records.
   --  @param Status Outcome of the query (Db_Error on failure).

   procedure Fetch_Summary
     (R      : Resources;
      Id     : MS.Row_Id;
      Result : out MS.Summary_Ptr;
      Status : out MS.Op_Status)
     with Global => (In_Out => Sqlite_Vec_Spark.DBMS);
   --  Fetch a single summary by its row id.
   --  @param R The resources holding the store.
   --  @param Id Row id of the summary to fetch.
   --  @param Result The summary (null when absent).
   --  @param Status Outcome of the query (Db_Error on failure).

   procedure Search_Summaries
     (R         : Resources;
      Query_Emb : Candle_Spark.Embedding;
      Projects  : MS.Name_List;
      Limit     : Natural;
      Has_Since : Boolean;
      Since     : String;
      Has_Until : Boolean;
      Until_At  : String;
      Result    : out MS.Summary_Hit_List;
      Status    : out MS.Op_Status)
     with Global => (In_Out => Sqlite_Vec_Spark.DBMS);
   --  Vector-search summaries, optionally restricted by project and time range.
   --  @param R The resources holding the store.
   --  @param Query_Emb The query embedding vector to rank against.
   --  @param Projects Restrict to these projects (empty for all).
   --  @param Limit Maximum number of hits to return.
   --  @param Has_Since Whether the Since lower time bound applies.
   --  @param Since Lower time bound (used only when Has_Since is True).
   --  @param Has_Until Whether the Until_At upper time bound applies.
   --  @param Until_At Upper time bound (used only when Has_Until is True).
   --  @param Result The ranked summary hits.
   --  @param Status Outcome of the query (Db_Error on failure).

   procedure Search_Chunks
     (R           : Resources;
      Query_Emb   : Candle_Spark.Embedding;
      Projects    : MS.Name_List;
      Session_Ids : MS.Name_List;
      Limit       : Natural;
      Has_Since   : Boolean;
      Since       : String;
      Has_Until   : Boolean;
      Until_At    : String;
      Result      : out MS.Chunk_Hit_List;
      Status      : out MS.Op_Status)
     with Global => (In_Out => Sqlite_Vec_Spark.DBMS);
   --  Vector-search chunks, optionally restricted by project, session and time.
   --  @param R The resources holding the store.
   --  @param Query_Emb The query embedding vector to rank against.
   --  @param Projects Restrict to these projects (empty for all).
   --  @param Session_Ids Restrict to these sessions (empty for all).
   --  @param Limit Maximum number of hits to return.
   --  @param Has_Since Whether the Since lower time bound applies.
   --  @param Since Lower time bound (used only when Has_Since is True).
   --  @param Has_Until Whether the Until_At upper time bound applies.
   --  @param Until_At Upper time bound (used only when Has_Until is True).
   --  @param Result The ranked chunk hits.
   --  @param Status Outcome of the query (Db_Error on failure).

   procedure Fetch_Turns
     (R           : Resources;
      Session_Id  : String;
      Has_Project : Boolean;
      Project     : String;
      Has_Start   : Boolean;
      Start_Ord   : MS.Row_Id;
      Has_End     : Boolean;
      End_Ord     : MS.Row_Id;
      Has_Tail    : Boolean;
      Tail        : Positive;
      Result      : out MS.Chunk_List;
      Status      : out MS.Op_Status)
     with Global => (In_Out => Sqlite_Vec_Spark.DBMS);
   --  Fetch turns of a session by position (ordinal range or a trailing tail).
   --  @param R The resources holding the store.
   --  @param Session_Id The session whose turns are fetched.
   --  @param Has_Project Whether the Project filter applies.
   --  @param Project Project filter (used only when Has_Project is True).
   --  @param Has_Start Whether the Start_Ord lower bound applies.
   --  @param Start_Ord First ordinal to include (used when Has_Start is True).
   --  @param Has_End Whether the End_Ord upper bound applies.
   --  @param End_Ord Last ordinal to include (used when Has_End is True).
   --  @param Has_Tail Whether the Tail trailing-count applies.
   --  @param Tail Number of trailing turns to return (used when Has_Tail True).
   --  @param Result The matching chunks (turns).
   --  @param Status Outcome of the query (Db_Error on failure).

   procedure Save
     (R            : Resources;
      Project      : String;
      Diary_Body   : String;
      Summary_Body : String;
      Embedding    : Candle_Spark.Embedding;
      Has_Session  : Boolean;
      Session_Id   : String;
      Has_Created  : Boolean;
      Created_At   : String;
      Result       : out MS.Save_Result;
      Status       : out MS.Op_Status)
     with Global => (In_Out => (Sqlite_Vec_Spark.DBMS, Ada.Text_IO.File_System));
   --  Persist a diary headline plus its summary and embedding for a project.
   --  @param R The resources holding the store.
   --  @param Project The project the entry belongs to.
   --  @param Diary_Body The single-line diary headline.
   --  @param Summary_Body The full structured summary text.
   --  @param Embedding The summary embedding vector.
   --  @param Has_Session Whether Session_Id is supplied.
   --  @param Session_Id Session id (used only when Has_Session is True).
   --  @param Has_Created Whether Created_At is supplied.
   --  @param Created_At Creation timestamp (used only when Has_Created is True).
   --  @param Result Row ids written by the save.
   --  @param Status Outcome of the write (Db_Error on failure).

   procedure Forget_Summary
     (R       : Resources;
      Id      : MS.Row_Id;
      Deleted : out Boolean;
      Status  : out MS.Op_Status)
     with Global => (In_Out => (Sqlite_Vec_Spark.DBMS, Ada.Text_IO.File_System));
   --  Delete a summary (and its dependents) by row id.
   --  @param R The resources holding the store.
   --  @param Id Row id of the summary to delete.
   --  @param Deleted True when a row was actually removed.
   --  @param Status Outcome of the delete (Db_Error on failure).

   procedure Save_Session
     (R           : Resources;
      Project     : String;
      Session_Id  : String;
      Transcript  : String;
      Chunks      : MS.Chunk_Input_List;
      Has_Created : Boolean;
      Created_At  : String;
      Result      : out MS.Session_Save_Result;
      Status      : out MS.Op_Status)
     with Global => (In_Out => (Sqlite_Vec_Spark.DBMS, Ada.Text_IO.File_System));
   --  Persist a full session transcript together with its per-turn chunks.
   --  @param R The resources holding the store.
   --  @param Project The project the session belongs to.
   --  @param Session_Id Identifier of the session being saved.
   --  @param Transcript The full verbatim transcript text.
   --  @param Chunks The per-turn chunk inputs to store.
   --  @param Has_Created Whether Created_At is supplied.
   --  @param Created_At Creation timestamp (used only when Has_Created is True).
   --  @param Result Row ids written by the session save.
   --  @param Status Outcome of the write (Db_Error on failure).

   procedure Save_Autorecap
     (R           : Resources;
      Project     : String;
      Session_Id  : String;
      Recap_Text  : String;
      Embedding   : Candle_Spark.Embedding;
      Has_Created : Boolean;
      Created_At  : String;
      Summary_Id  : out MS.Row_Id;
      Diary_Id    : out MS.Row_Id;
      Written     : out Boolean;
      Status      : out MS.Op_Status)
     with Global => (In_Out => (Sqlite_Vec_Spark.DBMS, Ada.Text_IO.File_System));
   --  Persist a fallback autorecap summary/diary pair for a session.
   --  @param R The resources holding the store.
   --  @param Project The project the recap belongs to.
   --  @param Session_Id Identifier of the session being recapped.
   --  @param Recap_Text The recap text stored as both summary and diary.
   --  @param Embedding The recap embedding vector.
   --  @param Has_Created Whether Created_At is supplied.
   --  @param Created_At Creation timestamp (used only when Has_Created is True).
   --  @param Summary_Id Row id of the written summary.
   --  @param Diary_Id Row id of the written diary entry.
   --  @param Written True when the recap was actually written.
   --  @param Status Outcome of the write (Db_Error on failure).

private

   --  Hide the representation from clients' proof context: the Ownership
   --  annotation on Resources requires its private part to be either SPARK_Mode
   --  (Off) or hidden, and hiding keeps this body IN SPARK. Clients reason about
   --  Resources abstractly -- through Is_Open, the Needs_Reclamation obligation,
   --  and the operation contracts -- exactly as for Memcp_Store.Store and
   --  Candle_Spark.Embedder.
   pragma Annotate (GNATprove, Hide_Info, "Private_Part");

   type Resources is limited record
      The_Store    : MS.Store;                --  The owned SQLite store.
      The_Embedder : Candle_Spark.Embedder;   --  The owned embedding model.
   end record;
   --  Full view: the two owned constituents. No status flags -- the open/loaded
   --  state and the reclamation state are read straight off the handles (a
   --  handle IS its own liveness), which is what removes the old implicit
   --  flag <-> ownership coupling the singleton relied on.

   function Is_Open (R : Resources) return Boolean is
     (MS.Is_Open (R.The_Store));

   function Is_Reclaimed (R : Resources) return Boolean is
     (MS.Is_Reclaimed (R.The_Store)
      and then Candle_Spark.Is_Reclaimed (R.The_Embedder));

   function Embedder_Loaded (R : Resources) return Boolean is
     (Candle_Spark.Is_Loaded (R.The_Embedder));

end Memcp_Resources;
