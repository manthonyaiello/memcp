generic
   with procedure On_Request
     (Request  : String;
      Response : out Message_Ptr);
   --  Handle one decoded MCP request.
   --  @param Request The raw request body.
   --  @param Response The allocated response handed back to Serve (null or an
   --    empty allocation denotes a JSON-RPC notification, answered 204).
   --
   --  For human readers only: gnatdoc cannot document a generic subprogram's
   --  formal in any spelling it accepts, so the doc gate carries an exact-match
   --  exception for the warning (TOOL_LIMITS in scripts/check-docs.sh). The tag
   --  meant for the job cannot even be named here -- gnatdoc parses it wherever
   --  it appears.
procedure Spark_Mcp.Http.Serve (Port : Port_Number)
  with SPARK_Mode        => On,
       Exceptional_Cases => (Transport_Error => True);
--  The blocking accept loop: bind 127.0.0.1:Port and serve POST /mcp forever,
--  handing each request body to On_Request and sending back what it allocates.
--  The handler seam is a generic formal rather than access-to-subprogram, so its
--  effects are re-analysed at each instantiation and stay visible to flow
--  analysis at the call site. Nothing here is MCP-specific.
--  @param Port The TCP port bound on 127.0.0.1 for POST /mcp.
