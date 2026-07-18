--  Spark_Mcp.Server is a generic package, which GNATprove only analyzes
--  through instantiations. This harness instantiates it with a small,
--  representative tool set so that running GNATprove on spark_mcp_prove.gpr
--  generates and discharges the routing body's proof obligations. It is a
--  proof-only unit (not part of the shipped library); the real instantiation
--  lives in memcp.

with Spark_Mcp;
with Spark_Mcp.Tools;
with Spark_Mcp.Server;

package Proof_Harness with SPARK_Mode => On is

   --  A representative two-tool set, mirroring tests/src/test_spark_mcp.adb.
   type Tool_Id is (Echo, Boom);

   function Name (Id : Tool_Id) return String is
     (case Id is when Echo => "echo", when Boom => "boom");

   function Description (Id : Tool_Id) return String is
     (case Id is
        when Echo => "Echo the arguments back.",
        when Boom => "Always fails.");

   function Input_Schema (Id : Tool_Id) return String is
     (case Id is when others => "{""type"":""object""}");

   --  Respond calls Invoke only with a bounded Arguments; taking that as a
   --  precondition lets the body build a result straight from Arguments and
   --  still satisfy Invocation_Result's Len <= Max_Field predicate. A procedure
   --  handing out an ownership allocation, matching the reshaped formal seam.
   procedure Invoke
     (Id        : Tool_Id;
      Arguments : String;
      Result    : out Spark_Mcp.Tools.Result_Ptr)
   with Pre => Arguments'Length <= Spark_Mcp.Max_Field;

   package MCP is new Spark_Mcp.Server
     (Server_Name    => "memcp",
      Server_Version => "0.1.0",
      Instructions   => "instructions",
      Tool_Id        => Tool_Id,
      Name           => Name,
      Description     => Description,
      Input_Schema   => Input_Schema,
      Invoke         => Invoke);

end Proof_Harness;
