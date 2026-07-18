--  The composition-root singletons the tool layer runs against: one opened
--  Store and one loaded Embedder, held as this package's Abstract_State. The
--  tool layer (and the -gnata test drivers) reach them ONLY through the total
--  operations below -- SPARK forbids handing out an access to a global object,
--  so the old Store_Ref/Embedder_Ref accessors are gone. Every operation is a
--  thin, precondition-free pass-through to the proved units beneath
--  (Memcp_Store, Candle_Spark): it guards the Store's own preconditions
--  internally (Is_Open, non-empty project, ...) and degrades to Db_Error / an
--  empty result rather than requiring the caller to establish them.
--
--  SPARK_Mode On: the state and its mutations are analysed here; the verified
--  work is in the units beneath.
--
--  Every store operation -- read or write -- carries In_Out on
--  Sqlite_Vec_Spark.DBMS, the external abstract state modelling the SQLite
--  subsystem across the FFI (see its note). The Store handle itself is only
--  read (Input => Store_State): opening the connection once fixes the handle,
--  and thereafter running any query mutates DBMS, not the handle. A read like
--  Fetch_Summary is In_Out on DBMS because stepping a cursor mutates connection
--  state, and SPARK does not attempt to prove that one statement cannot
--  influence another over the same connection (the Ada.Text_IO File_System
--  stance). This effect propagates on up: through Memcp_Tools.Invoke into the
--  generic Spark_Mcp.Server.Dispatch seam and the Spark_Mcp.Http.Serve loop,
--  each re-analysed at memcp's instantiation, so the DBMS mutation stays
--  visible to flow analysis rather than hidden behind the seam.

with Ada.Text_IO;

with Memcp_Store;
with Candle_Spark;
with Sqlite_Vec_Spark;

package Memcp_Resources with
  SPARK_Mode     => On,
  Abstract_State => (Store_State, Embedder_State),
  Initializes    => (Store_State, Embedder_State)
