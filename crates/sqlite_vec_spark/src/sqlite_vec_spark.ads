--  sqlite_vec_spark: SPARK binding to SQLite3 and the sqlite-vec extension.
--
--  Primitives only: open/close a connection, run SQL, the prepared-statement
--  lifecycle (prepare/bind/step/column/reset/finalize), and registration of
--  sqlite-vec so `vec0` virtual tables and `embedding MATCH ? ORDER BY distance`
--  work. No schema, record types or application SQL live here. Both C libraries
--  compile straight into this Ada library; there is no system libsqlite3
--  dependency.

with Ada.Streams;
with Ada.Unchecked_Deallocation;
with Interfaces;

package Sqlite_Vec_Spark
  with SPARK_Mode     => On,
       Abstract_State => (DBMS with External => (Async_Writers    => True,
                                                 Async_Readers    => True,
                                                 Effective_Writes => True,
                                                 Effective_Reads  => False)),
       --  model the SQLite subsystem's state on the far side of the C
       --  boundary.
       Initializes    => DBMS
is

   type Database is limited private
     with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
          Default_Initial_Condition =>
            not Is_Open (Database) and then Is_Reclaimed (Database);
   --  Opaque database connection handle.

   type Statement is limited private
     with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
          Default_Initial_Condition =>
            not Is_Valid (Statement) and then Is_Reclaimed (Statement);
   --  Opaque prepared-statement handle.

   type Status is (Ok, Error, Row, Done, Busy, Constraint, Misuse);
   --  The subset of SQLite result codes this layer distinguishes; any other
   --  code maps to Error.
   --  @enum Ok The operation succeeded.
   --  @enum Error A generic SQLite error (any code not otherwise distinguished).
   --  @enum Row Step produced a result row to read with the Column_* functions.
   --  @enum Done Step reached the end of the result set.
   --  @enum Busy The database is locked by another connection.
   --  @enum Constraint A constraint was violated (e.g. UNIQUE, NOT NULL).
   --  @enum Misuse The SQLite API was used incorrectly.

   type Text_Ptr is access String;
   --  Caller-owned text pulled from a column, allocated to exactly the column's
   --  byte length; the caller frees it with Free. gnatprove tracks the
   --  ownership, so a dropped Text_Ptr is a proof error, not a silent leak.

   procedure Free is new Ada.Unchecked_Deallocation (String, Text_Ptr);
   --  Reclaim a Text_Ptr returned by Column_Text.

   function Is_Open  (DB : Database)  return Boolean;
   --  True when DB names an open connection.
   --  @param DB The connection handle to test.
   --  @return True iff DB is open.
   function Is_Valid (S  : Statement) return Boolean;
   --  True when S names a live (not yet finalized) prepared statement.
   --  @param S The statement handle to test.
   --  @return True iff S is valid.

   function Is_Reclaimed (DB : Database) return Boolean
     with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
   --  Reclamation predicate for Database: a closed connection holds no C
   --  resource.
   --  @param DB The connection handle to test.
   --  @return True iff DB owns no connection (equivalently, not Is_Open (DB)).

   function Is_Reclaimed (S : Statement) return Boolean
     with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
   --  Reclamation predicate for Statement: a finalized statement holds no C
   --  resource.
   --  @param S The statement handle to test.
   --  @return True iff S owns no statement (equivalently, not Is_Valid (S)).

   Max_Blob_Bytes : constant := 2 ** 31 - 1;
   --  SQLite's bind-length ABI is a C int, so a single bound value cannot
   --  exceed this. String-valued binds inherit the equivalent bound from
   --  String'Length <= Integer'Last.

   ---------------------
   -- Connection life --
   ---------------------

   procedure Open
     (DB     : out Database;
      Path   : String;
      Result : out Status)
     with Pre    => Path'Length > 0 and then Path'Last < Natural'Last,
          Post   => (Is_Open (DB) = (Result = Ok))
                    and then (Is_Reclaimed (DB) = (Result /= Ok)),
          Global => (In_Out => DBMS);
   --  Open (or create) the database at Path, registering sqlite-vec first so
   --  the connection has vec0, then enforcing foreign keys and enabling WAL
   --  journalling. Is_Open (DB) iff Result = Ok; on failure DB is closed and
   --  must not be used.
   --  @param DB The connection handle, set open on success.
   --  @param Path Filesystem path to the database file to open or create.
   --  @param Result Ok on success, or an error code.

   procedure Close (DB : in out Database)
     with Post    => not Is_Open (DB) and then Is_Reclaimed (DB),
          Global  => (In_Out => DBMS),
          Depends => (DBMS =>+ null, DB => null, null => DB);
   --  Close the connection (sqlite3_close_v2 via the shim, which tolerates
   --  unfinalized statements). Idempotent; leaves DB not-open.
   --  The explicit Depends -- DB's new value is a constant, its old handle
   --  reaching only the C side -- keeps callers that drop a closed Database free
   --  of "set but not used" flow warnings.
   --  @param DB The connection to close; left not-open.

   procedure Execute
     (DB     : Database;
      SQL    : String;
      Result : out Status)
     with Pre    => Is_Open (DB)
                    and then SQL'Length > 0
                    and then SQL'Last < Natural'Last,
          Global => (In_Out => DBMS);
   --  Run one or more statements with no result rows (DDL scripts, INSERT,
   --  DELETE, PRAGMA ...), via sqlite3_exec. Result is Ok or Error.
   --  @param DB The open connection to run SQL on.
   --  @param SQL One or more SQL statements producing no result rows.
   --  @param Result Ok on success, or Error.

   function Last_Insert_Rowid (DB : Database) return Interfaces.Integer_64
     with Pre => Is_Open (DB),
          Volatile_Function, Global => (Input => DBMS);
   --  Rowid of the most recent successful INSERT on DB
   --  (sqlite3_last_insert_rowid). Meaningful only straight after that INSERT's
   --  Step returned Done.
   --  @param DB The open connection to query.
   --  @return The rowid of the most recent successful INSERT on DB.

   function Changes (DB : Database) return Natural
     with Pre => Is_Open (DB),
          Volatile_Function, Global => (Input => DBMS);
   --  Rows changed by the most recent INSERT/UPDATE/DELETE (sqlite3_changes).
   --  @param DB The open connection to query.
   --  @return The number of rows changed by the last INSERT/UPDATE/DELETE.

   -------------------------
   -- Statement lifecycle --
   -------------------------

   procedure Prepare
     (DB     : Database;
      SQL    : String;
      Stmt   : out Statement;
      Result : out Status)
     with Pre    => Is_Open (DB) and then SQL'Length > 0,
          Post   => (Is_Valid (Stmt) = (Result = Ok))
                    and then (Is_Reclaimed (Stmt) = (Result /= Ok)),
          Global => (In_Out => DBMS);
   --  Compile one SQL statement (sqlite3_prepare_v2). Is_Valid (Stmt) iff
   --  Result = Ok; a valid Stmt must eventually be Finalize'd. Stmt holds a
   --  pointer into DB, so DB must outlive Stmt -- unenforceable in SPARK.
   --  @param DB The open connection; must outlive Stmt.
   --  @param SQL A single SQL statement to compile.
   --  @param Stmt The compiled statement, valid on success.
   --  @param Result Ok on success, or an error code.

   procedure Bind_Text
     (S : Statement; Index : Positive; Value : String; Result : out Status)
     with Pre => Is_Valid (S), Global => (In_Out => DBMS);
   --  Bind text to parameter Index (1-based, as in sqlite3_bind_*). Text and
   --  blob binds are copied by SQLite (SQLITE_TRANSIENT), so the Ada argument
   --  need not outlive the call.
   --  @param S The valid statement to bind on.
   --  @param Index The 1-based parameter index.
   --  @param Value The text value to bind.
   --  @param Result Ok on success, or an error code.

   procedure Bind_Int64
     (S      : Statement;
      Index  : Positive;
      Value  : Interfaces.Integer_64;
      Result : out Status)
     with Pre => Is_Valid (S), Global => (In_Out => DBMS);
   --  Bind a 64-bit integer to parameter Index (1-based).
   --  @param S The valid statement to bind on.
   --  @param Index The 1-based parameter index.
   --  @param Value The integer value to bind.
   --  @param Result Ok on success, or an error code.

   procedure Bind_Blob
     (S      : Statement;
      Index  : Positive;
      Data   : Ada.Streams.Stream_Element_Array;
      Result : out Status)
     with Pre    => Is_Valid (S) and then Data'Length <= Max_Blob_Bytes,
          Global => (In_Out => DBMS);
   --  Bind a blob; a packed float vector for a vec0 column lands here. Copied
   --  by SQLite, as for Bind_Text.
   --  @param S The valid statement to bind on.
   --  @param Index The 1-based parameter index.
   --  @param Data The raw bytes to bind as a blob.
   --  @param Result Ok on success, or an error code.

   procedure Bind_Null
     (S : Statement; Index : Positive; Result : out Status)
     with Pre => Is_Valid (S), Global => (In_Out => DBMS);
   --  Bind SQL NULL to parameter Index (1-based).
   --  @param S The valid statement to bind on.
   --  @param Index The 1-based parameter index.
   --  @param Result Ok on success, or an error code.

   procedure Step (S : Statement; Result : out Status)
     with Pre => Is_Valid (S), Global => (In_Out => DBMS);
   --  Advance the statement (sqlite3_step). Result = Row when a row is
   --  available (read it with the Column_* functions before the next Step),
   --  Done at end of result set, or an error/Busy code.
   --  @param S The valid statement to advance.
   --  @param Result Row, Done, or an error/Busy code.

   procedure Reset (S : Statement; Result : out Status)
     with Pre => Is_Valid (S), Global => (In_Out => DBMS);
   --  Reset a stepped statement back to its initial state so it can be
   --  re-stepped (sqlite3_reset); bindings are preserved. Result carries any
   --  error deferred from the previous run.
   --  @param S The valid statement to reset.
   --  @param Result Ok, or an error deferred from the previous run.

   procedure Finalize (S : in out Statement)
     with Post    => not Is_Valid (S) and then Is_Reclaimed (S),
          Global  => (In_Out => DBMS),
          Depends => (DBMS =>+ null, S => null, null => S);
   --  Destroy the statement (sqlite3_finalize). Idempotent; leaves S not-valid.
   --  The explicit Depends -- S's new value is a constant, its old handle
   --  reaching only the C side -- keeps callers that finalize a local Statement
   --  free of "set but not used" flow warnings.
   --  @param S The statement to finalize; left not-valid.

   ------------------
   -- Column reads --
   ------------------

   function Column_Int64
     (S : Statement; Col : Natural) return Interfaces.Integer_64
     with Pre => Is_Valid (S),
          Volatile_Function, Global => (Input => DBMS);
   --  Read column Col (0-based) of the current row as a 64-bit integer. Every
   --  Column_* read is valid only when the most recent Step returned Row, and
   --  only until the next Step/Reset/Finalize on S -- unenforceable in SPARK.
   --  @param S The valid statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return The column value as an Integer_64.

   function Column_Double
     (S : Statement; Col : Natural) return Interfaces.IEEE_Float_64
     with Pre => Is_Valid (S),
          Volatile_Function, Global => (Input => DBMS);
   --  Read column Col of the current row as a double; the vec0 KNN `distance`
   --  column comes back here.
   --  @param S The valid statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return The column value as an IEEE_Float_64.

   function Column_Is_Null (S : Statement; Col : Natural) return Boolean
     with Pre => Is_Valid (S),
          Volatile_Function, Global => (Input => DBMS);
   --  True when the column holds SQL NULL -- the only way to tell that from an
   --  empty-string Column_Text result.
   --  @param S The valid statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return True iff the column holds SQL NULL.

   function Column_Text (S : Statement; Col : Natural) return Text_Ptr
     with Pre  => Is_Valid (S),
          Post => Column_Text'Result /= null,
          Volatile_Function, Global => (Input => DBMS);
   --  A fresh, exactly-sized, caller-owned copy of the column's text, which the
   --  caller must Free -- a copy because sqlite3_column_text's buffer belongs to
   --  SQLite and dies at the next cursor move. Never null; a NULL or empty
   --  column yields "" (length 0).
   --  @param S The valid statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return A fresh, caller-owned copy of the column's text; never null.

