--  End-to-end test of memcp's Dispatch: raw JSON-RPC 2.0 request text in,
--  response text out. Covers method routing, id echoing and error framing at
--  the wire level -- not tool behaviour.

with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Spark_Mcp;
with Spark_Mcp.Tools;
with Spark_Mcp.Server;

with Memcp.Hooks;
with Memcp.Tools;
with Memcp.Envelope;
with Memcp.Resources;

procedure Test_Dispatch with SPARK_Mode => Off is

   Failures : Natural := 0;
   --  Failed checks so far; a non-zero count sets a non-zero exit status.

   procedure Check (Cond : Boolean; Label : String);
   --  Report Cond against Label as "ok" or "FAIL", counting a failure.

   procedure Check (Cond : Boolean; Label : String) is
   begin
      if Cond then
         Ada.Text_IO.Put_Line ("ok   - " & Label);
      else
         Ada.Text_IO.Put_Line ("FAIL - " & Label);
         Failures := Failures + 1;
      end if;
   end Check;

   procedure Check_Has (Haystack, Needle, Label : String);
   --  Check that Needle occurs in Haystack, printing both on failure.

   procedure Check_Has (Haystack, Needle, Label : String) is
      use Ada.Strings.Fixed;
   begin
      Check (Index (Haystack, Needle) > 0, Label);
      if Index (Haystack, Needle) = 0 then
         Ada.Text_IO.Put_Line ("        looking for: " & Needle);
         Ada.Text_IO.Put_Line ("        in:          " & Haystack);
      end if;
   end Check_Has;

   Res : Memcp.Resources.Resources;
   --  The store the tools run against, opened :memory: before any dispatch.

   procedure Invoke_Tool
     (Id        : Memcp.Tools.Tool_Id;
      Arguments : String;
      Result    : out Spark_Mcp.Tools.Result_Ptr)
     with Pre => Arguments'Length <= Spark_Mcp.Max_Field;
   --  The Invoke seam: a three-argument adapter closing over Res.

   procedure Invoke_Tool
     (Id        : Memcp.Tools.Tool_Id;
      Arguments : String;
      Result    : out Spark_Mcp.Tools.Result_Ptr)
   is
   begin
      Memcp.Tools.Invoke (Res, Id, Arguments, Result);
   end Invoke_Tool;

   --  The composition under test: memcp's tools plus its json-based envelope
   --  parser supplying spark_mcp's Parse_Envelope formal.
   package MCP is new Spark_Mcp.Server
     (Server_Name    => "memcp",
      Server_Version => "0.1.0",
      Instructions   => Memcp.Tools.Instructions,
      Tool_Id        => Memcp.Tools.Tool_Id,
      Name           => Memcp.Tools.Name,
      Description     => Memcp.Tools.Description,
      Input_Schema    => Memcp.Tools.Input_Schema,
      Invoke          => Invoke_Tool,
      Parse_Envelope  => Memcp.Envelope.Parse_Envelope,
      Client_Meta     => Memcp.Hooks.Client_Meta);

   function Dispatch_Str (Request : String) return String;
   --  Dispatch one request and return the response text, "" for a
   --  notification, freeing the allocation Dispatch hands out.

   function Dispatch_Str (Request : String) return String is
      use type Spark_Mcp.Response_Ptr;
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
   --  Status of the Open below; :memory: does not fail, so nothing reads it.

begin
   --  A live store, so a tools/call reaches a real tool. No model is loaded, so
   --  the embedding tools would report "embedder unavailable"; they are not
   --  exercised here.
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
      Check_Has (R, """instructions""", "initialize: instructions present");
   end;

   -------------------------------------------------------------------------
   --  initialize -- the hook-staleness note
   -------------------------------------------------------------------------
   declare
      function Init (Client : String) return String is
        (Dispatch_Str
           ("{""jsonrpc"":""2.0"",""id"":1,""method"":""initialize"""
            & ",""params"":{""clientInfo"":" & Client & "}}"));
      --  initialize carrying the given clientInfo object.
   begin
      Check
        (Ada.Strings.Fixed.Index
           (Init ("{""name"":""memcp-session-start"",""version"":"""
                  & Memcp.Hooks.Hook_Version & "+deadbeef""}"),
            "_meta") = 0,
         "hook status: the shipped release, digest and all, is not stale");

      Check_Has
        (Init ("{""name"":""memcp-session-start"",""version"":""0.1.0""}"),
         Memcp.Hooks.Stale_Meta,
         "hook status: an older release is answered with the note");

      Check_Has
        (Init ("{""name"":""memcp-session-end"",""version"":""0.1.0""}"),
         Memcp.Hooks.Stale_Meta,
         "hook status: the SessionEnd hook is checked too");

      --  Every other MCP client must stay out of it: Claude Code's own
      --  connection reports its own version, and calling that stale would put
      --  an unactionable block in front of the user on turn one.
      Check
        (Ada.Strings.Fixed.Index
           (Init ("{""name"":""claude-code"",""version"":""0.1.0""}"), "_meta")
         = 0,
         "hook status: a client that is not a hook is never called stale");

      Check
        (Ada.Strings.Fixed.Index (Init ("{}"), "_meta") = 0,
         "hook status: no clientInfo, no note");

      --  clientInfo is informational: a wrong shape must not fail the
      --  handshake, only go unread. A hook that then states no version cannot
      --  be shown current, so it is reported rather than assumed good.
      Check_Has
        (Init ("{""name"":""memcp-session-start"",""version"":42}"),
         """protocolVersion""",
         "hook status: a non-string version still completes initialize");
      Check_Has
        (Init ("{""name"":""memcp-session-start"",""version"":42}"),
         Memcp.Hooks.Stale_Meta,
         "hook status: a hook stating no version is reported, not assumed good");
   end;

   -------------------------------------------------------------------------
   --  ping -- string id echoed verbatim, quotes preserved
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
   --  tools/call -- name extracted and routed, nested arguments parsed
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
      --  An explicit empty 'projects' over an empty store yields an empty
      --  `entries`, so the name routed to recent and its arguments parsed.
      Check_Has (R, "entries\"":[]",
                 "tools/call: tool NAME extracted, routed to recent");
   end;

   -------------------------------------------------------------------------
   --  tools/call, tool-execution failure -- an isError result, not a JSON-RPC
   --  error, which is reserved for faults caught before Invoke. fetch_summary
   --  with no summary_id fails validation in-tool.
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
   --  tools/call, fetch_summary miss -- a result object whose entry is null,
   --  not an error. The store is empty, so any id misses.
   -------------------------------------------------------------------------
   declare
      R : constant String := Dispatch_Str
        ("{""jsonrpc"":""2.0"",""id"":7,""method"":""tools/call"","
         & """params"":{""name"":""fetch_summary"","
         & """arguments"":{""summary_id"":1}}}");
   begin
      Check_Has (R, """isError"":false", "fetch_summary miss: not an error");
      Check_Has (R, "entry\"":null",
                 "fetch_summary miss: a null entry, not a bare sentence");
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
