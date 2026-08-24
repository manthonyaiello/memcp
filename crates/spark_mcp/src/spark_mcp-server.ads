--  The reusable MCP server, generic over an application's tool set: method
--  routing (initialize, tools/list, tools/call, ping), id echoing and error
--  framing. The tool seam is generic formals rather than
--  access-to-subprogram, so each instantiation re-analyses the tools' effects.
--
--  @formal Server_Name The MCP server name reported on initialize.
--  @formal Server_Version The MCP server version reported on initialize.
--  @formal Instructions Surfaced as the MCP `instructions` block on initialize.
--  @formal Tool_Id The application's tools, as a contiguous enumeration.
--    Tool_Id'Range is what tools/list enumerates.
--  @formal Name Returns the wire name of the given tool.
--  @formal Description Returns the human-readable description of the given
--    tool.
--  @formal Input_Schema Returns the tool's JSON Schema for `inputSchema`, as
--    JSON text (an object). This, the name and the description are jointly
--    bounded by Max_Tool_Item once escaped.
--  @formal Invoke Executes a tools/call. `Arguments` is params.arguments as raw
--    JSON text ("{}" when the client sent none), which the tool parses itself.
--    Respond calls it only with Arguments'Length <= Max_Field, so a tool may
--    take that precondition and build a result straight from Arguments. A
--    procedure, because a real tool mutates application state; it hands the
--    result out as `Result := new Invocation_Result'(...)`, which Respond reads
--    once and Frees. A conforming Invoke never returns null.
--  @formal Parse_Envelope Decode one request's text into an Envelope. The one
--    step that needs a JSON library, which is why it is a formal and has no
--    default: an instantiation with no parser to offer supplies one returning
--    Kind => Unimplemented, and Respond is drivable directly, so the crate
--    builds, proves and is tested with no JSON dependency at all.
--  @formal Client_Meta Extra members for the `initialize` result's `_meta`,
--    given params.clientInfo.name and .version as the client reported them.
--    Return "" to add none, otherwise a JSON object of at most Max_Field
--    characters; the text is embedded verbatim, on the same footing as
--    Input_Schema. A version string means nothing to this crate, so deciding
--    what to say about one is the application's, and there is no default: an
--    instantiation with nothing to say supplies a function returning "".

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
     (Request : String) return Requests.Envelope;

   with function Client_Meta
     (Client_Name, Client_Version : String) return String;

package Spark_Mcp.Server with SPARK_Mode => On is

   Max_Tool_Item : constant := 65_536;
   --  Upper bound on one tools/list item: the tool's name and description at
   --  worst-case 6x escaping, its inputSchema verbatim, and the enclosing
   --  object's framing. A tool whose metadata exceeds it leaves an unproved
   --  check at the instantiation.

   Max_Tools : constant := 256;
   --  Upper bound on the number of tools in Tool_Id. With Max_Tool_Item it
   --  bounds the whole listing by a static figure, so proving that bound costs
   --  the same whatever the tool set.

   pragma Compile_Time_Error
     (Tool_Id'Pos (Tool_Id'Last) - Tool_Id'Pos (Tool_Id'First) + 1 > Max_Tools,
      "tool set exceeds Spark_Mcp.Server.Max_Tools");
   --  Rejects an oversized tool set where it is written, since Tool_Id is a
   --  formal discrete type and nothing else stops an instantiation handing it
   --  one whose positions run to Integer'Last.

   procedure Dispatch (Request : String; Response : out Response_Ptr);
   --  Handle one JSON-RPC 2.0 message: Parse_Envelope, then Respond. Total --
   --  malformed input becomes a JSON-RPC error response rather than an exception
   --  -- so a caller needs no handler and the core is drivable in-process.
   --  @param Request The raw JSON-RPC 2.0 request text to handle.
   --  @param Response Out: null for a notification; otherwise an exactly-sized
   --    ownership allocation the caller sends and Frees.

   procedure Respond
     (Method          : String;
      Is_Notification : Boolean;
      Id              : String;
      Response        : out Response_Ptr;
      Tool_Name       : String := "";
      Arguments       : String := "{}";
      Client_Name     : String := "";
      Client_Version  : String := "")
   with
     Pre => Method'Length <= Max_Field
            and then Id'Length <= Max_Field
            and then Tool_Name'Length <= Max_Field
            and then Arguments'Length <= Max_Field
            and then Client_Name'Length <= Max_Field
            and then Client_Version'Length <= Max_Field;
   --  Route an already-decoded JSON-RPC request and build the response text.
   --  Exposed so the whole routing and response layer can be driven without a
   --  JSON parser.
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
   --  @param Client_Name For method "initialize", params.clientInfo.name ("" when
   --    absent); ignored for other methods.
   --  @param Client_Version For method "initialize", params.clientInfo.version
   --    ("" when absent); ignored for other methods.

end Spark_Mcp.Server;
