package body Spark_Mcp.Requests with SPARK_Mode => On is

   ---------------
   -- No_Parser --
   ---------------

   function No_Parser (Request : String) return Envelope is
      pragma Unreferenced (Request);
   begin
      return
        (M_Len           => 0,
         Id_Len          => 0,
         TN_Len          => 0,
         Arg_Len         => 0,
         Kind            => Unimplemented,
         Is_Notification => False,
         Method          => "",
         Id              => "",
         Tool_Name       => "",
         Arguments       => "");
   end No_Parser;

end Spark_Mcp.Requests;
