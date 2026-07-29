package body Memcp.Log with SPARK_Mode => On is

   -----------
   -- Error --
   -----------

   procedure Error (Message : String) is
   begin
      --  Prefix then message, as two writes rather than one concatenation:
      --  Message carries no length obligation this way, so needs no
      --  precondition. Warning is the same shape.
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

end Memcp.Log;
