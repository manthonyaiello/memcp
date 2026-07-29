--  Spark_Mcp.Http: SPARK binding to a minimal synchronous HTTP/1.1 server (the
--  Rust `tiny_http` crate) serving one route, POST /mcp. This package holds the
--  transport's shared vocabulary; the accept loop is the child Serve.
--
--  Rust owns all socket I/O and HTTP framing and never parses the JSON; Ada owns
--  `main` and the request loop, so the FFI is pull-based (open, next, read,
--  respond) and nothing Ada is ever called from Rust.

with Ada.Unchecked_Deallocation;

package Spark_Mcp.Http
  with SPARK_Mode => On,
       --  Network models the socket world; its constituents are on the far side
       --  of the FFI, so the refinement is null.
       Abstract_State => ((Network with External)),
       Initializes    => Network,
       Elaborate_Body
is

   type Port_Number is range 1 .. 65_535;
   --  A valid TCP port the server may bind, excluding 0 (1 .. 65_535).

   type Message_Ptr is access String;
   --  A request or response body, allocated to the exact size of its content:
   --  the allocation is the length, so there is no resident buffer and no
   --  separate bookkeeping. Ownership crosses in both directions and Serve frees
   --  both ends.

   procedure Free is new Ada.Unchecked_Deallocation (String, Message_Ptr);
   --  Reclaim a message buffer, nulling the pointer that named it.

   Max_Message : constant := 64 * 1024 * 1024;
   --  Upper bound on request bodies, mirrored by MAX_BODY_BYTES in
   --  rust/src/lib.rs, which rejects a larger request with 413 before it reaches
   --  Ada. Responses are unbounded, being exactly-sized allocations.

   Transport_Error : exception;
   --  The port could not be bound, or the accept loop died.

end Spark_Mcp.Http;
