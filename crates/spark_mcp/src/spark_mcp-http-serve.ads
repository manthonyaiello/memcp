generic
   with procedure On_Request
     (Request  : String;
      Response : out Message_Ptr);
   --  Handles one decoded MCP request.
   --  @param Request The raw request body.
   --  @param Response The allocated response handed back to Serve (null or an
   --    empty allocation denotes a JSON-RPC notification, answered 204).
procedure Spark_Mcp.Http.Serve (Port : Port_Number)
  with SPARK_Mode        => On,
       Exceptional_Cases => (Transport_Error => True);
--  The blocking accept loop, generic over the request handler.
--
--  The seam is a formal PROCEDURE, not a function: dispatching an MCP request
--  mutates application state (save/forget write the store), and SPARK
--  functions must be side-effect free -- GNAT 15 accepts Side_Effects only on
--  plain function declarations, not on generic formals, and even then such a
--  function could not size an unconstrained result. As a procedure, the
--  actual may carry any Global contract; gnatprove re-analyzes Serve at each
--  instantiation, so the handler's effects are visible to flow analysis
--  exactly where the call happens -- in Serve's proven body, not hidden
--  behind a foreign callback.
--
--  On_Request allocates its response at exactly the right size and hands
--  ownership out through Response; Serve sends it and frees it (leak-freedom
--  is proved). null or an empty allocation means "" -- a JSON-RPC
--  notification, answered 204. There is no shared buffer, no size cap on
--  responses, and no length bookkeeping to get wrong: the allocation IS the
--  length.
--
--  Serve blocks forever serving POST /mcp on 127.0.0.1:Port. Its only exits
--  are the declared Transport_Error (port already bound, or the accept loop
--  died) -- see Exceptional_Cases: this is proved, not documented folklore.
--
--  Though a child of Spark_Mcp, this uses NOTHING from its parent -- the
--  handler is an abstract seam, so the transport stays MCP-agnostic. The
--  composition root (memcp) is what ties this to Spark_Mcp.Server.Dispatch.
--
--  @param Port The TCP port bound on 127.0.0.1 for POST /mcp.
