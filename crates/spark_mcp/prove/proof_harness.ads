--  Proof_Harness: a proof-only instantiation of Spark_Mcp.Server over a
--  two-tool set, so that running GNATprove on spark_mcp_prove.gpr generates and
--  discharges the routing body's obligations. Not part of the shipped library.

with Spark_Mcp;
with Spark_Mcp.Requests;
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

   function No_Parser
     (Request : String) return Spark_Mcp.Requests.Envelope
   is
     (M_Len           => 0,
      Id_Len          => 0,
      TN_Len          => 0,
      Arg_Len         => 0,
      CN_Len          => 0,
      CV_Len          => 0,
      Kind            => Spark_Mcp.Requests.Unimplemented,
      Is_Notification => False,
      Method          => "",
      Id              => "",
      Tool_Name       => "",
      Arguments       => "",
      Client_Name     => "",
      Client_Version  => "")
   with Depends => (No_Parser'Result => null, null => Request);
   --  A Parse_Envelope that decodes nothing: Dispatch's obligations are the
   --  same whatever the parser returns, and this keeps the harness free of a
   --  JSON dependency.
   --  @param Request The raw request text; no decoding is attempted.
   --  @return An Envelope with Kind => Unimplemented and every *_Len => 0.

   function No_Meta (Client_Name, Client_Version : String) return String is
     ("")
   with Depends =>
     (No_Meta'Result => null, null => (Client_Name, Client_Version));
   --  A Client_Meta that says nothing, so `initialize` carries no `_meta`.
   --  @param Client_Name The client's reported name.
   --  @param Client_Version The client's reported version.
   --  @return "", adding no members.

   pragma Warnings (Off, "unused initial value of ""Request""");
   --  No_Parser reads nothing, so Dispatch's Request reaches no output in this
   --  instance. The dead parameter is the harness's, not the library's.

   package MCP is new Spark_Mcp.Server
     (Server_Name    => "memcp",
      Server_Version => "0.1.0",
      Instructions   => "instructions",
      Tool_Id        => Tool_Id,
      Name           => Name,
      Description     => Description,
      Input_Schema   => Input_Schema,
      Invoke         => Invoke,
      Parse_Envelope => No_Parser,
      Client_Meta    => No_Meta);
   --  The instantiation under proof.

   pragma Warnings (On, "unused initial value of ""Request""");

end Proof_Harness;
