--  Body exists only to carry Network's null refinement: the socket world has
--  no Ada-side constituents -- it lives across the FFI, in Rust.

package body Spark_Mcp.Http
  with SPARK_Mode    => On,
       Refined_State => (Network => null)
is
end Spark_Mcp.Http;
