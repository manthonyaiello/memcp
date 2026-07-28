--  Wrapper body: proven-SPARK wrappers over the C trust seam, which lives
--  entirely in the child Sqlite_Vec_Spark.Bridge (see its spec). There is no
--  Import in this body -- every crossing of the SQLite/sqlite-vec C ABI goes
--  through Bridge, so this layer is all proof: it proves each Bridge call's Pre
--  and maps the raw result codes onto Status.
--
--  Strings cross as Ada arrays: RM B.3 passes an array to a C-convention import
--  as a pointer to its first element, so no 'Address arithmetic appears. Where
--  SQLite needs a NUL-terminated C string (open_v2, exec -- no length arg) the
--  wrapper appends ASCII.NUL; everywhere else it passes an explicit length and
--  no NUL (avoiding embedded-NUL surprises).
--
--  Because Database/Statement are limited (no copy), handle fields are mutated
--  component-wise (DB.Handle := ...), never by whole-record aggregate.
--
--  Handles are ownership types (see the spec's private part), which shapes the
--  two acquiring wrappers below: Open and Prepare hand their handle component
--  straight to the Bridge as the `out` parameter, rather than opening into a
--  local and copying it in on success. A copy would be a *move*, leaving the
--  local unreadable for the rest of the wrapper -- and the reason for the local
--  is gone anyway, since a handle that turns out to be unusable is released
--  through the very component it landed in. That release is unconditional on
--  every failure path: the shims tolerate an already-null pointer, and SPARK
--  knows nothing about which failures leave a resource behind, so reclaiming
--  always is both cheaper to prove and closer to what SQLite documents.

with Interfaces.C;
with Sqlite_Vec_Spark.Bridge;

package body Sqlite_Vec_Spark
  with SPARK_Mode    => On,
       Refined_State => (DBMS => null)
is
   use type Interfaces.C.int;
   use type Interfaces.C.size_t;

   --  SQLite result / type codes we care about (sqlite3.h).
   SQLITE_OK         : constant := 0;
   SQLITE_BUSY       : constant := 5;
   SQLITE_CONSTRAINT : constant := 19;
   SQLITE_MISUSE     : constant := 21;
   SQLITE_ROW        : constant := 100;
   SQLITE_DONE       : constant := 101;
   SQLITE_NULL_TYPE  : constant := 5;   --  sqlite3_column_type value for NULL

   ----------------------
   -- Local helpers --
   ----------------------

   --  Map a raw SQLite result code onto the Status subset. Total: any
   --  unrecognized code is Error.
   function To_Status (Rc : Interfaces.C.int) return Status is
     (case Rc is
         when SQLITE_OK         => Ok,
         when SQLITE_ROW        => Row,
         when SQLITE_DONE       => Done,
         when SQLITE_BUSY       => Busy,
         when SQLITE_CONSTRAINT => Constraint,
         when SQLITE_MISUSE     => Misuse,
         when others            => Error);

   --  THE escape hatch, scoped to one statement -- cloned from
   --  Spark_Mcp.Http.Bridge.Alloc_Uninit. SPARK forbids uninitialized
   --  allocators (String has no default initialization), but blank-filling a
   --  buffer Bridge.Column_Text_Copy is about to overwrite in full would write
   --  every column body twice. Global => null is the trusted claim that the
   --  fresh allocation is wholly owned by Data. Sound because Column_Text either
   --  leaves it empty (Length = 0) or fills it via Bridge.Column_Text_Copy on
   --  the next statement, before any SPARK code reads it.
   procedure Alloc_Uninit (Length : Natural; Data : out Text_Ptr)
     with Post => Data /= null and then Data'Length = Length,
          Global => null, Always_Terminates => True;

   procedure Alloc_Uninit (Length : Natural; Data : out Text_Ptr)
     with SPARK_Mode => Off
   is
   begin
      Data := new String (1 .. Length);
   end Alloc_Uninit;

   ----------
   -- Open --
   ----------

   procedure Open
     (DB     : out Database;
      Path   : String;
      Result : out Status)
   is
      Rc : Interfaces.C.int;
   begin
      --  vec0 must be registered before the connection is opened. This is the
      --  one path that returns without having called Bridge.Open, so it is also
      --  the one that has to establish the reclaimed handle itself.
      declare
         Reg_Rc : Interfaces.C.int;
      begin
         Bridge.Register_Vec (Reg_Rc);
         if Reg_Rc /= SQLITE_OK then
            DB.Handle := Handles.Null_Db_Handle;
            Result    := Error;
            return;
         end if;
      end;

      --  Filename is NUL-terminated (open_v2 takes no length argument).
      Bridge.Open (Path => Path & ASCII.NUL, Db => DB.Handle, Rc => Rc);

      --  Two failures in one branch: a genuine error code, and a success code
      --  with a null handle (which SQLite does not do, but which the Post
      --  (Is_Open = (Result = Ok)) has to rule out to be a theorem). Either way
      --  open_v2 may have left a connection behind -- it does so on some
      --  failures -- so Close unconditionally; it tolerates a null handle, and
      --  it is what discharges DB's ownership obligation on this path.
      if Rc /= SQLITE_OK or else not Is_Open (DB) then
         Bridge.Close (DB.Handle);
         Result := Error;
         return;
      end if;

      --  Per-connection setup, mirroring store.py's _conn: enforce foreign
      --  keys, enable WAL (a no-op on :memory:, which returns "memory", not an
      --  error). Both in one exec. A non-OK code here means the connection is
      --  not properly initialized, so treat it like an open failure -- close and
      --  report Error -- rather than serve on a half-configured connection.
      --  (In practice these PRAGMAs do not fail for a file or :memory:; the
      --  check also keeps the setup exec's DBMS effect live under the body's
      --  null refinement, where a discarded result would read as no effect.)
      declare
         Setup_Rc : Interfaces.C.int;
      begin
         Bridge.Exec
           (DB.Handle,
            "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;" & ASCII.NUL,
            Setup_Rc);
         if Setup_Rc /= SQLITE_OK then
            Bridge.Close (DB.Handle);
            Result := Error;
            return;
         end if;
         Result := Ok;
      end;
   end Open;

   -----------
   -- Close --
   -----------

   --  One call: releasing the connection and leaving DB reclaimed are the same
   --  step now, and Bridge.Close's Post is what says so. Idempotent, because
   --  the shim tolerates an already-null pointer.
   procedure Close (DB : in out Database) is
   begin
      Bridge.Close (DB.Handle);
   end Close;

   -------------
   -- Execute --
   -------------

   procedure Execute
     (DB     : Database;
      SQL    : String;
      Result : out Status)
   is
      Rc : Interfaces.C.int;
   begin
      Bridge.Exec (DB.Handle, SQL & ASCII.NUL, Rc);
      Result := (if Rc = SQLITE_OK then Ok else Error);
   end Execute;

   -----------------------
   -- Last_Insert_Rowid --
   -----------------------

   function Last_Insert_Rowid (DB : Database) return Interfaces.Integer_64 is
     (Bridge.Last_Insert_Rowid (DB.Handle));

   -------------
   -- Changes --
   -------------

   function Changes (DB : Database) return Natural is
      N : constant Interfaces.C.int := Bridge.Changes (DB.Handle);
   begin
      --  sqlite3_changes is non-negative; clamp defensively to stay total.
      return (if N <= 0 then 0 else Natural (N));
   end Changes;

   -------------
   -- Prepare --
   -------------

   procedure Prepare
     (DB     : Database;
      SQL    : String;
      Stmt   : out Statement;
      Result : out Status)
   is
      Rc : Interfaces.C.int;
   begin
      Bridge.Prepare
        (Db    => DB.Handle,
         SQL   => SQL,
         Nbyte => Interfaces.C.int (SQL'Length),
         Stmt  => Stmt.Handle,
         Rc    => Rc);

      if Rc = SQLITE_OK and then Is_Valid (Stmt) then
         Result := Ok;
      else
         --  No usable statement, either because prepare_v2 failed or because it
         --  succeeded with a null handle (whitespace-only SQL). prepare_v2 nulls
         --  its out handle on error, but nothing here relies on that: Finalize
         --  unconditionally, which tolerates a null handle and is what
         --  discharges Stmt's ownership obligation on this path.
         Bridge.Finalize (Stmt.Handle);
         Result := To_Status (Rc);
         if Result = Ok then
            Result := Error;
         end if;
      end if;
   end Prepare;

   ---------------
   -- Bind_Text --
   ---------------

   procedure Bind_Text
     (S : Statement; Index : Positive; Value : String; Result : out Status)
   is
      Rc : Interfaces.C.int;
   begin
      Bridge.Bind_Text
        (Stmt => S.Handle,
         Idx  => Interfaces.C.int (Index),
         Text => Value,
         Len  => Interfaces.C.int (Value'Length),
         Rc   => Rc);
      Result := To_Status (Rc);
   end Bind_Text;

   ----------------
   -- Bind_Int64 --
   ----------------

   procedure Bind_Int64
     (S      : Statement;
      Index  : Positive;
      Value  : Interfaces.Integer_64;
      Result : out Status)
   is
      Rc : Interfaces.C.int;
   begin
      Bridge.Bind_Int64 (S.Handle, Interfaces.C.int (Index), Value, Rc);
      Result := To_Status (Rc);
   end Bind_Int64;

   ---------------
   -- Bind_Blob --
   ---------------

   procedure Bind_Blob
     (S      : Statement;
      Index  : Positive;
      Data   : Ada.Streams.Stream_Element_Array;
      Result : out Status)
   is
      Rc : Interfaces.C.int;
   begin
      Bridge.Bind_Blob
        (Stmt => S.Handle,
         Idx  => Interfaces.C.int (Index),
         Data => Data,
         Len  => Interfaces.C.int (Data'Length),
         Rc   => Rc);
      Result := To_Status (Rc);
   end Bind_Blob;

   ---------------
   -- Bind_Null --
   ---------------

   procedure Bind_Null
     (S : Statement; Index : Positive; Result : out Status)
   is
      Rc : Interfaces.C.int;
   begin
      Bridge.Bind_Null (S.Handle, Interfaces.C.int (Index), Rc);
      Result := To_Status (Rc);
   end Bind_Null;

   ----------
   -- Step --
   ----------

   procedure Step (S : Statement; Result : out Status) is
      Rc : Interfaces.C.int;
   begin
      Bridge.Step (S.Handle, Rc);
      Result := To_Status (Rc);
   end Step;

   -----------
   -- Reset --
   -----------

   procedure Reset (S : Statement; Result : out Status) is
      Rc : Interfaces.C.int;
   begin
      Bridge.Reset (S.Handle, Rc);
      Result := To_Status (Rc);
   end Reset;

   --------------
   -- Finalize --
   --------------

   --  As with Close: one call, and Bridge.Finalize's Post is the reclamation.
   procedure Finalize (S : in out Statement) is
   begin
      Bridge.Finalize (S.Handle);
   end Finalize;

   ------------------
   -- Column_Int64 --
   ------------------

   function Column_Int64
     (S : Statement; Col : Natural) return Interfaces.Integer_64 is
     (Bridge.Column_Int64 (S.Handle, Interfaces.C.int (Col)));

   -------------------
   -- Column_Double --
   -------------------

   function Column_Double
     (S : Statement; Col : Natural) return Interfaces.IEEE_Float_64 is
     (Bridge.Column_Double (S.Handle, Interfaces.C.int (Col)));

   --------------------
   -- Column_Is_Null --
   --------------------

   function Column_Is_Null (S : Statement; Col : Natural) return Boolean is
      --  Capture the volatile read into a local: DBMS has Async_Writers, so the
      --  Bridge.Column_Type call may appear only in a non-interfering context,
      --  not as an operand of "=".
      Kind : constant Interfaces.C.int :=
        Bridge.Column_Type (S.Handle, Interfaces.C.int (Col));
   begin
      return Kind = SQLITE_NULL_TYPE;
   end Column_Is_Null;

   -----------------
   -- Column_Text --
   -----------------

   function Column_Text (S : Statement; Col : Natural) return Text_Ptr is
      Raw    : constant Interfaces.C.size_t :=
        Bridge.Column_Text_Len (S.Handle, Interfaces.C.int (Col));
      --  Clamp the size_t to Natural for the allocation. A text column larger
      --  than Natural'Last (~2 GiB) is not a real memcp value; the clamp is an
      --  AoRTE guard that never fires in practice.
      Length : constant Natural :=
        (if Raw > Interfaces.C.size_t (Natural'Last)
         then Natural'Last
         else Natural (Raw));
      Data   : Text_Ptr;
   begin
      Alloc_Uninit (Length, Data);
      if Length > 0 then
         Bridge.Column_Text_Copy
           (Stmt => S.Handle,
            Col  => Interfaces.C.int (Col),
            Dst  => Data.all,
            Len  => Interfaces.C.size_t (Length));
      end if;
      return Data;
   end Column_Text;

end Sqlite_Vec_Spark;
