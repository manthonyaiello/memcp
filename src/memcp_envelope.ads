--  memcp's concrete inbound envelope parser: the json-based implementation of
--  spark_mcp's Parse_Envelope generic formal.
--
--  spark_mcp is deliberately json-free -- it owns the MCP method layer and all
--  response framing, but delegates the ONE step that needs a JSON parser (turn
--  request text into {method, id, tool name, arguments}) to the application.
--  This is that step, living in the composition root where the json crate is
--  pinned. It decodes with json (v7) and returns spark_mcp's neutral
--  Spark_Mcp.Requests.Envelope; memcp.adb wires it in at instantiation.

with Spark_Mcp.Requests;

package Memcp_Envelope with SPARK_Mode => On is

   function Parse_Envelope
     (Request : String) return Spark_Mcp.Requests.Envelope;
   --  Decode one JSON-RPC 2.0 request's text into an Envelope. Never raises:
   --  invalid JSON becomes Bad_Json, a well-formed-JSON-but-not-JSON-RPC
   --  message becomes Bad_Request, and Spark_Mcp.Server.Dispatch frames the
   --  matching error response. This is the shape Dispatch's contract requires.
   --  @param Request The raw text of one JSON-RPC 2.0 request.
   --  @return The decoded neutral Envelope, or a Bad_Json/Bad_Request envelope
   --  when the text is not valid JSON-RPC.

end Memcp_Envelope;