private

   pragma Annotate (GNATprove, Hide_Info, "Private_Part");
   --  Required for GNATprove Ownership

   --  The two raw SQLite pointers, each an ownership type and distinct types,
   --  so the Bridge cannot pass a connection to a statement's release
   --  operation or vice versa.
   package Handles is

      type Db_Handle is private
        with Default_Initial_Condition => Is_Null (Db_Handle),
             Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
             Annotate => (GNATprove, Predefined_Equality, "Only_Null");
      --  The C sqlite3*. Owns an open connection until it is closed.

      Null_Db_Handle : constant Db_Handle
        with Annotate => (GNATprove, Ownership, "Reclaimed_Value"),
             Annotate => (GNATprove, Predefined_Equality, "Null_Value");
      --  The reclaimed value: a Db_Handle equal to this owns nothing, so
      --  GNATprove permits dropping or overwriting it.

      function Is_Null (H : Db_Handle) return Boolean
        with Ghost, Global => null, Post => Is_Null'Result = (H = Null_Db_Handle);
      --  Ghost spelling of "reclaimed", for the Default_Initial_Condition
      --  above; executable code compares directly.
      --  @param H The handle to test.
      --  @return True iff H is the reclaimed value.

      type Stmt_Handle is private
        with Default_Initial_Condition => Is_Null (Stmt_Handle),
             Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
             Annotate => (GNATprove, Predefined_Equality, "Only_Null");
      --  The C sqlite3_stmt*. Owns a compiled statement until it is finalized.

      Null_Stmt_Handle : constant Stmt_Handle
        with Annotate => (GNATprove, Ownership, "Reclaimed_Value"),
             Annotate => (GNATprove, Predefined_Equality, "Null_Value");
      --  The reclaimed value for Stmt_Handle (see Null_Db_Handle).

      function Is_Null (H : Stmt_Handle) return Boolean
        with Ghost, Global => null,
             Post => Is_Null'Result = (H = Null_Stmt_Handle);
      --  Ghost spelling of "reclaimed" for Stmt_Handle (see above).
      --  @param H The handle to test.
      --  @return True iff H is the reclaimed value.

   private
      pragma SPARK_Mode (Off);

      type Sqlite3      is limited null record;
      --  Designated type for the C sqlite3. Never allocated or dereferenced on
      --  the Ada side: every value comes from SQLite and goes back to it, so all
      --  the representation owes us is a pointer comparable to null.

      type Sqlite3_Stmt is limited null record;
      --  Designated type for the C sqlite3_stmt (see Sqlite3).

      type Db_Handle   is access all Sqlite3;
      --  The C sqlite3*, owned until closed; full view a plain C pointer.

      type Stmt_Handle is access all Sqlite3_Stmt;
      --  The C sqlite3_stmt*, owned until finalized; full view a plain C
      --  pointer.

      Null_Db_Handle   : constant Db_Handle   := null;
      --  The reclaimed Db_Handle value: the null pointer.

      Null_Stmt_Handle : constant Stmt_Handle := null;
      --  The reclaimed Stmt_Handle value: the null pointer.

      function Is_Null (H : Db_Handle) return Boolean is (H = null);
      --  Completion of the Db_Handle ghost predicate.
      --  @param H The handle to test.
      --  @return True iff H is the null pointer.

      function Is_Null (H : Stmt_Handle) return Boolean is (H = null);
      --  Completion of the Stmt_Handle ghost predicate.
      --  @param H The handle to test.
      --  @return True iff H is the null pointer.
   end Handles;

   use type Handles.Db_Handle;
   use type Handles.Stmt_Handle;

   type Database is limited record
      Handle : Handles.Db_Handle;
      --  The owned sqlite3*; Null_Db_Handle (the default) when not open.
   end record;
   --  Opaque database connection handle.

   type Statement is limited record
      Handle : Handles.Stmt_Handle;
      --  The owned sqlite3_stmt*; Null_Stmt_Handle (the default) when invalid.
   end record;
   --  Opaque prepared-statement handle.

   function Is_Open (DB : Database) return Boolean is
     (DB.Handle /= Handles.Null_Db_Handle);
   --  A connection is open iff its handle is not the reclaimed value.
   --  @param DB The connection handle to test.
   --  @return True iff DB holds a connection.

   function Is_Valid (S : Statement) return Boolean is
     (S.Handle /= Handles.Null_Stmt_Handle);
   --  A statement is valid iff its handle is not the reclaimed value.
   --  @param S The statement handle to test.
   --  @return True iff S holds a compiled statement.

   function Is_Reclaimed (DB : Database) return Boolean is
     (DB.Handle = Handles.Null_Db_Handle);
   --  Reclaimed exactly when the handle is the reclaimed value (equivalently,
   --  not Is_Open (DB)).
   --  @param DB The connection handle to test.
   --  @return True iff DB owns no connection.

   function Is_Reclaimed (S : Statement) return Boolean is
     (S.Handle = Handles.Null_Stmt_Handle);
   --  Reclaimed exactly when the handle is the reclaimed value (equivalently,
   --  not Is_Valid (S)).
   --  @param S The statement handle to test.
   --  @return True iff S owns no statement.

end Sqlite_Vec_Spark;
