--  memcp's inbound envelope parser: decode one JSON-RPC 2.0 request's text into
--  the neutral Spark_Mcp.Requests.Envelope. This is the one step of the MCP
--  protocol that needs a JSON parser.

with Spark_Mcp.Requests;

package Memcp.Envelope with SPARK_Mode => On is

   function Parse_Envelope
     (Request : String) return Spark_Mcp.Requests.Envelope;
   --  Decode one JSON-RPC 2.0 request's text into an Envelope. Never raises:
   --  invalid JSON becomes Bad_Json, and well-formed JSON that is not JSON-RPC
   --  becomes Bad_Request.
   --  @param Request The raw text of one JSON-RPC 2.0 request.
   --  @return The decoded neutral Envelope, or a Bad_Json/Bad_Request envelope
   --  when the text is not valid JSON-RPC.

end Memcp.Envelope;
