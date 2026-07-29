--  C trust seam for the crate: every SQLite and sqlite-vec import is declared
--  here, keeping the parent body free of Import. Private: nothing outside
--  Sqlite_Vec_Spark may reach the raw seam.
--
--  Every operation that changes connection or statement state -- open, close,
--  exec, prepare, the binds, step, reset, finalize, vec registration -- carries
--  Global => (In_Out => DBMS) and so is a procedure; those that report a result
--  code do so through an `out Rc`, via the void-returning shims in shim.c. The
--  value readers (column_*, changes, last_insert_rowid) carry
--  Global => (Input => DBMS), and the value-returning ones also
--  Volatile_Function.
--
--  Both SQLite pointers cross the seam as the parent's ownership types,
--  Handles.Db_Handle and Handles.Stmt_Handle, so the resource discipline is
--  stated here, on the imports that acquire and release:
--
--    * Open and Prepare promise nothing about the `out` handle:
--      sqlite3_open_v2 can hand back a connection that still needs closing even
--      when it fails, so the wrappers reclaim on every failure path.
--
--    * Close and Finalize are shims over sqlite3_close_v2 / sqlite3_finalize
--      that null the caller's pointer, which is why the handle is `in out` and
--      reaches C as a pointer-to-pointer. Both tolerate an already-reclaimed
--      handle -- no precondition -- so they are idempotent and the failure
--      paths in Open and Prepare can release unconditionally.
--
--    * Everything else takes the handle as `in` and requires it non-null:
--      sqlite3_step, sqlite3_changes and the column readers dereference it, so
--      a null handle is undefined behaviour rather than an error code.
--
--  The column readers are valid only once Step has returned SQLITE_ROW and only
--  until the next Step, Reset or Finalize on that statement.

