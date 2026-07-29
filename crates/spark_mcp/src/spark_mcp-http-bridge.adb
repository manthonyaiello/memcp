--  Proven-SPARK wrappers over the five imports below, whose contracts are the
--  formal statement of what rust/src/lib.rs does. Request bodies and response
--  payloads cross the FFI as Ada arrays, so no 'Address arithmetic appears
--  anywhere.

with Interfaces.C;

package body Spark_Mcp.Http.Bridge
  with SPARK_Mode => On
is
   use type Interfaces.C.size_t;
   use type System.Address;

   function C_Server_New
     (Port : Interfaces.C.unsigned_short) return System.Address
     with Import, Convention => C, External_Name => "mcp_server_new",
          Side_Effects, Global => (In_Out => Network), Always_Terminates;
   --  Bind 127.0.0.1:Port: `Server *mcp_server_new (unsigned short port)`.
   --  @param Port The TCP port to listen on.
   --  @return The Rust-owned listener, or null if the bind failed.

   function C_Next (Srv : System.Address) return System.Address
     with Import, Convention => C, External_Name => "mcp_next",
          --  Always_Terminates: it blocks, returning once a request arrives or
          --  the accept loop dies. It does not spin.
          Side_Effects, Global => (In_Out => Network), Always_Terminates;
   --  Pull the next MCP request: `McpRequest *mcp_next (Server *server)`. Rust
   --  consumes the 404/400/413 traffic itself.
   --  @param Srv The listener to accept from.
   --  @return The Rust-owned request, or null once the accept loop is dead.

   function C_Body_Len (Req : System.Address) return Interfaces.C.size_t
     with Import, Convention => C, External_Name => "mcp_body_len",
          Global => null;
   --  Byte length of the request body: `size_t mcp_body_len (const McpRequest
   --  *req)`. The body of a pulled request is immutable, so its length is a
   --  function of the handle alone.
   --  @param Req A live request.
   --  @return The body's exact size in bytes.

   procedure C_Body_Read (Req : System.Address; Dst : out String)
     with Import, Convention => C, External_Name => "mcp_body_read",
          Global => (Input => Network), Always_Terminates;
   --  Copy the request body out: `void mcp_body_read (const McpRequest *req,
   --  uint8_t *dst)`. Rust writes exactly C_Body_Len bytes and never reads Dst.
   --  @param Req A live request.
   --  @param Dst The buffer the body is written into, sized by C_Body_Len.

   procedure C_Respond
     (Req : System.Address; Data : String; Len : Interfaces.C.size_t)
     with Import, Convention => C, External_Name => "mcp_respond",
          Global => (In_Out => Network), Always_Terminates;
   --  Answer and free the request: `void mcp_respond (McpRequest *req, const
   --  uint8_t *data, size_t len)`.
   --  @param Req The live request, freed by the call.
   --  @param Data The response payload; untouched when Len is 0.
   --  @param Len Byte length of the payload; 0 answers 204.

   procedure Alloc_Uninit (Length : Message_Length; Data : out Message_Ptr)
     with Post => Data /= null and then Data'Length = Length,
          Global => null, Always_Terminates;
   --  Allocate an uninitialized String of Length characters. The one escape
   --  hatch, scoped to a single statement: SPARK forbids uninitialized
   --  allocators, and blank-filling a buffer C_Body_Read overwrites in full
   --  would write every request body twice. Global => null is the trusted claim
   --  that the fresh allocation is wholly owned by Data. Sound only because
   --  Read_Body hands the result to C_Body_Read on the very next statement,
   --  before any SPARK code can read it.
   --  @param Length Length of the allocation, in characters.
   --  @param Data The fresh allocation, owned by the caller.

   procedure Alloc_Uninit (Length : Message_Length; Data : out Message_Ptr)
     with SPARK_Mode => Off
   is
   begin
      Data := new String (1 .. Length);
   end Alloc_Uninit;

   function Is_Open (Server : Server_Handle) return Boolean is
     (Server.Ptr /= System.Null_Address);

   function Is_Live (Request : Request_Handle) return Boolean is
     (Request.Ptr /= System.Null_Address);

   function Body_Length (Request : Request_Handle) return Natural is
     (Request.Len);

   ----------
   -- Open --
   ----------

   procedure Open (Port : Port_Number; Server : out Server_Handle) is
      P : System.Address;
   begin
      P := C_Server_New (Interfaces.C.unsigned_short (Port));
      Server := (Ptr => P);
   end Open;

   ----------
   -- Next --
   ----------

   procedure Next (Server : Server_Handle; Request : out Request_Handle) is
      P : System.Address;
   begin
      Request := (Ptr => System.Null_Address, Len => 0);
      P := C_Next (Server.Ptr);
      if P /= System.Null_Address then
         declare
            L : constant Interfaces.C.size_t := C_Body_Len (P);
         begin
            if L <= Interfaces.C.size_t (Max_Message) then
               Request := (Ptr => P, Len => Natural (L));
            else
               --  Rust caps bodies at Max_Message, so this is unreachable; if
               --  that ever breaks, drop the request (204) and report the
               --  transport dead rather than build a handle that violates
               --  Message_Length.
               C_Respond (P, "", 0);
            end if;
         end;
      end if;
   end Next;

   ---------------
   -- Read_Body --
   ---------------

   procedure Read_Body (Request : Request_Handle; Data : out Message_Ptr) is
   begin
      Alloc_Uninit (Request.Len, Data);
      if Request.Len > 0 then
         C_Body_Read (Request.Ptr, Data.all);
      end if;
   end Read_Body;

   -------------
   -- Respond --
   -------------

   procedure Respond (Request : in out Request_Handle; Data : String) is
   begin
      C_Respond (Request.Ptr, Data, Interfaces.C.size_t (Data'Length));
      Request := (Ptr => System.Null_Address, Len => 0);
   end Respond;

end Spark_Mcp.Http.Bridge;
