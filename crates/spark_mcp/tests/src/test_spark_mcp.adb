--  Tests for the json-free spark_mcp core: Spark_Mcp.Writer (escaping) and the
--  pre-parsed Spark_Mcp.Server.Respond routing. Mirrors the shapes exercised in
--  ../../../memcp/tests/test_server.py, at the envelope level.
--
--  A tiny fake tool set stands in for memcp's 9 tools so the generic core can
--  be instantiated and driven directly. Run: `alr exec -- gprbuild -P
--  tests/spark_mcp_tests.gpr && tests/bin/test_spark_mcp`.

with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Spark_Mcp;         use Spark_Mcp;
with Spark_Mcp.Tools;
with Spark_Mcp.Writer;
with Spark_Mcp.Server;

procedure Test_Spark_Mcp is

   Failures : Natural := 0;

   procedure Check (Cond : Boolean; Label : String) is
   begin
      if Cond then
         Ada.Text_IO.Put_Line ("ok   - " & Label);
      else
         Ada.Text_IO.Put_Line ("FAIL - " & Label);
         Failures := Failures + 1;
      end if;
   end Check;

   --  Assert that Needle appears somewhere in Haystack.
   procedure Check_Has (Haystack, Needle, Label : String) is
      use Ada.Strings.Fixed;
   begin
      Check (Index (Haystack, Needle) > 0, Label);
      if Index (Haystack, Needle) = 0 then
         Ada.Text_IO.Put_Line ("        looking for: " & Needle);
         Ada.Text_IO.Put_Line ("        in:          " & Haystack);
      end if;
   end Check_Has;

   ---------------------------------------------------------------------------
   --  A fake tool set: Echo succeeds (echoing a fixed payload), Boom fails.
   ---------------------------------------------------------------------------

   type Tool_Id is (Echo, Boom);

   function Name (Id : Tool_Id) return String is
     (case Id is when Echo => "echo", when Boom => "boom");

   function Description (Id : Tool_Id) return String is
     (case Id is
        when Echo => "Echo the arguments back.",
        when Boom => "Always fails.");

   function Input_Schema (Id : Tool_Id) return String is
      pragma Unreferenced (Id);
   begin
      return "{""type"":""object""}";
   end Input_Schema;

   procedure Invoke
     (Id : Tool_Id; Arguments : String; Result : out Tools.Result_Ptr) is
   begin
      case Id is
         when Echo =>
            --  Payload is JSON text; the core wraps it as an MCP text block.
            Result := new Tools.Invocation_Result'
              (Tools.Success ("{""got"":" & Arguments & "}"));
         when Boom =>
            Result := new Tools.Invocation_Result'
              (Tools.Failure (Internal_Error, "boom happened"));
      end case;
   end Invoke;

   package MCP is new Spark_Mcp.Server
     (Server_Name    => "memcp",
      Server_Version => "0.1.0",
      Instructions   => "line one" & ASCII.LF & "line ""two""",
      Tool_Id        => Tool_Id,
      Name           => Name,
      Description     => Description,
      Input_Schema   => Input_Schema,
      Invoke         => Invoke);

   --  Respond is now a procedure handing out an ownership allocation (null for
   --  a notification). This wrapper keeps the assertion call sites below reading
   --  as before: drive Respond, copy the body out as a String ("" for null),
   --  and free the allocation.
   function Respond_Str
     (Method          : String;
      Is_Notification : Boolean;
      Id              : String;
      Tool_Name       : String := "";
      Arguments       : String := "{}") return String
   is
      P : Spark_Mcp.Response_Ptr;
   begin
      MCP.Respond (Method, Is_Notification, Id, P, Tool_Name, Arguments);
      if P = null then
         return "";
      end if;
      declare
         S : constant String := P.all;
      begin
         Spark_Mcp.Free (P);
         return S;
      end;
   end Respond_Str;

   --  Escaped forms, spelled without embedding raw control bytes in this file.
   Q      : constant Character := '"';
   BSlash : constant Character := '\';

