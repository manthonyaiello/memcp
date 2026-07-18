--  Proof-of-life for sqlite_vec_spark: drive the WHOLE binding end-to-end in
--  process against an in-memory database, the way memcp's Store will.
--
--    open :memory:  ->  create a table + a vec0 virtual table  ->  INSERT a row
--    (prepare/bind_text/step, read last_insert_rowid)  ->  INSERT its packed
--    float[384] embedding (bind_int64 + bind_blob)  ->  KNN `MATCH ... ORDER BY
--    distance` (bind_blob query, read column_int64 rowid + column_double
--    distance)  ->  read the TEXT back through a caller-owned Text_Ptr (+ Free).
--
--  Every step is asserted; built with -gnata (see the gpr), so a bad Status,
--  wrong rowid, non-zero self-distance, or mismatched text aborts with
--  Assertion_Error and a non-zero exit. This is the sqlite analogue of candle's
--  "hello -> norm 1.0" run: it proves the C link, the vec0 registration, and
--  the marshalling actually work, not just that the wrappers prove.

with Ada.Text_IO;            use Ada.Text_IO;
with Ada.Streams;
with Ada.Unchecked_Conversion;
with Interfaces;
with Sqlite_Vec_Spark;       use Sqlite_Vec_Spark;

procedure Sqlite_Smoke is
   use type Interfaces.Integer_64;
   use type Interfaces.IEEE_Float_64;
   use type Ada.Streams.Stream_Element_Offset;

   --  A 384-float embedding and its byte-identical blob view (1536 bytes). The
   --  Unchecked_Conversion is the same packed layout sqlite-vec stores and
   --  memcp will overlay onto Candle_Spark.Embedding.
   type F32_Array is array (1 .. 384) of Interfaces.IEEE_Float_32;
   subtype Blob is Ada.Streams.Stream_Element_Array (1 .. 384 * 4);
   function To_Blob is new Ada.Unchecked_Conversion (F32_Array, Blob);

   DB : Database;
   St : Status;
   V  : F32_Array := (others => 0.0);
begin
   --  A simple non-degenerate unit-ish vector; stored == queried so the KNN
   --  self-distance must come back ~0.
   V (1) := 1.0;
   V (2) := 0.5;
   V (3) := 0.25;

   Open (DB, ":memory:", St);
   pragma Assert (St = Ok and then Is_Open (DB));
   Put_Line ("opened :memory:");

   Execute (DB, "CREATE TABLE items (id INTEGER PRIMARY KEY, body TEXT);", St);
   pragma Assert (St = Ok);
   Execute
     (DB, "CREATE VIRTUAL TABLE vec USING vec0(embedding float[384]);", St);
   pragma Assert (St = Ok);
   Put_Line ("created items + vec0 virtual table");

   --  INSERT a row and its embedding.
   declare
      Stmt  : Statement;
      Rowid : Interfaces.Integer_64;
   begin
      Prepare (DB, "INSERT INTO items (body) VALUES (?);", Stmt, St);
      pragma Assert (St = Ok and then Is_Valid (Stmt));
      Bind_Text (Stmt, 1, "hello vector world", St);
      pragma Assert (St = Ok);
      Step (Stmt, St);
      pragma Assert (St = Done);
      Finalize (Stmt);

      Rowid := Last_Insert_Rowid (DB);
      pragma Assert (Rowid = 1);
      Put_Line ("inserted item, rowid =" & Rowid'Image);

      Prepare (DB, "INSERT INTO vec (rowid, embedding) VALUES (?, ?);", Stmt, St);
      pragma Assert (St = Ok);
      Bind_Int64 (Stmt, 1, Rowid, St);
      pragma Assert (St = Ok);
      Bind_Blob (Stmt, 2, To_Blob (V), St);
      pragma Assert (St = Ok);
      Step (Stmt, St);
      pragma Assert (St = Done);
      Finalize (Stmt);
      Put_Line ("inserted packed float[384] embedding");
   end;

   --  KNN: query with the identical vector; expect our rowid at distance ~0.
   declare
      Stmt      : Statement;
      Got_Rowid : Interfaces.Integer_64;
      Dist      : Interfaces.IEEE_Float_64;
   begin
      Prepare
        (DB,
         "SELECT rowid, distance FROM vec "
           & "WHERE embedding MATCH ? ORDER BY distance LIMIT ?;",
         Stmt, St);
      pragma Assert (St = Ok);
      Bind_Blob (Stmt, 1, To_Blob (V), St);
      pragma Assert (St = Ok);
      Bind_Int64 (Stmt, 2, 5, St);
      pragma Assert (St = Ok);

      Step (Stmt, St);
      pragma Assert (St = Row);
      Got_Rowid := Column_Int64 (Stmt, 0);
      Dist      := Column_Double (Stmt, 1);
      pragma Assert (Got_Rowid = 1);
      pragma Assert (Dist >= 0.0 and then Dist < 0.001);
      Put_Line
        ("KNN match: rowid =" & Got_Rowid'Image
           & ", distance =" & Dist'Image);
      Finalize (Stmt);
   end;

   --  Read the TEXT back through an owned Text_Ptr, distinguishing NULL.
   declare
      Stmt : Statement;
      T    : Text_Ptr;
   begin
      Prepare (DB, "SELECT body FROM items WHERE id = ?;", Stmt, St);
      pragma Assert (St = Ok);
      Bind_Int64 (Stmt, 1, 1, St);
      pragma Assert (St = Ok);
      Step (Stmt, St);
      pragma Assert (St = Row);
      pragma Assert (not Column_Is_Null (Stmt, 0));

      T := Column_Text (Stmt, 0);
      pragma Assert (T /= null and then T.all = "hello vector world");
      Put_Line ("read body back = """ & T.all & """");
      Free (T);
      Finalize (Stmt);
   end;

   Close (DB);
   pragma Assert (not Is_Open (DB));
   Put_Line ("ALL CHECKS PASSED");
end Sqlite_Smoke;
