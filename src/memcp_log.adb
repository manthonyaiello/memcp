package body Memcp_Log with SPARK_Mode => On is

   --  A fixed prefix followed by the message, emitted as two writes rather
   --  than one concatenation: this keeps the line free of any length/overflow
   --  proof obligation on Message (String'Last), so no precondition is needed.

   -----------
   -- Error --
   -----------

   procedure Error (Message : String) is
   begin
      Ada.Text_IO.Put ("memcp [error] ");
      Ada.Text_IO.Put_Line (Message);
   end Error;

   -------------
   -- Warning --
   -------------

   procedure Warning (Message : String) is
   begin
      Ada.Text_IO.Put ("memcp [warn]  ");
      Ada.Text_IO.Put_Line (Message);
   end Warning;

end Memcp_Log;
