with Ada.Text_IO;

--  Diagnostic logging for memcp.
--
--  memcp's transport is HTTP (tiny_http), so standard output carries no
--  protocol traffic and is free for diagnostics -- `main` already writes its
--  own startup/shutdown lines there through Ada.Text_IO. This package gives
--  the Store and tool layers a way to record failures they otherwise discard
--  (a failed transaction rollback, a replay-corpus embedding miss): those are
--  irrecoverable at the point they occur, but recording them is exactly what
--  makes the failure visible, even where the Python source of truth stays
--  silent.
--
--  Everything here is provable at SPARK Silver: Ada.Text_IO is itself
--  SPARK-annotated in this run-time (Abstract_State => File_System), so the
--  logging effect is modelled honestly as an In_Out on Ada.Text_IO.File_System
--  rather than hidden behind a trusted body.
package Memcp.Log with SPARK_Mode => On is

   procedure Error (Message : String)
     with Global            => (In_Out => Ada.Text_IO.File_System),
          Always_Terminates => True;
   --  Record an irrecoverable failure on the diagnostic channel.

   procedure Warning (Message : String)
     with Global            => (In_Out => Ada.Text_IO.File_System),
          Always_Terminates => True;
   --  Record a recoverable anomaly (e.g. a replay-corpus miss) on the
   --  diagnostic channel.

end Memcp.Log;
