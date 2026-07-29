--  Proven-SPARK wrappers over the SQLite / sqlite-vec C ABI.

with Interfaces.C;
with Sqlite_Vec_Spark.Bridge;

package body Sqlite_Vec_Spark
  with SPARK_Mode    => On,
       Refined_State => (DBMS => null)
is
   use type Interfaces.C.int;
   use type Interfaces.C.size_t;

   SQLITE_OK         : constant := 0;
   --  sqlite3 value signaling the operation succeeded.

   SQLITE_BUSY       : constant := 5;
   --  sqlite3 value signaling the database is locked by another connection.

   SQLITE_CONSTRAINT : constant := 19;
   --  sqlite3 value indicating that a constraint was violated (e.g. UNIQUE,
   --  NOT NULL).

   SQLITE_MISUSE     : constant := 21;
   --  sqlite3 value indicating that the SQLite API was used incorrectly.

   SQLITE_ROW        : constant := 100;
   --  sqlite3 value indicating that a step produced a result row to read with
   --  the Column_* functions.

   SQLITE_DONE       : constant := 101;
   --  sqlite3 value indicating that a step reached the end of the result set.

   SQLITE_NULL_TYPE  : constant := 5;
   --  sqlite3_column_type value for NULL

   ----------------------
   -- Local helpers --
   ----------------------

   function To_Status (Rc : Interfaces.C.int) return Status is
     (case Rc is
         when SQLITE_OK         => Ok,
         when SQLITE_ROW        => Row,
         when SQLITE_DONE       => Done,
         when SQLITE_BUSY       => Busy,
         when SQLITE_CONSTRAINT => Constraint,
         when SQLITE_MISUSE     => Misuse,
         when others            => Error);
   --  Map a raw SQLite result code onto Status; unrecognized codes are Error.

   procedure Alloc_Uninit (Length : Natural; Data : out Text_Ptr)
     with Post => Data /= null and then Data'Length = Length,
          Global => null, Always_Terminates => True;
   --  Allocate without blank-filling, avoiding a second write of every column
   --  body: Bridge.Column_Text_Copy overwrites the buffer in full. Sound
   --  because Column_Text either leaves it empty (Length = 0) or fills it
   --  before any SPARK code reads it; Global => null claims the allocation is
   --  owned by Data.
   --  @param Length Character count to allocate; may be zero.
   --  @param Data The fresh allocation, exactly Length characters, whose
   --    contents are undefined until the caller writes them.

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
      --  vec0 must be registered before the connection is opened. The only path
      --  that returns without calling Bridge.Open, so it nulls the handle itself.
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

      Bridge.Open (Path => Path & ASCII.NUL, Db => DB.Handle, Rc => Rc);

      --  Two failures in one branch: an error code, and an OK code with a null
      --  handle (SQLite does not do this, but the Post has to rule it out).
      --  Close unconditionally: open_v2 can leave a connection behind on
      --  failure, and Close tolerates a null handle.
      if Rc /= SQLITE_OK or else not Is_Open (DB) then
         Bridge.Close (DB.Handle);
         Result := Error;
         return;
      end if;

      --  Per-connection setup: enforce foreign keys, enable WAL (a no-op on
      --  :memory:, which returns "memory", not an error). A non-OK code leaves a
      --  half-configured connection, so treat it like an open failure.
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
         --  No usable statement: prepare_v2 failed, or succeeded with a null
         --  handle (whitespace-only SQL). Finalize unconditionally rather than
         --  rely on prepare_v2 nulling its out handle; it tolerates a null
         --  handle.
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
      Kind : constant Interfaces.C.int :=
        Bridge.Column_Type (S.Handle, Interfaces.C.int (Col));
      --  Kind, the volatile read captured into a local: Bridge.Column_Type
      --  cannot appear as an operand of "=".
   begin
      return Kind = SQLITE_NULL_TYPE;
   end Column_Is_Null;

   -----------------
   -- Column_Text --
   -----------------

   function Column_Text (S : Statement; Col : Natural) return Text_Ptr is
      Raw    : constant Interfaces.C.size_t :=
        Bridge.Column_Text_Len (S.Handle, Interfaces.C.int (Col));

      Length : constant Natural :=
        (if Raw > Interfaces.C.size_t (Natural'Last)
         then Natural'Last
         else Natural (Raw));
      --  Length, clamped from size_t to Natural for the allocation: an AoRTE
      --  guard for a text column larger than Natural'Last (~2 GiB).

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
