--  spark_mcp: a reusable, transport-agnostic MCP server core. This root package
--  holds the constants and pointer type shared across the crate; the JSON-RPC
--  2.0 envelope and MCP method layer live in the children. Nothing here knows
--  about HTTP, sockets or any concrete tool set, and the crate depends on no
--  JSON library: responses are emitted as text, and request decoding is a
--  generic formal.

with Ada.Unchecked_Deallocation;

package Spark_Mcp with SPARK_Mode => On is

   MCP_Protocol_Version : constant String := "2024-11-05";
   --  The MCP protocol revision this server advertises in `initialize`.
   --  "2024-11-05" is the widely-supported baseline; bump when clients need it.

   Max_Field : constant := Natural'Last / 8;
   --  Upper bound on any single neutral text field crossing the crate's seams.
   --  The eighth is headroom, not a size limit: JSON framing, the echoed id and
   --  worst-case 6x string escaping must all fit a String's Positive index, and
   --  that is what makes response building provably free of overflow.

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
   --  A handed-out response body, allocated to the exact length of the response
   --  text. Ownership passes to the caller, which sends it and Frees it. Null
   --  means no response is owed -- a JSON-RPC notification -- so nothing is
   --  allocated for one.

   procedure Free is new Ada.Unchecked_Deallocation (String, Response_Ptr);
   --  Reclaim a Response_Ptr's String, leaving the pointer null.

end Spark_Mcp;
