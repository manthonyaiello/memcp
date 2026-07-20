--  memcp's concrete tool set: the 9 tools, as the enumeration + accessors that
--  instantiate the generic Spark_Mcp.Server. This is the ONLY place the memcp
--  surface is named -- spark_mcp stays a reusable, coupling-free MCP library.
--
--  Wire names and behaviour mirror src/memcp/server.py 1:1.
--
--  Like Memcp_Envelope (the inbound half of the json marshalling), this unit is
--  trusted composition-root glue -- not in SPARK_Mode. It parses each tool's
--  `arguments` and renders each result with Memcp_Json, and runs the request
--  against a Memcp_Resources object; the verified surface is the units it
--  stands on (Memcp_Store Silver, json Silver, Spark_Mcp.Writer Silver). Invoke
--  takes the Resources as its first parameter: the generic seam
--  (Id/Arguments/Result) has nowhere to pass it, so the composition root wraps
--  Invoke in a nested adapter that closes over its Resources object and forwards
--  here (see memcp.adb). That keeps the owned Store/Embedder a tracked local
--  rather than hidden package state.

with Spark_Mcp.Tools;
with Memcp_Resources;

package Memcp_Tools with SPARK_Mode => On is

   type Tool_Id is
     (Recent,          --  The N most recent diary Headers.
      List_Projects,   --  Every project memcp has seen, newest activity first.
      Save,            --  Save a (diary line, structured summary) pair.
      Forget,          --  Delete a summary, diary line, and embedding by id.
      Search,          --  Semantic search over Summaries.
      Fetch_Summary,   --  Fetch a full Summary by id.
      Upload_Session,  --  Persist a session transcript plus embeddable chunks.
      Fetch_Chunks,    --  Semantic search over session chunks (the Details).
      Fetch_Turns);    --  Fetch verbatim conversation turns by position.
   --  The 9 tools (server.py). Enumeration literals ARE the identifiers; the
   --  wire names (lowercase) come from Name below.

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
   --  The wire name (lowercase) of a tool.
   --  Expression functions IN THE SPEC (not the body): the generic Server's
   --  tools/list length-bound proof runs at the instantiation in memcp.adb and
   --  can only see each result's length if these are inlinable there -- which a
   --  body expression function, invisible cross-unit, is not. Mirrors how
   --  spark_mcp's own proof harness declares its accessors.
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
              & "upsert: a later save in the same session replaces it in place.",
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
   --  The human-readable description of a tool (server.py 1:1), shown in
   --  the tools/list listing.
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
              & """transcript_b64"":{""type"":""string""}},"
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
   --  The JSON Schema for a tool's `arguments` object (server.py 1:1).
   --  @param Id The tool whose input schema is requested.
   --  @return The JSON Schema text describing the tool's arguments.

   procedure Invoke
     (R         : Memcp_Resources.Resources;
      Id        : Tool_Id;
      Arguments : String;
      Result    : out Spark_Mcp.Tools.Result_Ptr)
   with Pre => Arguments'Length <= Spark_Mcp.Max_Field;
   --  Run tool Id against the Resources R and render its reply. R is observed
   --  (an `in` parameter); a mutating tool (save/forget/upload_session) mutates
   --  the SQLite subsystem (DBMS), not R. Not the generic actual itself -- the
   --  composition root passes a 3-argument adapter that closes over R and calls
   --  here (see the seam note above).
   --  `Arguments` is the request's params.arguments as raw JSON text ("{}" if
   --  none). Each tool parses the fields it needs with memcp's own JSON
   --  instantiation (Memcp_Json) -- spark_mcp itself stays json-free -- runs the
   --  request against the Memcp_Resources Store/Embedder, and renders the reply.
   --
   --  A procedure handing out an ownership allocation (Spark_Mcp.Tools.
   --  Result_Ptr): the reshaped seam that lets a real tool mutate the Store
   --  (save/forget) -- a SPARK function cannot have side effects. The Max_Field
   --  precondition mirrors the generic formal's contract, so a tool may build a
   --  result straight from Arguments and still uphold the Len <= Max_Field
   --  predicate on Invocation_Result.
   --  @param R The resources (open Store, maybe-loaded Embedder) to run against.
   --  @param Id The tool to invoke.
   --  @param Arguments The request's params.arguments as raw JSON text.
   --  @param Result Out; the freshly allocated invocation result to hand back.

   Instructions : constant String;
   --  Surfaced to the client on initialize (server.py INSTRUCTIONS): the
   --  retrieval ladder (Header -> Summary -> Details) the model follows.

private

   LF : constant Character := Character'Val (10);
   --  ASCII line feed, used to build the multi-line Instructions text below.

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
     & "save(project, diary, summary, session_id). `diary` is a single headline"
     & LF
     & "line; `summary` is the full structured body. Pass each in its own"
     & " argument." & LF
     & "Saves are session-scoped: a later save() in the same session replaces the"
     & LF
     & "prior one in place, so it is safe to save early and re-save as more lands.";
   --  Completion of Instructions: the full initialize-time instruction text
   --  (server.py INSTRUCTIONS), describing the Header -> Summary -> Details
   --  retrieval ladder, effective use, and the save() contract.

end Memcp_Tools;