begin
   -------------------------------------------------------------------------
   --  Spark_Mcp.Writer
   -------------------------------------------------------------------------
   Check (Spark_Mcp.Writer.Escape ("plain") = "plain",
          "escape: plain passthrough");
   Check
     (Spark_Mcp.Writer.Escape (Q & BSlash) = BSlash & Q & BSlash & BSlash,
      "escape: quote and backslash");
   Check
     (Spark_Mcp.Writer.Escape ("x" & ASCII.LF & ASCII.HT & "y") = "x\n\ty",
      "escape: newline and tab");
   Check
     (Spark_Mcp.Writer.Escape ((1 => ASCII.NUL)) = "\u0000",
      "escape: NUL to backslash-u0000");
   Check
     (Spark_Mcp.Writer.Escape ((1 => Character'Val (16#1F#))) = "\u001f",
      "escape: unit separator to backslash-u001f");
   Check (Spark_Mcp.Writer.Escape ((1 => ASCII.BS)) = "\b",
          "escape: backspace");
   Check (Spark_Mcp.Writer.Escape ((1 => ASCII.CR)) = "\r",
          "escape: carriage return");
   Check (Spark_Mcp.Writer.Escape ("") = "", "escape: empty");
   Check (Spark_Mcp.Writer.Quoted ("hi") = Q & "hi" & Q,
          "quoted: wraps in quotes");
   --  UTF-8 bytes (>= 0x80) pass through unescaped.
   Check
     (Spark_Mcp.Writer.Escape (Character'Val (16#C3#) & Character'Val (16#A9#))
        = Character'Val (16#C3#) & Character'Val (16#A9#),
      "escape: utf-8 passthrough");

   -------------------------------------------------------------------------
   --  initialize
   -------------------------------------------------------------------------
   declare
      R : constant String := Respond_Str ("initialize", False, "1");
   begin
      Check_Has (R, """jsonrpc"":""2.0""", "initialize: jsonrpc tag");
      Check_Has (R, """id"":1", "initialize: id echoed");
      Check_Has (R, """protocolVersion"":""2024-11-05""",
                 "initialize: protocol version");
      Check_Has (R, """serverInfo"":{""name"":""memcp"",""version"":""0.1.0""}",
                 "initialize: serverInfo");
      --  Instructions with a newline and a quote must be escaped.
      Check_Has (R, """instructions"":""line one\nline \""two\""""",
                 "initialize: instructions escaped");
   end;

   -------------------------------------------------------------------------
   --  ping / notification / unknown method
   -------------------------------------------------------------------------
   Check
     (Respond_Str ("ping", False, "7")
        = "{""jsonrpc"":""2.0"",""id"":7,""result"":{}}",
      "ping: empty result");
   Check (Respond_Str ("notifications/initialized", True, "") = "",
          "notification: no response");
   Check_Has (Respond_Str ("no/such", False, "3"), """code"":-32601",
              "unknown method: Method_Not_Found");

   -------------------------------------------------------------------------
   --  tools/list
   -------------------------------------------------------------------------
   declare
      R : constant String := Respond_Str ("tools/list", False, "2");
   begin
      Check_Has (R, """name"":""echo""", "tools/list: echo present");
      Check_Has (R, """name"":""boom""", "tools/list: boom present");
      Check_Has (R, """inputSchema"":{""type"":""object""}",
                 "tools/list: inputSchema embedded verbatim");
      Check_Has (R, """description"":""Echo the arguments back.""",
                 "tools/list: description present");
   end;

   -------------------------------------------------------------------------
   --  tools/call
   -------------------------------------------------------------------------
   declare
      R : constant String :=
        Respond_Str
          (Method          => "tools/call",
           Is_Notification => False,
           Id              => "5",
           Tool_Name       => "echo",
           Arguments       => "{""a"":1}");
   begin
      Check_Has (R, """isError"":false", "tools/call: success flag");
      --  The tool payload {"got":{"a":1}} is carried as an escaped text block.
      Check_Has (R, """text"":""{\""got\"":{\""a\"":1}}""",
                 "tools/call: payload serialized into text block");
   end;

   --  A tool that executes and fails (Tools.Failure) surfaces as an isError
   --  result, NOT a JSON-RPC error -- the message rides in the text block.
   --  (Contrast the unknown-tool dispatch fault just below, still -32602.)
   Check_Has
     (Respond_Str ("tools/call", False, "6", "boom", "{}"),
      """isError"":true",
      "tools/call: failing tool surfaces an isError result");
   Check_Has
     (Respond_Str ("tools/call", False, "6", "boom", "{}"),
      """text"":""boom happened""",
      "tools/call: failing tool surfaces its message");

   Check_Has
     (Respond_Str ("tools/call", False, "8", "nope", "{}"),
      """code"":-32602",
      "tools/call: unknown tool is Invalid_Params");

   -------------------------------------------------------------------------
   Ada.Text_IO.New_Line;
   if Failures = 0 then
      Ada.Text_IO.Put_Line ("All tests passed.");
   else
      Ada.Text_IO.Put_Line
        (Ada.Strings.Fixed.Trim (Failures'Image, Ada.Strings.Both)
         & " test(s) FAILED.");
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Test_Spark_Mcp;