is

   package MS renames Memcp_Store;

   type Open_Status is (Ready, Store_Failed);
   --  How Open ended. Embed_Failed is not fatal to serving: the read/list tools
   --  work without an embedder; only save/search/fetch_chunks need one and they
   --  report an error when it is absent (Embedder_Loaded is False).
   --  @enum Ready The Store opened; serving can begin.
   --  @enum Store_Failed The Store could not be opened -- nothing is usable.

   procedure Open
     (DB_Path : String; Model_Path : String; Status : out Open_Status)
     with Pre    => DB_Path'Length > 0 and then DB_Path'Last < Natural'Last,
          Global => (Output => Store_State, In_Out => (Embedder_State, Sqlite_Vec_Spark.DBMS));
   --  Open the singleton Store at DB_Path (":memory:" for a throwaway) and, when
   --  Model_Path is non-empty, load the singleton Embedder from it. Store_Failed
   --  means the Store could not be opened -- nothing is usable. A failed or
   --  skipped embedder load is not reported here; query Embedder_Loaded.
   --  The Store is (re)opened here as an Output: the whole Store_State is
   --  written on every path, so its prior contents are never leaked. That in
   --  turn means Open must always reach Memcp_Store.Open, hence the precondition
   --  on DB_Path (rather than an internal guard that would skip the open).
   --  @param DB_Path Filesystem path to the SQLite database, ":memory:" for a
   --    throwaway; the precondition requires it non-empty and DB_Path'Last below
   --    Natural'Last.
   --  @param Model_Path Path to the embedding model; when non-empty the Embedder
   --    is loaded from it, otherwise the embedder load is skipped.
   --  @param Status How the open ended: Ready or Store_Failed.

   procedure Close with Global => (In_Out => (Store_State, Embedder_State, Sqlite_Vec_Spark.DBMS));
   --  Close the Store and unload the Embedder. Idempotent.

   function Is_Open return Boolean with Global => (Input => Store_State);
   --  Whether the singleton Store is currently open.
   --  @return True while a Store is open, False otherwise.

   function Embedder_Loaded return Boolean
     with Global => (Input => Embedder_State);
   --  True once a model has been loaded (Open with a non-empty Model_Path that
   --  succeeded). The embedding-dependent tools gate on this.
   --  @return True when an embedding model is loaded, False otherwise.

   ---------------------------------------------------------------------------
   --  Store operations. Each guards Is_Open (and the Store's other
   --  preconditions) and degrades to Db_Error / an empty result, so callers
   --  need no precondition of their own.
   ---------------------------------------------------------------------------

   procedure Recent_Diary
     (Projects : MS.Name_List;
      N        : Natural;
      Result   : out MS.Diary_Entry_List;
      Status   : out MS.Op_Status)
     with Global => (Input => Store_State, In_Out => Sqlite_Vec_Spark.DBMS);
   --  Return the most recent diary entries across the given projects.
   --  @param Projects The projects to draw diary entries from (empty for all).
   --  @param N Maximum number of entries to return.
   --  @param Result The diary entries, most recent first.
   --  @param Status Outcome of the query (Db_Error on failure).

   procedure List_Projects
     (Result : out MS.Project_Info_List;
      Status : out MS.Op_Status)
     with Global => (Input => Store_State, In_Out => Sqlite_Vec_Spark.DBMS);
   --  List the known projects with their per-project info.
   --  @param Result The per-project information records.
   --  @param Status Outcome of the query (Db_Error on failure).

   procedure Fetch_Summary
     (Id     : MS.Row_Id;
      Result : out MS.Summary_Ptr;
      Status : out MS.Op_Status)
     with Global => (Input => Store_State, In_Out => Sqlite_Vec_Spark.DBMS);
   --  Fetch a single summary by its row id.
   --  @param Id Row id of the summary to fetch.
   --  @param Result The summary (null when absent).
   --  @param Status Outcome of the query (Db_Error on failure).

   procedure Search_Summaries
     (Query_Emb : Candle_Spark.Embedding;
      Projects  : MS.Name_List;
      Limit     : Natural;
      Has_Since : Boolean;
      Since     : String;
      Has_Until : Boolean;
      Until_At  : String;
      Result    : out MS.Summary_Hit_List;
      Status    : out MS.Op_Status)
     with Global => (Input => Store_State, In_Out => Sqlite_Vec_Spark.DBMS);
   --  Vector-search summaries, optionally restricted by project and time range.
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
     (Query_Emb   : Candle_Spark.Embedding;
      Projects    : MS.Name_List;
      Session_Ids : MS.Name_List;
      Limit       : Natural;
      Has_Since   : Boolean;
      Since       : String;
      Has_Until   : Boolean;
      Until_At    : String;
      Result      : out MS.Chunk_Hit_List;
      Status      : out MS.Op_Status)
     with Global => (Input => Store_State, In_Out => Sqlite_Vec_Spark.DBMS);
   --  Vector-search chunks, optionally restricted by project, session and time.
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
     (Session_Id  : String;
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
     with Global => (Input => Store_State, In_Out => Sqlite_Vec_Spark.DBMS);
   --  Fetch turns of a session by position (ordinal range or a trailing tail).
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
     (Project      : String;
      Diary_Body   : String;
      Summary_Body : String;
      Embedding    : Candle_Spark.Embedding;
      Has_Session  : Boolean;
      Session_Id   : String;
      Has_Created  : Boolean;
      Created_At   : String;
      Result       : out MS.Save_Result;
      Status       : out MS.Op_Status)
     with Global => (Input  => Store_State,
                     In_Out => (Sqlite_Vec_Spark.DBMS, Ada.Text_IO.File_System));
   --  Persist a diary headline plus its summary and embedding for a project.
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
     (Id      : MS.Row_Id;
      Deleted : out Boolean;
      Status  : out MS.Op_Status)
     with Global => (Input  => Store_State,
                     In_Out => (Sqlite_Vec_Spark.DBMS, Ada.Text_IO.File_System));
   --  Delete a summary (and its dependents) by row id.
   --  @param Id Row id of the summary to delete.
   --  @param Deleted True when a row was actually removed.
   --  @param Status Outcome of the delete (Db_Error on failure).

   procedure Save_Session
     (Project     : String;
      Session_Id  : String;
      Transcript  : String;
      Chunks      : MS.Chunk_Input_List;
      Has_Created : Boolean;
      Created_At  : String;
      Result      : out MS.Session_Save_Result;
      Status      : out MS.Op_Status)
     with Global => (Input  => Store_State,
                     In_Out => (Sqlite_Vec_Spark.DBMS, Ada.Text_IO.File_System));
   --  Persist a full session transcript together with its per-turn chunks.
   --  @param Project The project the session belongs to.
   --  @param Session_Id Identifier of the session being saved.
   --  @param Transcript The full verbatim transcript text.
   --  @param Chunks The per-turn chunk inputs to store.
   --  @param Has_Created Whether Created_At is supplied.
   --  @param Created_At Creation timestamp (used only when Has_Created is True).
   --  @param Result Row ids written by the session save.
   --  @param Status Outcome of the write (Db_Error on failure).

   procedure Save_Autorecap
     (Project     : String;
      Session_Id  : String;
      Recap_Text  : String;
      Embedding   : Candle_Spark.Embedding;
      Has_Created : Boolean;
      Created_At  : String;
      Summary_Id  : out MS.Row_Id;
      Diary_Id    : out MS.Row_Id;
      Written     : out Boolean;
      Status      : out MS.Op_Status)
     with Global => (Input  => Store_State,
                     In_Out => (Sqlite_Vec_Spark.DBMS, Ada.Text_IO.File_System));
   --  Persist a fallback autorecap summary/diary pair for a session.
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

   function Embed
     (Text : String) return Candle_Spark.Embedding
     with Global => (Input => Embedder_State);
   --  Embed Text with the loaded model; the zero vector when no model is loaded
   --  or Text is empty (the caller decides whether that is an error). The replay
   --  path (recorded vectors) lives in the tool layer, not here.
   --  @param Text The text to embed.
   --  @return The embedding vector, or the zero vector when no model is loaded
   --    or Text is empty.

end Memcp_Resources;
