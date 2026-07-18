package body Proof_Harness with SPARK_Mode => On is

   ------------
   -- Invoke --
   ------------

   procedure Invoke
     (Id        : Tool_Id;
      Arguments : String;
      Result    : out Spark_Mcp.Tools.Result_Ptr)
   is
   begin
      case Id is
         when Echo =>
            Result := new Spark_Mcp.Tools.Invocation_Result'
              (Spark_Mcp.Tools.Success (Arguments));
         when Boom =>
            Result := new Spark_Mcp.Tools.Invocation_Result'
              (Spark_Mcp.Tools.Failure
                 (Spark_Mcp.Internal_Error, "boom happened"));
      end case;
   end Invoke;

end Proof_Harness;
