--  Sqlite_Vec_Spark.Bridge: the C trust seam for the whole crate.
--
--  Every call across the SQLite/sqlite-vec C ABI is imported here, so the parent
--  body is pure proven-SPARK wrappers with no Import in sight -- the same split
--  as Spark_Mcp_Http.Serve (proven) over Spark_Mcp_Http.Bridge (the C/Rust
--  seam). SPARK does not analyze the foreign bodies; it proves each Pre at the
--  call site and assumes the Global/termination contracts below.
--
--  Why a child, and why spec-only:
--
--    * A child, because DBMS is null-refined in the parent body (its
--      constituents live across the FFI) and SPARK only lets the abstract name
--      be mentioned outside its refinement region. Every mutating import carries
--      Global => (In_Out => DBMS), so none of them can be declared in the body
--      that refines it; here they can.
--
--  Effect model (see the parent spec's DBMS note): every operation that changes
--  connection or statement state -- open, close, exec, prepare, the binds, step,
--  reset, finalize, and vec registration -- carries Global => (In_Out => DBMS).
--  This is why each such import is a *procedure* reporting its result code
--  through an `out Rc` (via the void-returning shims in shim.c): only a
--  procedure may carry an In_Out global, and modelling every mutation as one
--  DBMS effect is what makes SPARK treat two statements over the same
--  connection as potentially interfering (the Ada.Text_IO File_System stance).
--  The value-returning imports (the column_* readers, changes,
--  last_insert_rowid) read mutable C-side state, so they carry
--  Volatile_Function, Global => (Input => DBMS) -- DBMS has Async_Writers, so
--  two calls may legitimately differ and SPARK must not fold them. The one
--  value reader that is a procedure (column_text_copy, filling an out buffer)
--  carries Global => (Input => DBMS) for the same read dependency.
--    * Spec-only, because the Import must live on the declaration itself: the
--      calling convention has to be known where callers see the subprogram, so
--      neither a pragma nor a `with Import` aspect can complete a plain
--      declaration from a body. Every entry is therefore its own import, and
--      the package needs no body.
--
--  Private, because nothing outside Sqlite_Vec_Spark may reach the raw C seam.

with Ada.Streams;
with Interfaces;
with Interfaces.C;
with System;

private package Sqlite_Vec_Spark.Bridge
  with SPARK_Mode => On
is

   procedure Register_Vec (Rc : out Interfaces.C.int)
     with Import, Convention => C,
          External_Name => "memcp_sqlite_register_vec",
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Register the sqlite-vec extension so vec0 exists on connections opened
   --  afterward. Mutates SQLite's process-global auto-extension registry.
   --  @param Rc The raw SQLite result code (non-zero on failure).

   procedure Open
     (Path : String;
      Db   : out System.Address;
      Rc   : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_open",
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Open (or create) a connection. Path must be NUL-terminated (open_v2 takes
   --  no length argument).
   --  @param Path NUL-terminated filesystem path to open or create.
   --  @param Db The raw sqlite3* handle, or Null_Address on failure.
   --  @param Rc The raw SQLite result code.

   procedure Close_V2 (Db : System.Address)
     with Import, Convention => C, External_Name => "sqlite3_close_v2",
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Close a connection (tolerates unfinalized statements, and Null_Address).
   --  @param Db The raw sqlite3* handle to close.

   procedure Exec
     (Db  : System.Address;
      SQL : String;
      Rc  : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_exec",
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Run NUL-terminated SQL with no result rows (memcp_sqlite_exec shim over
   --  sqlite3_exec; the always-NULL callback/arg/errmsg arguments are folded
   --  into the shim).
   --  @param Db The open connection.
   --  @param SQL NUL-terminated SQL producing no result rows.
   --  @param Rc The raw SQLite result code.

   function Last_Insert_Rowid (Db : System.Address) return Interfaces.Integer_64
     with Import, Convention => C, External_Name => "sqlite3_last_insert_rowid",
          Volatile_Function, Global => (Input => DBMS);
   --  Rowid of the most recent INSERT on Db (sqlite3_last_insert_rowid).
   --  @param Db The open connection.
   --  @return The rowid of the most recent successful INSERT.

   function Changes (Db : System.Address) return Interfaces.C.int
     with Import, Convention => C, External_Name => "sqlite3_changes",
          Volatile_Function, Global => (Input => DBMS);
   --  Rows changed by the most recent INSERT/UPDATE/DELETE (sqlite3_changes).
   --  @param Db The open connection.
   --  @return The number of rows changed by the last mutation.

   procedure Prepare
     (Db    : System.Address;
      SQL   : String;
      Nbyte : Interfaces.C.int;
      Stmt  : out System.Address;
      Rc    : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_prepare",
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Compile one SQL statement (memcp_sqlite_prepare shim).
   --  @param Db The open connection.
   --  @param SQL The SQL text (explicit length, not NUL-terminated).
   --  @param Nbyte The byte length of SQL.
   --  @param Stmt The compiled sqlite3_stmt*, or Null_Address.
   --  @param Rc The raw SQLite result code.

   procedure Bind_Text
     (Stmt : System.Address;
      Idx  : Interfaces.C.int;
      Text : String;
      Len  : Interfaces.C.int;
      Rc   : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_bind_text",
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Bind text to a 1-based parameter (SQLITE_TRANSIENT, so SQLite copies).
   --  @param Stmt The valid statement.
   --  @param Idx The 1-based parameter index.
   --  @param Text The text value (explicit length, not NUL-terminated).
   --  @param Len The byte length of Text.
   --  @param Rc The raw SQLite result code.

   procedure Bind_Int64
     (Stmt : System.Address;
      Idx  : Interfaces.C.int;
      Val  : Interfaces.Integer_64;
      Rc   : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_bind_int64",
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Bind a 64-bit integer to a 1-based parameter (sqlite3_bind_int64).
   --  @param Stmt The valid statement.
   --  @param Idx The 1-based parameter index.
   --  @param Val The integer value.
   --  @param Rc The raw SQLite result code.

   procedure Bind_Blob
     (Stmt : System.Address;
      Idx  : Interfaces.C.int;
      Data : Ada.Streams.Stream_Element_Array;
      Len  : Interfaces.C.int;
      Rc   : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_bind_blob",
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Bind a blob to a 1-based parameter (SQLITE_TRANSIENT, so SQLite copies).
   --  @param Stmt The valid statement.
   --  @param Idx The 1-based parameter index.
   --  @param Data The raw bytes.
   --  @param Len The byte length of Data.
   --  @param Rc The raw SQLite result code.

   procedure Bind_Null
     (Stmt : System.Address;
      Idx  : Interfaces.C.int;
      Rc   : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_bind_null",
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Bind SQL NULL to a 1-based parameter (sqlite3_bind_null).
   --  @param Stmt The valid statement.
   --  @param Idx The 1-based parameter index.
   --  @param Rc The raw SQLite result code.

   procedure Step (Stmt : System.Address; Rc : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_step",
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Advance a statement (sqlite3_step): SQLITE_ROW / SQLITE_DONE / error.
   --  @param Stmt The valid statement.
   --  @param Rc The raw SQLite result code.

   procedure Reset (Stmt : System.Address; Rc : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_reset",
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Reset a stepped statement so it can be re-stepped (sqlite3_reset).
   --  @param Stmt The valid statement.
   --  @param Rc The raw SQLite result code.

   procedure Finalize (Stmt : System.Address)
     with Import, Convention => C, External_Name => "sqlite3_finalize",
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Destroy a statement (sqlite3_finalize). Tolerates Null_Address.
   --  @param Stmt The statement to finalize.

   function Column_Int64
     (Stmt : System.Address; Col : Interfaces.C.int)
      return Interfaces.Integer_64
     with Import, Convention => C, External_Name => "sqlite3_column_int64",
          Volatile_Function, Global => (Input => DBMS);
   --  Read a 0-based column of the current row as a 64-bit integer.
   --  @param Stmt The statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return The column value as an Integer_64.

   function Column_Double
     (Stmt : System.Address; Col : Interfaces.C.int)
      return Interfaces.IEEE_Float_64
     with Import, Convention => C, External_Name => "sqlite3_column_double",
          Volatile_Function, Global => (Input => DBMS);
   --  Read a 0-based column of the current row as a double.
   --  @param Stmt The statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return The column value as an IEEE_Float_64.

   function Column_Type
     (Stmt : System.Address; Col : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "sqlite3_column_type",
          Volatile_Function, Global => (Input => DBMS);
   --  The SQLite datatype code of a 0-based column (used to detect SQL NULL).
   --  @param Stmt The statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return The raw sqlite3_column_type code.

   function Column_Text_Len
     (Stmt : System.Address; Col : Interfaces.C.int) return Interfaces.C.size_t
     with Import, Convention => C,
          External_Name => "memcp_sqlite_column_text_len",
          Volatile_Function, Global => (Input => DBMS);
   --  Byte length of a 0-based text column, so the caller can allocate an
   --  exact-size buffer before the copy.
   --  @param Stmt The statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return The column's text length in bytes.

   procedure Column_Text_Copy
     (Stmt : System.Address;
      Col  : Interfaces.C.int;
      Dst  : out String;
      Len  : Interfaces.C.size_t)
     with Import, Convention => C,
          External_Name => "memcp_sqlite_column_text_copy",
          Global => (Input => DBMS), Always_Terminates => True;
   --  Copy a 0-based text column into a caller-owned buffer of exactly Len bytes
   --  (see the parent's Column_Text).
   --  @param Stmt The statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @param Dst The exact-size destination buffer.
   --  @param Len The byte length to copy (= Dst'Length).

end Sqlite_Vec_Spark.Bridge;
