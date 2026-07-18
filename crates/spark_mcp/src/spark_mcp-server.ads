--  The reusable MCP server, generic over an application's tool set.
--
--  An application supplies its tools as an enumeration (`Tool_Id`) plus four
--  accessors. spark_mcp handles the entire JSON-RPC 2.0 + MCP envelope on top:
--  method routing (initialize / tools/list / tools/call / ping), id echoing,
--  error framing, and (for tools/list) enumerating `Tool_Id` to build the tool
--  catalog. No access-to-subprogram is used -- the seam is generic formals,
--  which keeps it inside SPARK's comfort zone.
--
--  Deliberately json-free. The frozen contract (Dispatch) is bytes-in /
--  bytes-out; a tool's `arguments` are handed over as raw JSON *text* (see
--  Invoke below), so this reusable core has no dependency on any JSON library
--  and can be built and proved independently. The application (memcp) owns the
--  choice of JSON parser and re-parses the small arguments object per call.
--
--  Dispatch is THE signature to freeze (see Spark_Mcp). Spark_Mcp.Http adapts
--  the C (ptr,len) boundary to it; JSON never crosses into the transport.
--
--  @formal Server_Name The MCP server name reported to the client on
--    initialize.
--  @formal Server_Version The MCP server version reported to the client on
--    initialize.
--  @formal Instructions Surfaced to the client as the MCP `instructions`
--    block on initialize.
--  @formal Tool_Id The application's tools, as a contiguous enumeration.
--    spark_mcp iterates over Tool_Id'Range to build tools/list, and maps an
--    incoming tool name back to a Tool_Id for tools/call.
--  @formal Name Returns the wire name of the given tool.
--  @formal Description Returns the human-readable description of the given
--    tool.
--  @formal Input_Schema Returns the tool's JSON Schema for `inputSchema`, as
--    JSON *text* (an object).
--  @formal Invoke Executes a tools/call. `Arguments` is the request's
--    `params.arguments` object as raw JSON text -- "{}" when the client sent
--    none; the tool parses whatever fields it needs (with the application's
--    JSON library). Respond only ever calls this with Arguments'Length <=
--    Max_Field (its own precondition guarantees it), so a tool may take its
--    own Max_Field precondition and build a result straight from Arguments
--    while still upholding Invocation_Result's Len <= Max_Field predicate. A
--    PROCEDURE, not a function: a real tool mutates the application's Store
--    (save/forget/upload_session), and a SPARK function must be side-effect
--    free. The actual carries whatever Global it needs; because this package
--    is generic, that effect is re-analysed at each instantiation and stays
--    visible to flow analysis through Respond and Dispatch (the same mechanism
--    Spark_Mcp.Http.Serve relies on for its handler seam). The result is
--    handed out as an ownership allocation (Tools.Result_Ptr) -- the tool does
--    `Result := new Invocation_Result'(Success (...) | Failure (...))`;
--    Respond reads it once and Frees it. A conforming Invoke never returns
--    null.
--  @formal Parse_Envelope Decode one request's text into an Envelope, using
--    the application's JSON library. This is the ONE step that needs a parser;
--    keeping it a generic formal is what lets spark_mcp itself stay json-free
--    (see the Envelope vocabulary in Spark_Mcp.Requests). Defaults to
--    Requests.No_Parser, which reports Unimplemented (=> Internal_Error) -- so
--    the core builds and is testable with no JSON dependency; memcp supplies
--    the real parser at instantiation (see Memcp_Envelope).

with Spark_Mcp.Requests;
with Spark_Mcp.Tools;

generic
   Server_Name    : String;
   Server_Version : String;
   Instructions   : String;

   type Tool_Id is (<>);

   with function Name         (Id : Tool_Id) return String;
   with function Description   (Id : Tool_Id) return String;
   with function Input_Schema  (Id : Tool_Id) return String;

   with procedure Invoke
     (Id        : Tool_Id;
      Arguments : String;
      Result    : out Tools.Result_Ptr);

   with function Parse_Envelope
     (Request : String) return Requests.Envelope is Requests.No_Parser;

package Spark_Mcp.Server with SPARK_Mode => On is

   procedure Dispatch (Request : String; Response : out Response_Ptr);
   --  Handle one JSON-RPC 2.0 message and hand back the response text.
   --  Response is null for a notification (no `id`), which the transport drops
   --  (answering 204); otherwise it is an exactly-sized ownership allocation the
   --  caller sends and Frees. Never propagates an exception: malformed input
   --  becomes a JSON-RPC error response. This total shape is what makes the core
   --  testable in-process (drive Dispatch directly -- no socket -- mirroring how
   --  tests/test_server.py uses an in-process fastmcp.Client today).
   --
   --  A procedure, not a function, because a tools/call may mutate the Store
   --  (see the Invoke formal). Dispatch = parse the envelope (via the
   --  Parse_Envelope formal -- the one step that needs a JSON library) then
   --  Respond. With the default parser it reports Internal_Error; supply a real
   --  Parse_Envelope for a live Dispatch.
   --  @param Request The raw JSON-RPC 2.0 request text to handle.
   --  @param Response Out: null for a notification; otherwise an exactly-sized
   --    ownership allocation the caller sends and Frees.

   procedure Respond
     (Method          : String;
      Is_Notification : Boolean;
      Id              : String;
      Response        : out Response_Ptr;
      Tool_Name       : String := "";
      Arguments       : String := "{}")
   with
     Pre => Method'Length <= Max_Field
            and then Id'Length <= Max_Field
            and then Tool_Name'Length <= Max_Field
            and then Arguments'Length <= Max_Field;
   --  The pre-parsed core: route an already-decoded JSON-RPC request and build
   --  the response text. Exposed both for transports that have parsed the
   --  envelope themselves and, primarily, so the whole routing + response layer
   --  is testable without a JSON parser (see the AUnit suite).
   --  @param Method The JSON-RPC `method`.
   --  @param Is_Notification True => no response is owed; Response is null.
   --  @param Id The request's `id` as a verbatim JSON token ("42", "null", or a
   --    quoted string like """abc"""); echoed into the response. Ignored when
   --    Is_Notification.
   --  @param Response Out: null for a notification; otherwise an exactly-sized
   --    ownership allocation the caller Frees.
   --  @param Tool_Name For method "tools/call", params.name ("" otherwise).
   --  @param Arguments For method "tools/call", params.arguments as JSON text
   --    ("{}" when absent); ignored for other methods.

end Spark_Mcp.Server;
