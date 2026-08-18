--  Memcp.Resources: the composition root's owned resources -- one opened Store
--  and one loaded Embedder -- bundled in a single object whose open-once
--  lifecycle GNATprove enforces. Opening is the one fallible step; every
--  operation after it is total.

with Ada.Text_IO;

with Memcp.Store;
with Candle_Spark;
with Sqlite_Vec_Spark;

package Memcp.Resources with SPARK_Mode => On is

   package MS renames Memcp.Store;
   --  Shorthand for the store vocabulary this spec is written in.

   type Resources is limited private
     with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
          Default_Initial_Condition =>
            not Is_Open (Resources) and then Is_Reclaimed (Resources);
   --  An owned Store and an owned Embedder, opened and closed as one.

   function Is_Open (R : Resources) return Boolean;
   --  Whether the bundled Store is currently open.
   --  @param R The resources to test.
   --  @return True while the Store is open, False otherwise.

   function Is_Reclaimed (R : Resources) return Boolean
     with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
   --  Reclamation predicate for Resources: reclaimed once both constituents
   --  are.
   --  @param R The resources to test.
   --  @return True iff both the Store and the Embedder are reclaimed.

   function Embedder_Loaded (R : Resources) return Boolean;
   --  Whether a model is loaded: Open was given a non-empty Model_Path and the
   --  load succeeded.
   --  @param R The resources to test.
   --  @return True when an embedding model is loaded, False otherwise.

   type Status is (Ready, Store_Failed);
   --  How Open ended; a failed embedder load does not appear here.
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
   --  Open the Store at DB_Path and, when Model_Path is non-empty, load the
   --  Embedder from it. A failed or skipped embedder load is not reported here;
   --  query Embedder_Loaded.
   --  @param R The resources to open; a fresh one qualifies, a re-Open needs a
   --    Close first.
   --  @param DB_Path Filesystem path to the SQLite database, ":memory:" for a
   --    throwaway.
   --  @param Model_Path Path to the embedding model; empty skips the embedder
   --    load.
   --  @param Result How the open ended: Ready or Store_Failed.

   procedure Close (R : in out Resources)
     with Post    => Is_Reclaimed (R),
          Global  => (In_Out => Sqlite_Vec_Spark.DBMS),
          --  R's new value is a constant and its old handles reach C only as
          --  addresses, so a caller that Closes R and never reads it back needs
          --  no "set but not used" suppression.
          Depends => (Sqlite_Vec_Spark.DBMS =>+ null, R => null, null => R);
   --  Close the Store and unload the Embedder, leaving R reclaimed. Idempotent,
   --  so a caller may Close on every exit path -- including after a Store_Failed
   --  Open -- to discharge R at end of scope.
   --  @param R The resources to close; left reclaimed.

   function Embed
     (R : Resources; Text : String) return Candle_Spark.Embedding;
   --  Embed Text with the loaded model; the zero vector when no model is loaded
   --  or Text is empty, leaving the caller to decide whether that is an error.
   --  @param R The resources holding the embedder.
   --  @param Text The text to embed.
   --  @return The embedding vector, or the zero vector when no model is loaded
   --    or Text is empty.

   ---------------------------------------------------------------------------
   --  Store operations. Each guards Is_Open and the Store's other
   --  preconditions itself, degrading to Db_Error and an empty result, so a
   --  caller needs no precondition of its own.
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

   procedure Degraded_Surfaces
     (R      : Resources;
      Result : out MS.Surface_Health_List;
      Status : out MS.Op_Status)
     with Global => (In_Out => Sqlite_Vec_Spark.DBMS);
   --  Report the surfaces whose sessions are saving summaries without
   --  uploading transcripts, over Memcp.Store's Health_Window and
   --  Health_Threshold.
   --  @param R The resources holding the store.
   --  @param Result One record per degraded surface; empty means healthy.
   --  @param Status Outcome of the query (Db_Error on failure).

   procedure Touch_Surface
     (R      : Resources;
      Uuid   : String;
      Label  : String;
      Status : out MS.Op_Status)
     with Global => (In_Out => Sqlite_Vec_Spark.DBMS);
   --  Record a surface as in use now, without it having written anything.
   --  @param R The resources holding the store.
   --  @param Uuid The surface's UUID; empty does nothing.
   --  @param Label The surface's label.
   --  @param Status Outcome of the write (Db_Error on failure).

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
      Surface      : String;
      Surface_Label : String;
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
   --  @param Surface The writing surface's id; empty leaves the row unattributed.
   --  @param Surface_Label The writing surface's human-readable name.
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
      Surface       : String;
      Surface_Label : String;
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
   --  @param Surface The uploading surface's id; empty leaves the row
   --    unattributed.
   --  @param Surface_Label The uploading surface's human-readable name.
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
      Surface       : String;
      Surface_Label : String;
      Result      : out MS.Autorecap_Result;
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
   --  @param Surface The writing surface's id; empty leaves the row unattributed.
   --  @param Surface_Label The writing surface's human-readable name.
   --  @param Result The rowids written and whether a write happened.
   --  @param Status Outcome of the write (Db_Error on failure).

private

   pragma Annotate (GNATprove, Hide_Info, "Private_Part");
   --  Required for the Ownership annotation on Resources, and keeps the body in
   --  SPARK.

   type Resources is limited record
      The_Store    : MS.Store;                --  The owned SQLite store.
      The_Embedder : Candle_Spark.Embedder;   --  The owned embedding model.
   end record;
   --  Full view: the two owned constituents and no status flags -- open, loaded
   --  and reclaimed are each read off a handle.

   function Is_Open (R : Resources) return Boolean is
     (MS.Is_Open (R.The_Store));
   --  Completion of the openness predicate: read off the owned store.
   --  @param R The resources to test.
   --  @return True iff R holds an open store.

   function Is_Reclaimed (R : Resources) return Boolean is
     (MS.Is_Reclaimed (R.The_Store)
      and then Candle_Spark.Is_Reclaimed (R.The_Embedder));
   --  Completion of the reclamation predicate.
   --  @param R The resources to test.
   --  @return True iff neither the store nor the embedder owns anything.

   function Embedder_Loaded (R : Resources) return Boolean is
     (Candle_Spark.Is_Loaded (R.The_Embedder));
   --  Completion of the embedder-loaded predicate.
   --  @param R The resources to test.
   --  @return True iff R holds a loaded embedding model.

end Memcp.Resources;
