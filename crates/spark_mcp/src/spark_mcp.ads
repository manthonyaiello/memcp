--  spark_mcp: a reusable, transport-agnostic MCP server core.
--
--  This crate owns the JSON-RPC 2.0 envelope and the MCP method layer
--  (initialize, tools/list, tools/call, ping) and NOTHING about HTTP, sockets,
--  or the concrete memcp tool set. It is json-free: outbound responses are
--  emitted as JSON *text* (Spark_Mcp.Writer), and inbound decoding is delegated
--  to a generic formal (Spark_Mcp.Server.Parse_Envelope) that the application
--  supplies with its own JSON library -- so this reusable core depends on no
--  JSON crate and can be built and proved independently.
--
--  The public contract with the transport is a single procedure:
--      Spark_Mcp.Server.Dispatch (Request : String; Response : out Response_Ptr)
--  bytes-in / bytes-out, UTF-8 JSON carried opaquely in a String. Freeze this
--  signature early -- it is the seam between the proven core and the un-proven
--  transport shim (the child package Spark_Mcp.Http). See
--  spark-memcp.planning.md.
--
--  Dispatch is a PROCEDURE, not a function: a tools/call ultimately runs a tool
--  that may mutate application state (memcp's save/forget write the Store), and
--  a SPARK function must be side-effect free. As a procedure it hands its result
--  back through an out parameter, and because Spark_Mcp.Server is generic the
--  tool's state effects are re-analysed (and stay visible to flow analysis) at
--  each instantiation. The result is an exactly-sized ownership allocation
--  (Response_Ptr below) rather than a returned String, because a procedure
--  cannot hand back an unconstrained String through a plain out parameter --
--  the same reason Spark_Mcp.Http.Serve's handler seam allocates.

with Ada.Unchecked_Deallocation;

package Spark_Mcp with SPARK_Mode => On is

   MCP_Protocol_Version : constant String := "2024-11-05";
   --  The MCP protocol revision this server advertises in `initialize`.
   --  "2024-11-05" is the widely-supported baseline; bump when clients need it.

   Max_Field : constant := Natural'Last / 8;
   --  Upper bound on the length of any single neutral text field carried across
   --  the seams: a request's Method/Id/Tool_Name/Arguments (Spark_Mcp.Requests)
   --  and a tool result's Content/Message (Spark_Mcp.Tools). It is Natural'Last
   --  / 8 -- about 256 MiB, far larger than any real MCP message -- chosen well
   --  below Natural'Last so that the fixed JSON framing, the echoed id, and the
   --  worst-case 6x string escaping (Spark_Mcp.Writer) in any single response
   --  can never overflow a String's Positive index. This headroom is what lets
   --  the routing body (Spark_Mcp.Server) be proved free of run-time errors: the
   --  bound is carried on the Envelope and Invocation_Result types (as
   --  predicates) and required of Respond's inputs (as a precondition), so every
   --  response-building concatenation is provably in range.

   type Error_Code is range -32768 .. 2 ** 31 - 1;
   --  JSON-RPC 2.0 reserved error codes (JSON-RPC 2.0 spec, section 5.1).

   Parse_Error      : constant Error_Code := -32700;
   --  Invalid JSON was received: the server could not parse the request text.
   Invalid_Request  : constant Error_Code := -32600;
   --  The JSON sent is not a well-formed JSON-RPC 2.0 Request object.
   Method_Not_Found : constant Error_Code := -32601;
   --  The requested method does not exist or is not available.
   Invalid_Params   : constant Error_Code := -32602;
   --  Invalid method parameters were supplied.
   Internal_Error   : constant Error_Code := -32603;
   --  An internal JSON-RPC server error occurred.

   type Response_Ptr is access String;
   --  A handed-out response body: a SPARK ownership pointer, allocated to the
   --  exact length of the response text. Spark_Mcp.Server.Dispatch (and the
   --  pre-parsed Respond) allocate one per request and pass ownership to the
   --  caller, which sends it and Frees it -- exactly the shape Spark_Mcp.Http's
   --  Message_Ptr uses on the transport side (they are distinct types in
   --  distinct child packages; the composition root moves between them). A **null**
   --  result means no response is owed -- a JSON-RPC notification -- so the
   --  transport can answer 204 without allocating anything.

   procedure Free is new Ada.Unchecked_Deallocation (String, Response_Ptr);
   --  Reclaim the String pointed to by a Response_Ptr once the transport has
   --  sent it, restoring the pointer to null.

end Spark_Mcp;
