--  Proof_Harness: a proof-only instantiation of Spark_Mcp.Server over a
--  two-tool set, so that running GNATprove on spark_mcp_prove.gpr generates and
--  discharges the routing body's obligations. Not part of the shipped library.

with Spark_Mcp;
with Spark_Mcp.Tools;
with Spark_Mcp.Server;

package Proof_Harness with SPARK_Mode => On is

   type Tool_Id is (Echo, Boom);
   --  The harness's tool set: one tool of each outcome.
   --  @enum Echo A tool that succeeds, echoing its arguments back.
   --  @enum Boom A tool that always fails.

   function Name (Id : Tool_Id) return String is
     (case Id is when Echo => "echo", when Boom => "boom");
   --  The wire name of a tool.
   --  @param Id The tool to name.
   --  @return The tool's MCP name.

   function Description (Id : Tool_Id) return String is
     (case Id is
        when Echo => "Echo the arguments back.",
        when Boom => "Always fails.");
   --  The human-readable description of a tool.
   --  @param Id The tool to describe.
   --  @return The tool's description.

   function Input_Schema (Id : Tool_Id) return String is
     (case Id is when others => "{""type"":""object""}");
   --  The JSON Schema for a tool's arguments.
   --  @param Id The tool whose schema is wanted.
   --  @return A JSON Schema object, as text.

   procedure Invoke
     (Id        : Tool_Id;
      Arguments : String;
      Result    : out Spark_Mcp.Tools.Result_Ptr)
   with Pre => Arguments'Length <= Spark_Mcp.Max_Field;
   --  Run one tool, building its result straight from Arguments.
   --  @param Id The tool to run.
   --  @param Arguments The raw JSON arguments object.
   --  @param Result The allocated invocation result, owned by the caller.

   package MCP is new Spark_Mcp.Server
     (Server_Name    => "memcp",
      Server_Version => "0.1.0",
      Instructions   => "instructions",
      Tool_Id        => Tool_Id,
      Name           => Name,
      Description     => Description,
      Input_Schema   => Input_Schema,
      Invoke         => Invoke);
   --  The instantiation under proof.

end Proof_Harness;
