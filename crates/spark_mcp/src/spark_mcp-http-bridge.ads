--  Thin SPARK wrappers over the Rust pull API. Spec AND body are in SPARK:
--  the wrapper bodies are proved against these contracts, so the lifecycle
--  Posts below are theorems, not promises. The trusted base is reduced to
--  the five C import declarations in the body (whose Global/Side_Effects
--  claims describe rust/src/lib.rs) plus one single-statement escape hatch
--  (an uninitialized allocator, see Alloc_Uninit). No Ada subprogram is ever
--  called from Rust, so there are no exported symbols, no
--  access-to-subprogram values, and no callback whose caller SPARK cannot
--  see.
--
--  Handle lifecycle, enforced by proof in every SPARK caller:
--    Open  -> Is_Open (Server) or bind failed
--    Next  -> blocks; yields a live Request (or dead: transport ended)
--    Read_Body -> hands the caller OWNERSHIP of an exactly-sized copy of
--                 the body (the caller frees it; leak-freedom is proved)
--    Respond   -> consumes the Request (Post => not Is_Live)
--
--  The trusted claims (Rust side of the bargain, rust/src/lib.rs):
--    * a live handle stays valid until Respond, and its body bytes are
--      stable and exactly Body_Length long;
--    * bodies are capped at Max_Message (larger requests get 413 before a
--      handle is ever created);
--    * Respond copies the response before returning and frees the request.

with System;

private package Spark_Mcp.Http.Bridge
  with SPARK_Mode => On
is

   type Server_Handle  is private;
   type Request_Handle is private;

   function Is_Open (Server : Server_Handle) return Boolean;
   --  True once Open has bound the listening socket for this server.
   --  @param Server The server handle to query.
   --  @return True if the socket is bound and the server can accept requests.

   function Is_Live (Request : Request_Handle) return Boolean;
   --  True while a request handle is still awaiting a response (not yet
   --  consumed by Respond, and not a dead handle from an ended accept loop).
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
   --  Block until the next POST /mcp arrives; Rust answers 404/400/413
   --  traffic itself and only surfaces real MCP requests. A dead Request
   --  (not Is_Live) means the accept loop ended and no further request will
   --  ever arrive.
   --  @param Server An open server to accept the next request from.
   --  @param Request The next live request, or a dead handle if the loop ended.

   procedure Read_Body (Request : Request_Handle; Data : out Message_Ptr)
     with Global => (Input => Network),
          Pre    => Is_Live (Request),
          Post   => Data /= null
                    and then Data'Length = Body_Length (Request);
   --  Allocate a String of exactly Body_Length and fill it with the request
   --  body (a single memcpy in the trusted body -- no blank initialization,
   --  no oversized buffer). Ownership moves to the caller.
   --  @param Request The live request whose body is copied out.
   --  @param Data An exactly-sized owned copy of the body; the caller frees it.

   procedure Respond (Request : in out Request_Handle; Data : String)
     with Global => (In_Out => Network),
          Pre    => Is_Live (Request),
          Post   => not Is_Live (Request);
   --  Send the response and release the request. Data = "" is a JSON-RPC
   --  notification: Rust answers 204 with no body, otherwise 200 with
   --  Content-Type: application/json. Data is read for exactly its length;
   --  responses are not size-capped (only requests are).
   --  @param Request The live request to answer; consumed, so no longer Is_Live.
   --  @param Data The response payload, or "" to send a 204 notification ack.

private
   --  Full views: raw addresses of Rust-owned objects, modeled in SPARK as
   --  opaque values (System.Address is private; only null-comparison is
   --  used). Len's subtype makes Body_Length's bound a subtype fact rather
   --  than a trusted claim -- Next proves it when constructing the handle.

   subtype Message_Length is Natural range 0 .. Max_Message;
   --  Body sizes as a subtype, so Body_Length's bound is a subtype fact that
   --  Next proves when constructing a handle rather than a trusted claim.

   type Server_Handle is record
      Ptr : System.Address := System.Null_Address;
      --  Raw address of the Rust-owned listener; null when unbound.
   end record;
   --  Full view of a server handle: an opaque Rust listener address.

   type Request_Handle is record
      Ptr : System.Address := System.Null_Address;
      --  Raw address of the Rust-owned request; null when dead.
      Len : Message_Length := 0;
      --  Cached body length carrying Body_Length's proven bound.
   end record;
   --  Full view of a request handle: an opaque Rust request address plus its
   --  proven body length.

end Spark_Mcp.Http.Bridge;
