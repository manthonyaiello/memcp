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

with Interfaces.C;
with Sqlite_Vec_Spark.Bridge;

package body Sqlite_Vec_Spark
  with SPARK_Mode    => On,
       Refined_State => (DBMS => null)
is
   use type Interfaces.C.int;
   use type Interfaces.C.size_t;
   use type System.Address;

   --  SQLite result / type codes we care about (sqlite3.h).
   SQLITE_OK         : constant := 0;
   SQLITE_BUSY       : constant := 5;
   SQLITE_CONSTRAINT : constant := 19;
   SQLITE_MISUSE     : constant := 21;
   SQLITE_ROW        : constant := 100;
   SQLITE_DONE       : constant := 101;
   SQLITE_NULL_TYPE  : constant := 5;   --  sqlite3_column_type value for NULL

   --  Reclaim the ownership token (see the private part note). Freeing it is
   --  what discharges the Needs_Reclamation obligation; it nulls its argument,
   --  so a closed/finalized handle is left in the reclaimed state.
   procedure Free_Token is
     new Ada.Unchecked_Deallocation (Boolean, Ownership_Token);

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
      Handle : System.Address;
      Rc     : Interfaces.C.int;
   begin
      DB.Handle := System.Null_Address;
      DB.Token  := null;

      --  vec0 must be registered before the connection is opened.
      declare
         Reg_Rc : Interfaces.C.int;
      begin
         Bridge.Register_Vec (Reg_Rc);
         if Reg_Rc /= SQLITE_OK then
            Result := Error;
            return;
         end if;
      end;

      --  Filename is NUL-terminated (open_v2 takes no length argument).
      Bridge.Open (Path => Path & ASCII.NUL, Db => Handle, Rc => Rc);

      if Rc /= SQLITE_OK then
         --  open may hand back a handle even on failure; close it.
         if Handle /= System.Null_Address then
            Bridge.Close_V2 (Handle);
         end if;
         Result := Error;
         return;
      end if;

      --  A success code with a null handle cannot happen with SQLite, but
      --  guarding it keeps the Post (Is_Open = (Result = Ok)) a theorem.
      if Handle = System.Null_Address then
         Result := Error;
         return;
      end if;

      DB.Handle := Handle;

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
           (Handle,
            "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;" & ASCII.NUL,
            Setup_Rc);
         if Setup_Rc /= SQLITE_OK then
            Bridge.Close_V2 (Handle);
            DB.Handle := System.Null_Address;
            Result := Error;
            return;
         end if;
         --  Fully open: take ownership. The token now shadows Handle's life.
         DB.Token := new Boolean'(True);
         Result := Ok;
      end;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (DB : in out Database) is
   begin
      if DB.Handle /= System.Null_Address then
         Bridge.Close_V2 (DB.Handle);
      end if;
      DB.Handle := System.Null_Address;
      --  Release the ownership token: this is the reclamation step. Idempotent
      --  -- Free_Token on a null token is a no-op -- so Close stays idempotent.
      Free_Token (DB.Token);
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
      Handle : System.Address;
      Rc     : Interfaces.C.int;
   begin
      Stmt.Handle := System.Null_Address;
      Stmt.Token  := null;
      Bridge.Prepare
        (Db    => DB.Handle,
         SQL   => SQL,
         Nbyte => Interfaces.C.int (SQL'Length),
         Stmt  => Handle,
         Rc    => Rc);

      if Rc = SQLITE_OK and then Handle /= System.Null_Address then
         Stmt.Handle := Handle;
         --  Compiled: take ownership. The token now shadows Handle's life.
         Stmt.Token  := new Boolean'(True);
         Result      := Ok;
      else
         --  A non-error code with a null handle (e.g. whitespace-only SQL)
         --  still means "no usable statement": report Error, not Ok.
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

   procedure Finalize (S : in out Statement) is
   begin
      if S.Handle /= System.Null_Address then
         Bridge.Finalize (S.Handle);
      end if;
      S.Handle := System.Null_Address;
      --  Release the ownership token: the reclamation step. Idempotent.
      Free_Token (S.Token);
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
     (Bridge.Column_Type (S.Handle, Interfaces.C.int (Col)) = SQLITE_NULL_TYPE);

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
