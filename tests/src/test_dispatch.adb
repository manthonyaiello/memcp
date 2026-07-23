--  End-to-end test of memcp's Dispatch: raw JSON-RPC 2.0 request text in,
--  response text out. This exercises the piece wired up in this step -- the
--  json-based Memcp.Envelope.Parse_Envelope supplying spark_mcp's generic
--  formal -- plus all of Respond's routing behind it. Mirrors the request
--  shapes in ../../tests/test_server.py (Python) at the wire level.

with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Spark_Mcp;
with Spark_Mcp.Tools;
with Spark_Mcp.Server;

with Memcp.Tools;
with Memcp.Envelope;
with Memcp.Resources;

procedure Test_Dispatch is

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

   procedure Check_Has (Haystack, Needle, Label : String) is
      use Ada.Strings.Fixed;
   begin
      Check (Index (Haystack, Needle) > 0, Label);
      if Index (Haystack, Needle) = 0 then
         Ada.Text_IO.Put_Line ("        looking for: " & Needle);
         Ada.Text_IO.Put_Line ("        in:          " & Haystack);
      end if;
   end Check_Has;

   --  A throwaway in-memory Resources the tools run against; the seam is a
   --  3-argument adapter that closes over it (mirrors memcp.adb). Opened in the
   --  body below before any request is dispatched.
   Res : Memcp.Resources.Resources;

   procedure Invoke_Tool
     (Id        : Memcp.Tools.Tool_Id;
      Arguments : String;
      Result    : out Spark_Mcp.Tools.Result_Ptr)
     with Pre => Arguments'Length <= Spark_Mcp.Max_Field;

   procedure Invoke_Tool
     (Id        : Memcp.Tools.Tool_Id;
      Arguments : String;
      Result    : out Spark_Mcp.Tools.Result_Ptr)
   is
   begin
      Memcp.Tools.Invoke (Res, Id, Arguments, Result);
   end Invoke_Tool;

   --  The real composition: memcp's tools + the json-based envelope parser.
   package MCP is new Spark_Mcp.Server
     (Server_Name    => "memcp",
      Server_Version => "0.1.0",
      Instructions   => Memcp.Tools.Instructions,
      Tool_Id        => Memcp.Tools.Tool_Id,
      Name           => Memcp.Tools.Name,
      Description     => Memcp.Tools.Description,
      Input_Schema    => Memcp.Tools.Input_Schema,
      Invoke          => Invoke_Tool,
      Parse_Envelope  => Memcp.Envelope.Parse_Envelope);

   --  Dispatch is now a procedure handing out an ownership allocation (null for
   --  a notification). This wrapper keeps the assertions below reading as raw
   --  text-in / text-out: drive Dispatch, copy the body out ("" for null), free.
   function Dispatch_Str (Request : String) return String is
      use type Spark_Mcp.Response_Ptr;  --  "=" against null below
      P : Spark_Mcp.Response_Ptr;
   begin
      MCP.Dispatch (Request, P);
      if P = null then
         return "";
      end if;
      declare
         S : constant String := P.all;
      begin
         Spark_Mcp.Free (P);
         return S;
      end;
   end Dispatch_Str;

   Open_St : Memcp.Resources.Status;

