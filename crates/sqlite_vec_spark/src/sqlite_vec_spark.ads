--  sqlite_vec_spark: SPARK binding to SQLite3 + the sqlite-vec extension
--  (both C, permissive-licensed). Thin-bind, don't rewrite.
--
--  This crate is the primitives layer: open/close a connection, run SQL,
--  the prepared-statement lifecycle (prepare/bind/step/column/reset/finalize),
--  and loading the sqlite-vec extension so `vec0` virtual tables and
--  `embedding MATCH ? ORDER BY distance` work. The *store logic* (the schema in
--  store.py, the record types, the queries behind the 9 tools) lives in the
--  memcp bin, built on top of these primitives -- that layer is pure-ish SPARK
--  and is where proof pays off. Nothing here knows a memcp record type or a
--  tool-specific SQL string.
--
--  Both C libraries are compiled straight into this Ada library by the GPR
--  (Languages => ("Ada", "C")); scripts/fetch-deps.sh vendors the pinned
--  amalgamations. There is no system libsqlite3 dependency.
--
--  SPARK_Mode On: the wrappers are proven; only the C bodies are trusted, with
--  Pre/Post as the boundary contract (proved at call sites, assumed of the C,
--  and executed under -gnata in test builds). This crate is candle-shaped -- a
--  data transform behind a handle, no accept loop -- so, like
--  Candle_Spark, it carries all state in its handles and gives the C
--  imports Global => null rather than modelling an external abstract state.
--
--  Design notes (decided 2026-07-13, see README "Design decisions"):
--
--    * Two limited handles. Database AND Statement are `limited private`: both
--      own a raw C pointer, so a copy followed by a second Close/Finalize would
--      double-free. `limited` forbids the copy structurally. (This is stricter
--      than Candle_Spark's copyable Embedder, which gets away with it
--      because exactly one is ever loaded; statements are created and finalized
--      in loops, so the copy hazard is live.)
--
--    * Column text is a caller-owned copy, not a borrow. SQLite owns the buffer
--      sqlite3_column_text returns and it is valid only until the next
--      step/reset/finalize -- we may NOT free it and must NOT alias it past the
--      cursor move. So Column_Text returns a Text_Ptr the caller frees: the
--      wrapper allocates an exact-size String and the C shim memcpys the column
--      into it (the sqlite analogue of Spark_Mcp.Http's Read_Body). One copy is
--      unavoidable to get a stable value; putting it on the ownership heap
--      keeps large bodies off the secondary stack and lets gnatprove discharge
--      the leak / use-after-free obligations.
--
--    * Index bases follow the C API verbatim (this is a thin bind): bind
--      parameter indexes are 1-based (Positive), column indexes are 0-based
--      (Natural) -- exactly sqlite3_bind_* and sqlite3_column_*.

with Ada.Streams;
with Ada.Unchecked_Deallocation;
with Interfaces;
with System;

package Sqlite_Vec_Spark
  with SPARK_Mode     => On,
       Abstract_State => (DBMS with External),
       Initializes    => DBMS
is

   --  DBMS is the SPARK model of the SQLite subsystem's mutable state that lives
   --  across the C boundary. It is External for the same reason Spark_Mcp_Http's
   --  Network is: a database file has genuine asynchronous peers -- other OS
   --  processes and connections can read or write it (especially under WAL) --
   --  so its state is not owned by this program alone. Marking it External is
   --  both honest about that and exactly what makes Open/Close carry weight:
   --  an External write is always effective (an async reader might observe it),
   --  so a Close whose handle is then discarded reads as a real effect, not a
   --  no-op flow-flags as ineffective.
   --
   --  DBMS refines to *null* in the body (the constituents live on the far side
   --  of the FFI), which means -- as with Network -- the C imports that carry
   --  the effect cannot be declared in the body that refines it; they live in
   --  the child Sqlite_Vec_Spark.Bridge, the only place the abstract name is
   --  legal.
   --
   --  Every operation that MUTATES connection or statement state carries
   --  Global => (In_Out => DBMS): not just Open/Close but Execute, Prepare, the
   --  Bind_* setters, Step, Reset and Finalize. This mirrors Ada.Text_IO, whose
   --  reads and writes all declare an effect on a single File_System abstract
   --  state: SPARK does not attempt to prove that a write through one file
   --  handle cannot influence another, and neither do we across one connection.
   --  Modelling every mutation as one shared DBMS effect is what makes SPARK
   --  treat two statements over the same Database as potentially interfering
   --  (Step on statement A may change what Step on statement B observes) -- which
   --  is exactly what can happen when they touch the same rows. The consequence
   --  is that the request path now DOES carry a DBMS global: it propagates up
   --  through the store into the tools and, at memcp's instantiation, into the
   --  frozen generic Dispatch seam. That is sound -- the generic is re-analysed
   --  in the context of its instantiation, so the effect stays visible to flow
   --  analysis rather than hidden behind the seam (see Spark_Mcp.Server.Invoke
   --  and Spark_Mcp_Http.Serve, whose contracts were written to admit it).
   --
   --  The read-only operations (Is_Open/Is_Valid on the handle, and the value
   --  readers Last_Insert_Rowid, Changes and the Column_* family) carry
   --  Global => null. A column read genuinely depends on DBMS, but declaring
   --  that would make each a *volatile function*, which SPARK forbids in the
   --  ordinary expression contexts the store reads them from (aggregates, `not`,
   --  operands). Since the row-positioning discipline they rely on is already
   --  beyond what SPARK can police across the C boundary (documented, not
   --  proved), modelling them as pure reads of the opaque handle is the honest
   --  and workable choice -- the "almost all" carve-out from the rule above.

   --  Opaque connection handle over the C `sqlite3*`. Limited: owns the
   --  connection, must not be copied (see the design note above).
   --
   --  Needs_Reclamation: an open connection owns a C resource that Close must
   --  release. The full view anchors that ownership on a small Ada access
   --  "token" (allocated when the C handle is opened, freed by Close), because
   --  the raw sqlite3* -- a bare System.Address -- is not subject to SPARK
   --  ownership on its own. GNATprove then proves, at every call site, that a
   --  Database is Closed before it is dropped (see the private part note).
   type Database is limited private
     with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
          Default_Initial_Condition =>
            not Is_Open (Database) and then Is_Reclaimed (Database);

   --  Opaque prepared-statement handle over the C `sqlite3_stmt*`. Limited for
   --  the same reason, and more sharply -- statements are short-lived cursors
   --  created and finalized many times. Needs_Reclamation for the same reason
   --  as Database, anchored on the same access-token device: a valid Statement
   --  must be Finalize'd before it goes out of scope, and GNATprove checks it.
   type Statement is limited private
     with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
          Default_Initial_Condition =>
            not Is_Valid (Statement) and then Is_Reclaimed (Statement);

   type Status is (Ok, Error, Row, Done, Busy, Constraint, Misuse);
   --  The subset of SQLite result codes this layer distinguishes. Any other
   --  code maps to Error. Row/Done are the two normal outcomes of Step.
   --  @enum Ok The operation succeeded.
   --  @enum Error A generic SQLite error (any code not otherwise distinguished).
   --  @enum Row Step produced a result row to read with the Column_* functions.
   --  @enum Done Step reached the end of the result set.
   --  @enum Busy The database is locked by another connection.
   --  @enum Constraint A constraint was violated (e.g. UNIQUE, NOT NULL).
   --  @enum Misuse The SQLite API was used incorrectly.

   type Text_Ptr is access String;
   --  Caller-owned text pulled from a column (see the design note). Always
   --  allocated to exactly the column's byte length; the caller frees it with
   --  Free. gnatprove tracks the ownership, so a dropped Text_Ptr is a proof
   --  error, not a silent leak.

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

   --  Reclamation predicates for the Needs_Reclamation annotations above. A
   --  closed connection / finalized statement holds no C resource and no token,
   --  so that is the reclaimed state GNATprove requires before the object is
   --  dropped. Ghost: they exist only for proof, never at run time.
   function Is_Reclaimed (DB : Database) return Boolean
     with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
   --  @param DB The connection handle to test.
   --  @return True iff DB owns no connection (equivalently, not Is_Open (DB)).
   function Is_Reclaimed (S : Statement) return Boolean
     with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
   --  @param S The statement handle to test.
   --  @return True iff S owns no statement (equivalently, not Is_Valid (S)).

   Max_Blob_Bytes : constant := 2 ** 31 - 1;
   --  SQLite's bind-length ABI is a C int, so a single bound value cannot
   --  exceed this (SQLite's own SQLITE_MAX_LENGTH default is smaller still).
   --  Not an artificial memcp cap -- the C boundary imposes it. String-valued
   --  binds inherit the equivalent bound from String'Length <= Integer'Last.

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
   --  the connection has vec0, then setting foreign_keys ON and WAL journalling
   --  (mirrors store.py's per-connection setup). Is_Open (DB) iff Result = Ok;
   --  on failure DB is closed and must not be used.
   --  @param DB The connection handle, set open on success.
   --  @param Path Filesystem path to the database file to open or create.
   --  @param Result Ok on success, or an error code.

   procedure Close (DB : in out Database)
     with Post   => not Is_Open (DB) and then Is_Reclaimed (DB),
          Global => (In_Out => DBMS);
   --  Close the connection (sqlite3_close_v2, which tolerates unfinalized
   --  statements). Idempotent; leaves DB not-open.
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
     with Pre => Is_Open (DB);
   --  Rowid of the most recent successful INSERT on DB (sqlite3_last_insert_
   --  rowid) -- the store.py `cur.lastrowid` after every INSERT. Meaningful
   --  only straight after the INSERT's Step returned Done.
   --  @param DB The open connection to query.
   --  @return The rowid of the most recent successful INSERT on DB.

   function Changes (DB : Database) return Natural
     with Pre => Is_Open (DB);
   --  Rows changed by the most recent INSERT/UPDATE/DELETE (sqlite3_changes) --
   --  e.g. forget_summary's "was a row removed?".
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
   --  Result = Ok. A valid Stmt must eventually be Finalize'd. Stmt holds a
   --  pointer into DB, so DB must outlive Stmt (a usage contract SPARK cannot
   --  express across the C boundary).
   --  @param DB The open connection; must outlive Stmt.
   --  @param SQL A single SQL statement to compile.
   --  @param Stmt The compiled statement, valid on success.
   --  @param Result Ok on success, or an error code.

   procedure Bind_Text
     (S : Statement; Index : Positive; Value : String; Result : out Status)
     with Pre => Is_Valid (S), Global => (In_Out => DBMS);
   --  Bind a value to parameter Index (1-based, as in sqlite3_bind_*). Text and
   --  Blob are copied by SQLite (SQLITE_TRANSIENT), so the Ada arguments need
   --  not outlive the call. Result is Ok or an error code.
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
   --  Bind a blob -- the packed float[Dimension] embedding lands here. The
   --  caller (memcp) overlays an Candle_Spark.Embedding onto a
   --  Stream_Element_Array; this crate stays independent of that one.
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
     with Post   => not Is_Valid (S) and then Is_Reclaimed (S),
          Global => (In_Out => DBMS);
   --  Destroy the statement (sqlite3_finalize). Idempotent; leaves S not-valid.
   --  @param S The statement to finalize; left not-valid.

   ------------------
   -- Column reads --
   ------------------

   function Column_Int64
     (S : Statement; Col : Natural) return Interfaces.Integer_64
     with Pre => Is_Valid (S);
   --  Read column Col of the current row as a 64-bit integer. All Column_*
   --  reads are valid only when the most recent Step returned Row, and only
   --  until the next Step/Reset/Finalize on S (a lifetime SPARK cannot police
   --  across the C boundary -- documented, not proved). Col is 0-based
   --  (sqlite3_column_*).
   --  @param S The valid statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return The column value as an Integer_64.

   function Column_Double
     (S : Statement; Col : Natural) return Interfaces.IEEE_Float_64
     with Pre => Is_Valid (S);
   --  Read column Col of the current row as a double. The vec0 KNN `distance`
   --  column comes back here (a C double).
   --  @param S The valid statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return The column value as an IEEE_Float_64.

   function Column_Is_Null (S : Statement; Col : Natural) return Boolean
     with Pre => Is_Valid (S);
   --  True when the column holds SQL NULL. Callers use this to tell a genuine
   --  NULL (nullable session_id, raw_path) from an empty-string Column_Text.
   --  @param S The valid statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return True iff the column holds SQL NULL.

   function Column_Text (S : Statement; Col : Natural) return Text_Ptr
     with Pre  => Is_Valid (S),
          Post => Column_Text'Result /= null;
   --  A fresh, exactly-sized, caller-owned copy of the column's text (see the
   --  design note). Never null; a NULL or empty column yields "" (length 0).
   --  The caller must Free the result.
   --  @param S The valid statement positioned on a result row.
   --  @param Col The 0-based column index.
   --  @return A fresh, caller-owned copy of the column's text; never null.

private

   --  Hide the representation from clients' proof context: an Ownership type
   --  requires its private part to be either SPARK_Mode (Off) or hidden, and
   --  hiding keeps the wrapper bodies in SPARK (unlike SPARK_Mode (Off), which
   --  would eject them). Clients reason about Database/Statement abstractly --
   --  through Is_Open/Is_Valid, the Needs_Reclamation obligation, and the
   --  operation contracts -- exactly as they do for Memcp_Json.Doc.
   pragma Annotate (GNATprove, Hide_Info, "Private_Part");

   type Ownership_Token is access Boolean;
   --  The SPARK ownership anchor. A raw sqlite3*/sqlite3_stmt* is a bare
   --  System.Address, which SPARK does not track as an owned resource; so the
   --  full view carries, alongside the address, a one-Boolean heap allocation
   --  whose lifetime shadows the C handle's: allocated the instant the C
   --  open/prepare succeeds, freed the instant Close/Finalize releases the C
   --  handle. Because this component is a genuine Ada access, the enclosing
   --  record is "subject to ownership", which is what lets Needs_Reclamation
   --  apply. The Boolean payload is irrelevant -- only null vs non-null (i.e.
   --  owned vs reclaimed) matters.

   type Database is limited record
      Handle : System.Address   := System.Null_Address;
      --  Raw C sqlite3* modelled as an opaque address; null when not open.
      Token  : Ownership_Token  := null;
      --  Ownership anchor; non-null exactly while Handle names an open
      --  connection (maintained in lockstep by Open/Close).
   end record;
   --  Full view of Database. The raw C pointer (only null-comparison is ever
   --  used, as in Candle_Spark / the http Bridge) plus the ownership token.
   --  Default-initialized to (null, null) so a fresh handle is not-open,
   --  reclaimed, and a closed one stays that way.

   type Statement is limited record
      Handle : System.Address   := System.Null_Address;
      --  Raw C sqlite3_stmt* modelled as an opaque address; null when invalid.
      Token  : Ownership_Token  := null;
      --  Ownership anchor; non-null exactly while Handle names a live
      --  statement (maintained in lockstep by Prepare/Finalize).
   end record;
   --  Full view of Statement. The raw C pointer plus the ownership token,
   --  default-initialized to (null, null) so a fresh handle is not-valid,
   --  reclaimed, and a finalized one stays that way.

   function Is_Open (DB : Database) return Boolean is (DB.Token /= null);
   --  A connection is open iff it holds an ownership token. Token tracks the C
   --  handle's liveness (see Open/Close), so this is equivalent to a non-null
   --  Handle while keeping the liveness and reclamation predicates on one
   --  field.
   --  @param DB The connection handle to test.
   --  @return True iff DB holds an ownership token.

   function Is_Valid (S : Statement) return Boolean is (S.Token /= null);
   --  A statement is valid iff it holds an ownership token.
   --  @param S The statement handle to test.
   --  @return True iff S holds an ownership token.

   function Is_Reclaimed (DB : Database) return Boolean is (DB.Token = null);
   --  Completion of the Database reclamation predicate: reclaimed exactly when
   --  the ownership token has been freed (equivalently, not Is_Open (DB)).

   function Is_Reclaimed (S : Statement) return Boolean is (S.Token = null);
   --  Completion of the Statement reclamation predicate: reclaimed exactly when
   --  the ownership token has been freed (equivalently, not Is_Valid (S)).

end Sqlite_Vec_Spark;
