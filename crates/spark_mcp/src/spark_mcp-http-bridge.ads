--  C trust seam of the transport: the Rust pull API (open, next, read, respond)
--  wrapped in SPARK contracts. The wrapper bodies are proved against these
--  contracts, so the Posts below are theorems; the trusted base is the five
--  imports in the body plus Alloc_Uninit's one statement.
--
--  What Rust is trusted for (rust/src/lib.rs): a live handle stays valid until
--  Respond, and its body bytes are stable and exactly Body_Length long; bodies
--  are capped at Max_Message, larger requests getting 413 before a handle
--  exists; Respond copies the response before returning, then frees the
--  request.

with System;

private package Spark_Mcp.Http.Bridge
  with SPARK_Mode => On
is

   type Server_Handle  is private;
   --  A listening socket, bound by Open.

   type Request_Handle is private;
   --  One pulled request, live until it is answered.

   function Is_Open (Server : Server_Handle) return Boolean;
   --  True once Open has bound the listening socket for this server.
   --  @param Server The server handle to query.
   --  @return True if the socket is bound and the server can accept requests.

   function Is_Live (Request : Request_Handle) return Boolean;
   --  True while a request still awaits a response: not yet consumed by
   --  Respond, and not a dead handle from an ended accept loop.
   --  @param Request The request handle to query.
   --  @return True if the request is live and may still be read or answered.

   function Body_Length (Request : Request_Handle) return Natural
     with Pre  => Is_Live (Request),
          Post => Body_Length'Result <= Max_Message;
   --  Length in bytes of the request body, capped at Max_Message.
   --  @param Request A live request whose body length is wanted.
   --  @return The exact body size, never exceeding Max_Message.

   procedure Open (Port : Port_Number; Server : out Server_Handle)
     with Global => (In_Out => Network);
   --  Bind 127.0.0.1:Port. Is_Open is False if the socket could not be bound.
   --  @param Port The TCP port to listen on.
   --  @param Server The resulting handle; Is_Open reports whether bind succeeded.

   procedure Next (Server : Server_Handle; Request : out Request_Handle)
     with Global => (In_Out => Network),
          Pre    => Is_Open (Server);
   --  Block until the next POST /mcp arrives; Rust answers 404/400/413 traffic
   --  itself and surfaces only real MCP requests. A dead Request means the
   --  accept loop ended and nothing further will arrive.
   --  @param Server An open server to accept the next request from.
   --  @param Request The next live request, or a dead handle if the loop ended.

   procedure Read_Body (Request : Request_Handle; Data : out Message_Ptr)
     with Global => (Input => Network),
          Pre    => Is_Live (Request),
          Post   => Data /= null
                    and then Data'Length = Body_Length (Request);
   --  Allocate a String of exactly Body_Length, fill it with the request body,
   --  and move ownership to the caller. One memcpy, no blank initialization.
   --  @param Request The live request whose body is copied out.
   --  @param Data An exactly-sized owned copy of the body; the caller frees it.

   procedure Respond (Request : in out Request_Handle; Data : String)
     with Global => (In_Out => Network),
          Pre    => Is_Live (Request),
          Post   => not Is_Live (Request);
   --  Send the response and release the request. Data = "" is a JSON-RPC
   --  notification, answered 204 with no body; otherwise 200 with Content-Type:
   --  application/json. Responses are not size-capped, only requests.
   --  @param Request The live request to answer; consumed, so no longer Is_Live.
   --  @param Data The response payload, or "" to send a 204 notification ack.

private

   subtype Message_Length is Natural range 0 .. Max_Message;
   --  Body sizes, so Body_Length's bound is a subtype fact Next proves when it
   --  constructs a handle rather than a trusted claim.

   type Server_Handle is record
      Ptr : System.Address := System.Null_Address;
      --  Raw address of the Rust-owned listener; null when unbound.
   end record;
   --  A listening socket, as the address of the Rust-owned listener.

   type Request_Handle is record
      Ptr : System.Address := System.Null_Address;
      --  Raw address of the Rust-owned request; null when dead.
      Len : Message_Length := 0;
      --  Cached body length, carrying Body_Length's bound.
   end record;
   --  One pulled request, as the address of the Rust-owned request plus its
   --  body length.

end Spark_Mcp.Http.Bridge;
