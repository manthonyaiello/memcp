with Ada.Text_IO;

--  Memcp.Log: diagnostic logging on standard output, prefixed by severity. The
--  transport is HTTP, so standard output carries no protocol traffic and is free
--  for diagnostics. It is where a failure that cannot be recovered at the point
--  it occurs is at least made visible.
package Memcp.Log with SPARK_Mode => On is

   procedure Error (Message : String)
     with Global            => (In_Out => Ada.Text_IO.File_System),
          Always_Terminates => True;
   --  Record an irrecoverable failure on the diagnostic channel.
   --  @param Message The text to record.

   procedure Warning (Message : String)
     with Global            => (In_Out => Ada.Text_IO.File_System),
          Always_Terminates => True;
   --  Record a recoverable anomaly on the diagnostic channel.
   --  @param Message The text to record.

end Memcp.Log;