begin
   --  The tools run against Res; open a throwaway in-memory store so a
   --  tools/call routes to a live tool (no model loaded, so the embedding tools
   --  would report "embedder unavailable" -- not exercised here; this file tests
   --  routing, not tool behaviour).
   Memcp.Resources.Open (Res, ":memory:", "", Open_St);

   -------------------------------------------------------------------------
   --  initialize -- integer id echoed verbatim
   -------------------------------------------------------------------------
   declare
      R : constant String := Dispatch_Str
        ("{""jsonrpc"":""2.0"",""id"":1,""method"":""initialize"",""params"":{}}");
   begin
      Check_Has (R, """jsonrpc"":""2.0""", "initialize: jsonrpc tag");
      Check_Has (R, """id"":1", "initialize: integer id echoed");
      Check_Has (R, """protocolVersion"":""2024-11-05""",
                 "initialize: protocol version");
      Check_Has (R, """serverInfo""", "initialize: serverInfo present");
   end;

   -------------------------------------------------------------------------
   --  ping -- STRING id echoed verbatim (quotes preserved)
   -------------------------------------------------------------------------
   Check
     (Dispatch_Str ("{""jsonrpc"":""2.0"",""id"":""abc"",""method"":""ping""}")
        = "{""jsonrpc"":""2.0"",""id"":""abc"",""result"":{}}",
      "ping: string id echoed verbatim, empty result");

   -------------------------------------------------------------------------
   --  tools/list -- catalog built from Memcp.Tools
   -------------------------------------------------------------------------
   declare
      R : constant String := Dispatch_Str
        ("{""jsonrpc"":""2.0"",""id"":2,""method"":""tools/list""}");
   begin
      Check_Has (R, """name"":""recent""", "tools/list: recent present");
      Check_Has (R, """name"":""save""",   "tools/list: save present");
      Check_Has (R, """name"":""fetch_turns""",
                 "tools/list: fetch_turns present");
   end;

   -------------------------------------------------------------------------
   --  notification (no id) -- no response owed
   -------------------------------------------------------------------------
   Check
     (Dispatch_Str
        ("{""jsonrpc"":""2.0"",""method"":""notifications/initialized""}") = "",
      "notification: no response");
   Check
     (Dispatch_Str ("{""jsonrpc"":""2.0"",""method"":""ping""}") = "",
      "notification: method with no id is a notification");

   -------------------------------------------------------------------------
   --  tools/call -- name extracted, routed to the (stubbed) tool. Nested
   --  arguments must parse without tripping Bad_Json.
   -------------------------------------------------------------------------
   declare
      R : constant String := Dispatch_Str
        ("{""jsonrpc"":""2.0"",""id"":3,""method"":""tools/call"","
         & """params"":{""name"":""recent"","
         & """arguments"":{""projects"":[],""limit"":5}}}");
   begin
      Check_Has (R, """id"":3", "tools/call: id echoed");
      Check_Has (R, """isError"":false",
                 "tools/call: reaches the tool (success)");
      --  recent got an explicit (empty) 'projects', so the empty store yields
      --  "[]" -- proof the name routed to recent and its arguments parsed.
      Check_Has (R, """text"":""[]""",
                 "tools/call: tool NAME extracted, routed to recent");
   end;

   -------------------------------------------------------------------------
   --  tools/call, tool-execution failure -- surfaced to the model as an
   --  isError result (the MCP way), NOT a JSON-RPC error. JSON-RPC errors are
   --  reserved for faults caught before Invoke (see the unknown-tool case just
   --  below). fetch_summary with no summary_id fails validation in-tool.
   -------------------------------------------------------------------------
   declare
      use Ada.Strings.Fixed;
      R : constant String := Dispatch_Str
        ("{""jsonrpc"":""2.0"",""id"":6,""method"":""tools/call"","
         & """params"":{""name"":""fetch_summary"",""arguments"":{}}}");
   begin
      Check_Has (R, """id"":6", "tool error: id echoed on a result");
      Check_Has (R, """isError"":true", "tool error: framed as an isError result");
      Check_Has (R, """content""", "tool error: carries a content block");
      Check (Index (R, """error"":{") = 0,
             "tool error: NOT framed as a JSON-RPC error object");
   end;

   -------------------------------------------------------------------------
   --  tools/call, fetch_summary miss -- a benign non-error one-line message,
   --  not a bare "null" block (the :memory: store is empty, so any id misses).
   -------------------------------------------------------------------------
   declare
      R : constant String := Dispatch_Str
        ("{""jsonrpc"":""2.0"",""id"":7,""method"":""tools/call"","
         & """params"":{""name"":""fetch_summary"","
         & """arguments"":{""summary_id"":1}}}");
   begin
      Check_Has (R, """isError"":false", "fetch_summary miss: not an error");
      Check_Has (R, """text"":""No summary found for id 1.""",
                 "fetch_summary miss: one-line message, not null");
   end;

   Check_Has
     (Dispatch_Str
        ("{""jsonrpc"":""2.0"",""id"":5,""method"":""tools/call"","
         & """params"":{""name"":""nope""}}"),
      """code"":-32602",
      "tools/call: unknown tool is Invalid_Params");

   -------------------------------------------------------------------------
   --  Envelope errors -- framed with a null id
   -------------------------------------------------------------------------
   Check_Has
     (Dispatch_Str ("{""jsonrpc"":""2.0"","),  --  truncated => not valid JSON
      """code"":-32700",
      "malformed JSON: Parse_Error");
   Check_Has
     (Dispatch_Str ("{""jsonrpc"":""2.0"","),
      """id"":null",
      "malformed JSON: null id");

   Check_Has
     (Dispatch_Str ("{""jsonrpc"":""1.0"",""id"":9,""method"":""ping""}"),
      """code"":-32600",
      "wrong jsonrpc version: Invalid_Request");
   Check_Has
     (Dispatch_Str ("{""jsonrpc"":""2.0"",""id"":9}"),
      """code"":-32600",
      "missing method: Invalid_Request");

   Check_Has
     (Dispatch_Str ("{""jsonrpc"":""2.0"",""id"":4,""method"":""no/such""}"),
      """code"":-32601",
      "unknown method: Method_Not_Found");
   Check_Has
     (Dispatch_Str ("{""jsonrpc"":""2.0"",""id"":4,""method"":""no/such""}"),
      """id"":4",
      "unknown method: id still echoed (a valid envelope)");

   -------------------------------------------------------------------------
   Memcp.Resources.Close (Res);

   Ada.Text_IO.New_Line;
   if Failures = 0 then
      Ada.Text_IO.Put_Line ("All tests passed.");
   else
      Ada.Text_IO.Put_Line
        (Ada.Strings.Fixed.Trim (Failures'Image, Ada.Strings.Both)
         & " test(s) FAILED.");
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Test_Dispatch;