with Ada.Streams;
with Interfaces;
with Interfaces.C;

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
      Db   : out Handles.Db_Handle;
      Rc   : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_open",
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Open (or create) a connection. Path must be NUL-terminated (open_v2 takes
   --  no length argument). No postcondition on Db: reclaim it whatever Rc says.
   --  @param Path NUL-terminated filesystem path to open or create.
   --  @param Db The connection handle, owned by the caller from here on.
   --  @param Rc The raw SQLite result code.

   procedure Close (Db : in out Handles.Db_Handle)
     with Import, Convention => C, External_Name => "memcp_sqlite_close",
          Global => (In_Out => DBMS), Always_Terminates => True,
          Depends => (Db => null, DBMS =>+ Db),
          Post => Db = Handles.Null_Db_Handle;
   --  Release the connection and leave Db reclaimed (memcp_sqlite_close, a shim
   --  over sqlite3_close_v2 that nulls the caller's pointer). Idempotent:
   --  tolerates an already-reclaimed handle.
   --  @param Db The connection handle to release; left reclaimed.

   procedure Exec
     (Db  : Handles.Db_Handle;
      SQL : String;
      Rc  : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_exec",
          Pre    => Db /= Handles.Null_Db_Handle,
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Run NUL-terminated SQL with no result rows (memcp_sqlite_exec: a
   --  sqlite3_exec shim with NULL callback, arg and errmsg).
   --  @param Db The open connection.
   --  @param SQL NUL-terminated SQL producing no result rows.
   --  @param Rc The raw SQLite result code.

   function Last_Insert_Rowid
     (Db : Handles.Db_Handle) return Interfaces.Integer_64
     with Import, Convention => C, External_Name => "sqlite3_last_insert_rowid",
          Pre => Db /= Handles.Null_Db_Handle,
          Volatile_Function, Global => (Input => DBMS);
   --  Rowid of the most recent INSERT on Db (sqlite3_last_insert_rowid).
   --  @param Db The open connection.
   --  @return The rowid of the most recent successful INSERT.

   function Changes (Db : Handles.Db_Handle) return Interfaces.C.int
     with Import, Convention => C, External_Name => "sqlite3_changes",
          Pre => Db /= Handles.Null_Db_Handle,
          Volatile_Function, Global => (Input => DBMS);
   --  Rows changed by the most recent INSERT/UPDATE/DELETE (sqlite3_changes).
   --  @param Db The open connection.
   --  @return The number of rows changed by the last mutation.

   procedure Prepare
     (Db    : Handles.Db_Handle;
      SQL   : String;
      Nbyte : Interfaces.C.int;
      Stmt  : out Handles.Stmt_Handle;
      Rc    : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_prepare",
          Pre    => Db /= Handles.Null_Db_Handle,
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Compile one SQL statement (memcp_sqlite_prepare shim over
   --  sqlite3_prepare_v2). No postcondition on Stmt: reclaim whatever comes
   --  back even when the compile failed. Stmt points into Db, so Db must
   --  outlive Stmt.
   --  @param Db The open connection.
   --  @param SQL The SQL text (explicit length, not NUL-terminated).
   --  @param Nbyte The byte length of SQL.
   --  @param Stmt The compiled statement, owned by the caller from here on.
   --  @param Rc The raw SQLite result code.

   procedure Bind_Text
     (Stmt : Handles.Stmt_Handle;
      Idx  : Interfaces.C.int;
      Text : String;
      Len  : Interfaces.C.int;
      Rc   : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_bind_text",
          Pre    => Stmt /= Handles.Null_Stmt_Handle,
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Bind text to a 1-based parameter (SQLITE_TRANSIENT, so SQLite copies).
   --  @param Stmt The valid statement.
   --  @param Idx The 1-based parameter index.
   --  @param Text The text value (explicit length, not NUL-terminated).
   --  @param Len The byte length of Text.
   --  @param Rc The raw SQLite result code.

   procedure Bind_Int64
     (Stmt : Handles.Stmt_Handle;
      Idx  : Interfaces.C.int;
      Val  : Interfaces.Integer_64;
      Rc   : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_bind_int64",
          Pre    => Stmt /= Handles.Null_Stmt_Handle,
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Bind a 64-bit integer to a 1-based parameter (sqlite3_bind_int64).
   --  @param Stmt The valid statement.
   --  @param Idx The 1-based parameter index.
   --  @param Val The integer value.
   --  @param Rc The raw SQLite result code.

   procedure Bind_Blob
     (Stmt : Handles.Stmt_Handle;
      Idx  : Interfaces.C.int;
      Data : Ada.Streams.Stream_Element_Array;
      Len  : Interfaces.C.int;
      Rc   : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_bind_blob",
          Pre    => Stmt /= Handles.Null_Stmt_Handle,
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Bind a blob to a 1-based parameter (SQLITE_TRANSIENT, so SQLite copies).
   --  @param Stmt The valid statement.
   --  @param Idx The 1-based parameter index.
   --  @param Data The raw bytes.
   --  @param Len The byte length of Data.
   --  @param Rc The raw SQLite result code.

   procedure Bind_Null
     (Stmt : Handles.Stmt_Handle;
      Idx  : Interfaces.C.int;
      Rc   : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_bind_null",
          Pre    => Stmt /= Handles.Null_Stmt_Handle,
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Bind SQL NULL to a 1-based parameter (sqlite3_bind_null).
   --  @param Stmt The valid statement.
   --  @param Idx The 1-based parameter index.
   --  @param Rc The raw SQLite result code.

   procedure Step
     (Stmt : Handles.Stmt_Handle; Rc : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_step",
          Pre    => Stmt /= Handles.Null_Stmt_Handle,
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Advance a statement (sqlite3_step): SQLITE_ROW / SQLITE_DONE / error.
   --  @param Stmt The valid statement.
   --  @param Rc The raw SQLite result code.

   procedure Reset
     (Stmt : Handles.Stmt_Handle; Rc : out Interfaces.C.int)
     with Import, Convention => C, External_Name => "memcp_sqlite_reset",
          Pre    => Stmt /= Handles.Null_Stmt_Handle,
          Global => (In_Out => DBMS), Always_Terminates => True;
   --  Reset a stepped statement so it can be re-stepped (sqlite3_reset).
   --  @param Stmt The valid statement.
   --  @param Rc The raw SQLite result code.

   procedure Finalize (Stmt : in out Handles.Stmt_Handle)
     with Import, Convention => C, External_Name => "memcp_sqlite_finalize",
          Global => (In_Out => DBMS), Always_Terminates => True,
          Depends => (Stmt => null, DBMS =>+ Stmt),
          Post => Stmt = Handles.Null_Stmt_Handle;
   --  Destroy the statement and leave Stmt reclaimed (memcp_sqlite_finalize, a
   --  shim over sqlite3_finalize that nulls the caller's pointer). Idempotent:
   --  tolerates an already-reclaimed handle.
   --  @param Stmt The statement to destroy; left reclaimed.

   function Column_Int64
     (Stmt : Handles.Stmt_Handle; Col : Interfaces.C.int)
      return Interfaces.Integer_64
     with Import, Convention => C, External_Name => "sqlite3_column_int64",
          Pre => Stmt /= Handles.Null_Stmt_Handle,
          Volatile_Function, Global => (Input => DBMS);
   --  Read a 0-based column of the current row as a 64-bit integer.
   --  @param Stmt The statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return The column value as an Integer_64.

   function Column_Double
     (Stmt : Handles.Stmt_Handle; Col : Interfaces.C.int)
      return Interfaces.IEEE_Float_64
     with Import, Convention => C, External_Name => "sqlite3_column_double",
          Pre => Stmt /= Handles.Null_Stmt_Handle,
          Volatile_Function, Global => (Input => DBMS);
   --  Read a 0-based column of the current row as a double.
   --  @param Stmt The statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return The column value as an IEEE_Float_64.

   function Column_Type
     (Stmt : Handles.Stmt_Handle; Col : Interfaces.C.int)
      return Interfaces.C.int
     with Import, Convention => C, External_Name => "sqlite3_column_type",
          Pre => Stmt /= Handles.Null_Stmt_Handle,
          Volatile_Function, Global => (Input => DBMS);
   --  The SQLite datatype code of a 0-based column (used to detect SQL NULL).
   --  @param Stmt The statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return The raw sqlite3_column_type code.

   function Column_Text_Len
     (Stmt : Handles.Stmt_Handle; Col : Interfaces.C.int)
      return Interfaces.C.size_t
     with Import, Convention => C,
          External_Name => "memcp_sqlite_column_text_len",
          Pre => Stmt /= Handles.Null_Stmt_Handle,
          Volatile_Function, Global => (Input => DBMS);
   --  Byte length of a 0-based text column, so the caller can allocate an
   --  exact-size buffer before the copy.
   --  @param Stmt The statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return The column's text length in bytes.

   procedure Column_Text_Copy
     (Stmt : Handles.Stmt_Handle;
      Col  : Interfaces.C.int;
      Dst  : out String;
      Len  : Interfaces.C.size_t)
     with Import, Convention => C,
          External_Name => "memcp_sqlite_column_text_copy",
          Pre    => Stmt /= Handles.Null_Stmt_Handle,
          Global => (Input => DBMS), Always_Terminates => True;
   --  Copy a 0-based text column into a caller-owned buffer of exactly Len
   --  bytes, taken from Column_Text_Len on the same row.
   --  @param Stmt The statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @param Dst The exact-size destination buffer.
   --  @param Len The byte length to copy (= Dst'Length).

end Sqlite_Vec_Spark.Bridge;
