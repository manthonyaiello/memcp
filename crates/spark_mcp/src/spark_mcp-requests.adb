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
         CN_Len          => 0,
         CV_Len          => 0,
         Kind            => Unimplemented,
         Is_Notification => False,
         Method          => "",
         Id              => "",
         Tool_Name       => "",
         Arguments       => "",
         Client_Name     => "",
         Client_Version  => "");
   end No_Parser;

   --------------------
   -- No_Client_Meta --
   --------------------

   function No_Client_Meta
     (Client_Name, Client_Version : String) return String
   is
      pragma Unreferenced (Client_Name, Client_Version);
   begin
      return "";
   end No_Client_Meta;

end Spark_Mcp.Requests;
