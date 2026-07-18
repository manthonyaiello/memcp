--  Spark_Mcp.Http: SPARK binding to a minimal synchronous HTTP/1.1 server
--  (the Rust `tiny_http` crate), exposing a single blocking accept loop.
--
--  The concrete transport spark_mcp ships with. Its Ada is MCP-agnostic
--  (Serve is generic over the request handler), but the Rust side is shaped
--  for MCP-over-HTTP -- one route (POST /mcp), JSON-RPC 204 semantics -- so it
--  is not a general-purpose HTTP server and lives as a child of Spark_Mcp
--  rather than a standalone crate. The provable core (Spark_Mcp.Server) uses
--  nothing here; only a cargo build step joins the crate, not an Ada dep.
--
--  Chosen because tiny_http is synchronous -- no tokio/async runtime to drag
--  across the FFI. One endpoint (POST /mcp), no routing. Rust owns all socket
--  I/O and HTTP framing (the un-SPARK-able part stays in memory-safe Rust); the
--  Ada side receives the raw request body and returns the raw response body.
--  Rust never parses the JSON -- defense in depth.
--
--  Binding shape (see spark-memcp.planning.md): Ada owns `main` AND the
--  request loop -- the FFI is pull-based (open / next / read / respond), so
--  no Ada subprogram is ever called from Rust. That keeps elaboration
--  automatic (no adainit from Rust) and, crucially, keeps the dispatch call
--  inside SPARK: Serve's body is proved, and the callback's effects are
--  visible to flow analysis at each instantiation. Only the thin marshalling
--  bodies in the private Bridge package are trusted (SPARK_Mode => Off),
--  against the Pre/Post on their SPARK specs.
--
--  Network is the SPARK model of the socket world (peers act asynchronously,
--  hence External). It has a null refinement: its "constituents" live on the
--  other side of the FFI.

with Ada.Unchecked_Deallocation;

package Spark_Mcp.Http
  with SPARK_Mode => On,
       Abstract_State => ((Network with External)),
       Initializes    => Network,
       Elaborate_Body
is

   type Port_Number is range 1 .. 65_535;
   --  A valid TCP port the server may bind, excluding 0 (1 .. 65_535).

   type Message_Ptr is access String;
   --  Message buffers are SPARK ownership pointers, always allocated to the
   --  exact size of their content: Read_Body hands one out per request,
   --  On_Request hands one back per response, Serve frees both -- gnatprove
   --  discharges the leak/use-after-free obligations. No resident buffer,
   --  no size-capped copy, nothing is ever passed around but the bytes that
   --  exist.

   procedure Free is new Ada.Unchecked_Deallocation (String, Message_Ptr);
   --  Reclaims a message buffer, nulling the pointer that named it.

   Max_Message : constant := 64 * 1024 * 1024;
   --  Upper bound on REQUEST bodies, mirrored by MAX_BODY_BYTES in
   --  rust/src/lib.rs (Rust rejects larger requests with 413 before they
   --  reach Ada). Far below Natural'Last, so lengths convert without
   --  ceremony. Responses are unbounded -- they are exactly-sized
   --  allocations, not buffers.

   Transport_Error : exception;
   --  The only exception Serve can propagate (see its Exceptional_Cases):
   --  the port could not be bound, or the accept loop died.

end Spark_Mcp.Http;
