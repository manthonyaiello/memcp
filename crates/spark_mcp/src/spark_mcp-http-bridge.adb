--  SPARK body: the wrappers are PROVED against the spec's contracts. The
--  trusted base is only (a) the five C import declarations below -- their
--  Global/Side_Effects contracts are the formal statement of what
--  rust/src/lib.rs does -- and (b) Alloc_Uninit's single-statement body, the
--  crate's one SPARK_Mode=>Off escape hatch.
--
--  Data crosses the FFI as Ada arrays: RM B.3 passes an array to a
--  C-convention import as a pointer to its first element, so no 'Address
--  arithmetic appears anywhere.

with Interfaces.C;

package body Spark_Mcp.Http.Bridge
  with SPARK_Mode => On
is
   use type Interfaces.C.size_t;
   use type System.Address;

   --  Binds a socket: effectful, so a Side_Effects function (callable only
   --  as an assignment statement). Null on failure.
   function C_Server_New
     (Port : Interfaces.C.unsigned_short) return System.Address
     with Import, Convention => C, External_Name => "mcp_server_new",
          Side_Effects, Global => (In_Out => Network), Always_Terminates;

   --  Consumes socket traffic (answers 404/400/413 itself). Null when the
   --  accept loop is dead. Always_Terminates here means "returns once a
   --  request arrives or the loop dies" -- it blocks, it does not spin.
   function C_Next (Srv : System.Address) return System.Address
     with Import, Convention => C, External_Name => "mcp_next",
          Side_Effects, Global => (In_Out => Network), Always_Terminates;

   --  Pure query: the body of a pulled request is immutable, so its length
   --  is a function of the handle alone.
   function C_Body_Len (Req : System.Address) return Interfaces.C.size_t
     with Import, Convention => C, External_Name => "mcp_body_len",
          Global => null;

   --  Fills Dst (passed as pointer-to-first-element) with the request body;
   --  Rust writes exactly C_Body_Len bytes, never reads Dst.
   procedure C_Body_Read (Req : System.Address; Dst : out String)
     with Import, Convention => C, External_Name => "mcp_body_read",
          Global => (Input => Network), Always_Terminates;

   --  Sends the response (Len = 0 answers 204 without touching Data) and
   --  frees the request.
   procedure C_Respond
     (Req : System.Address; Data : String; Len : Interfaces.C.size_t)
     with Import, Convention => C, External_Name => "mcp_respond",
          Global => (In_Out => Network), Always_Terminates;

   --  THE escape hatch, scoped to one statement: SPARK forbids uninitialized
   --  allocators (String has no default initialization), but blank-filling a
   --  buffer C_Body_Read is about to overwrite in full would write every
   --  request body twice. Global => null is the trusted claim that the
   --  fresh allocation is wholly owned by Data (otherwise gnatprove
   --  generates a heap-memory effect from the Off body that an explicit
   --  Global upstream could not name). Sound because Read_Body passes the
   --  result to C_Body_Read on the very next statement, before any SPARK
   --  code can read it.
   --
   --  Relaxed_Initialization was evaluated (2026-07-13) and does not help on
   --  this toolchain: gnatprove 15.1 still rejects uninitialized allocators
   --  of relaxed types (E0019), and cross-unit use of an
   --  access-to-Relaxed_Initialization type ICEs gnat2why ("GNAT BUG
   --  DETECTED") even with initialized allocators. Revisit when the
   --  toolchain moves.
   procedure Alloc_Uninit (Length : Message_Length; Data : out Message_Ptr)
     with Post => Data /= null and then Data'Length = Length,
          Global => null, Always_Terminates;

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
               --  Rust caps bodies at Max_Message, so this cannot happen; if
               --  that invariant is ever broken, drop the request (204) and
               --  report the transport dead rather than construct a handle
               --  that violates Message_Length.
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
