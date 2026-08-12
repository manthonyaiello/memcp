--  memcp's concrete tool set: the tool enumeration, the three accessors that
--  instantiate the generic Spark_Mcp.Server, and the Invoke that runs one tool
--  against a Memcp.Resources object. Each tool parses its own `arguments` with
--  Memcp.Json and renders its reply as JSON text.

with Spark_Mcp.Tools;
with Memcp.Resources;

package Memcp.Tools with SPARK_Mode => On is

   type Tool_Id is
     (Recent,
      List_Projects,
      Save,
      Forget,
      Search,
      Fetch_Summary,
      Upload_Session,
      Fetch_Chunks,
      Fetch_Turns);
   --  memcp's tool set. The enumeration literals are the identifiers; the
   --  lowercase wire names come from Name below.
   --  @enum Recent The N most recent diary Headers.
   --  @enum List_Projects Every project memcp has seen, newest activity first.
   --  @enum Save Save a (diary line, structured summary) pair.
   --  @enum Forget Delete a summary, diary line, and embedding by id.
   --  @enum Search Semantic search over Summaries.
   --  @enum Fetch_Summary Fetch a full Summary by id.
   --  @enum Upload_Session Persist a session transcript plus embeddable
   --    chunks.
   --  @enum Fetch_Chunks Semantic search over session chunks (the Details).
   --  @enum Fetch_Turns Fetch verbatim conversation turns by position.

   function Name (Id : Tool_Id) return String is
     (case Id is
         when Recent         => "recent",
         when List_Projects  => "list_projects",
         when Save           => "save",
         when Forget         => "forget",
         when Search         => "search",
         when Fetch_Summary  => "fetch_summary",
         when Upload_Session => "upload_session",
         when Fetch_Chunks   => "fetch_chunks",
         when Fetch_Turns    => "fetch_turns");
   --  The wire name (lowercase) of a tool. An expression function in the spec
   --  rather than the body: the generic Server's tools/list length bound is
   --  proved at the instantiation, which can only see each result's length if
   --  these accessors are inlinable there.
   --  @param Id The tool whose wire name is requested.
   --  @return The lowercase wire name of the tool.

   function Description (Id : Tool_Id) return String is
     (case Id is
         when Recent =>
            "Return Headers for the N most recent diary entries. "
              & "Headers only -- use fetch_summary(summary_id) for the full "
              & "body, unless kind == 'autorecap' (Header text already is it).",
         when List_Projects =>
            "List every project memcp has seen, newest activity first. "
              & "Each entry carries project, diary_count, and latest_at.",
         when Save =>
            "Save a (diary line, structured summary) pair as a "
              & "kind='diary' Header. With session_id it is a session-scoped "
              & "upsert: a later save in the same session replaces it in "
              & "place. Pass the surface the SessionStart hook injected.",
         when Forget =>
            "Delete a summary, its diary line, and its embedding by "
              & "summary id. Returns {""deleted"": false} if the id is unknown.",
         when Search =>
            "Semantic search over Summaries. projects=null searches all "
              & "projects; pass projects=['memcp'] to scope. Hits carry kind.",
         when Fetch_Summary =>
            "Fetch a full Summary by id; returns null if missing. "
              & "Includes body; for kind='autorecap' body equals the Header.",
         when Upload_Session =>
            "Persist a session transcript (base64) plus embeddable "
              & "chunks (the verbatim turns). Idempotent on (project, "
              & "session_id). The raw transcript is not retrievable by any tool.",
         when Fetch_Chunks =>
            "Semantic search over session chunks (the Details). Pass "
              & "session_ids=[...] to scope to specific sessions.",
         when Fetch_Turns =>
            "Fetch verbatim conversation turns by position -- NOT "
              & "semantic search. last=N for the final N turns; start/end for a "
              & "half-open [start,end) slice; neither for the whole session.");
   --  The human-readable description of a tool, shown in the tools/list
   --  listing.
   --  @param Id The tool whose description is requested.
   --  @return The description text for the tool.

   function Input_Schema (Id : Tool_Id) return String is
     (case Id is
         when Recent =>
            "{""type"":""object"",""properties"":{"
              & """projects"":{""type"":""array"",""items"":{""type"":"
              & """string""}},""n"":{""type"":""integer""}},"
              & """required"":[""projects""]}",
         when List_Projects =>
            "{""type"":""object"",""properties"":{}}",
         when Save =>
            "{""type"":""object"",""properties"":{"
              & """project"":{""type"":""string""},"
              & """diary"":{""type"":""string""},"
              & """summary"":{""type"":""string""},"
              & """session_id"":{""type"":""string""},"
              & """surface"":{""type"":""string""},"
              & """created_at"":{""type"":""string""}},"
              & """required"":[""project""]}",
         when Forget =>
            "{""type"":""object"",""properties"":{"
              & """summary_id"":{""type"":""integer""}},"
              & """required"":[""summary_id""]}",
         when Search =>
            "{""type"":""object"",""properties"":{"
              & """query"":{""type"":""string""},"
              & """projects"":{""type"":""array"",""items"":{""type"":"
              & """string""}},""limit"":{""type"":""integer""},"
              & """since"":{""type"":""string""},"
              & """until"":{""type"":""string""}},"
              & """required"":[""query""]}",
         when Fetch_Summary =>
            "{""type"":""object"",""properties"":{"
              & """summary_id"":{""type"":""integer""}},"
              & """required"":[""summary_id""]}",
         when Upload_Session =>
            "{""type"":""object"",""properties"":{"
              & """project"":{""type"":""string""},"
              & """session_id"":{""type"":""string""},"
              & """transcript_b64"":{""type"":""string""},"
              & """surface"":{""type"":""string""}},"
              & """required"":[""project"",""session_id"",""transcript_b64""]}",
         when Fetch_Chunks =>
            "{""type"":""object"",""properties"":{"
              & """query"":{""type"":""string""},"
              & """projects"":{""type"":""array"",""items"":{""type"":"
              & """string""}},"
              & """session_ids"":{""type"":""array"",""items"":{""type"":"
              & """string""}},""limit"":{""type"":""integer""},"
              & """since"":{""type"":""string""},"
              & """until"":{""type"":""string""}},"
              & """required"":[""query""]}",
         when Fetch_Turns =>
            "{""type"":""object"",""properties"":{"
              & """session_id"":{""type"":""string""},"
              & """project"":{""type"":""string""},"
              & """last"":{""type"":""integer""},"
              & """start"":{""type"":""integer""},"
              & """end"":{""type"":""integer""}},"
              & """required"":[""session_id""]}");
   --  The JSON Schema for a tool's `arguments` object.
   --  @param Id The tool whose input schema is requested.
   --  @return The JSON Schema text describing the tool's arguments.

   procedure Invoke
     (R         : Memcp.Resources.Resources;
      Id        : Tool_Id;
      Arguments : String;
      Result    : out Spark_Mcp.Tools.Result_Ptr)
   with Pre => Arguments'Length <= Spark_Mcp.Max_Field;
   --  Run tool Id against the Resources R and render its reply. `Arguments` is
   --  the request's params.arguments as raw JSON text ("{}" when the client
   --  sent none), which each tool parses itself; the Max_Field precondition is
   --  what lets a tool build a result straight from Arguments and still uphold
   --  Invocation_Result's Len bound. R is observed -- a mutating tool (save,
   --  forget, upload_session) mutates the SQLite subsystem, not R.
   --  @param R The resources (open Store, maybe-loaded Embedder) to run against.
   --  @param Id The tool to invoke.
   --  @param Arguments The request's params.arguments as raw JSON text.
   --  @param Result Out; the freshly allocated invocation result to hand back.

   Instructions : constant String;
   --  Surfaced to the client on initialize: the retrieval ladder
   --  (Header -> Summary -> Details) the model follows.

private

   LF : constant Character := Character'Val (10);
   --  ASCII line feed, for the multi-line Instructions text below.

   Instructions : constant String :=
     "memcp: progressive-disclosure project memory" & LF
     & LF
     & "## Structure" & LF
     & LF
     & "1. Header - 1-2 sentence summary of the last session. Each Header"
     & " carries a" & LF
     & "   `kind` field:" & LF
     & LF
     & "  - kind=""diary""     -- a real model-authored summary is available."
     & LF
     & "  - kind=""autorecap"" -- fallback recap line from last session." & LF
     & "                       Header text == Summary text. NO fetch_summary; go"
     & LF
     & "                       straight to fetch_chunks if you need more." & LF
     & LF
     & "2. Summary - Claude-authored summary of the session." & LF
     & LF
     & "3. Details - verbatim user/assistant turns (one per message; tool calls,"
     & LF
     & "   results, and thinking are not stored). `fetch_chunks` finds them by"
     & LF
     & "   relevance; `fetch_turns` retrieves them by position (`ordinal` = turn"
     & LF
     & "   index), e.g. `fetch_turns(session_id, last=2)` for the last two turns."
     & LF
     & LF
     & "## Effective Use" & LF
     & LF
     & "Use Headers as keys to Summaries, Summaries as keys to full Details with"
     & LF
     & "fetch_chunks(query=<your question>, session_ids=[that_summary.session_id])"
     & LF
     & LF
     & "Use search for Summary recall beyond the Headers given at session start."
     & LF
     & LF
     & "## Saving" & LF
     & LF
     & "save(project, diary, summary, session_id, surface). `diary` is a single"
     & LF
     & "headline line; `summary` is the full structured body. Pass each in its"
     & " own" & LF
     & "argument, and `surface` verbatim as SessionStart injected it." & LF
     & "Saves are session-scoped: a later save() in the same session replaces the"
     & LF
     & "prior one in place, so it is safe to save early and re-save as more lands.";
   --  Completion of Instructions: the initialize-time instruction text.

end Memcp.Tools;
