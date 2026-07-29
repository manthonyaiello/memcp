--  Spark_Mcp.Http body: no code of its own; it exists to refine Network.

package body Spark_Mcp.Http
  with SPARK_Mode    => On,
       Refined_State => (Network => null)
is
end Spark_Mcp.Http;
