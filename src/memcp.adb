--  memcp: composition root. The only crate that knows the whole picture --
--  it wires the concrete tools into the generic core and the core into the
--  transport, and owns the Resources object (the Store + Embedder) the tools
--  run against. Ada owns `main`, so elaboration stays automatic.
--
--  The Resources object is a tracked local, not package state: it is Opened at
--  the top of the body and Closed on every exit, and the tool seam reaches it
--  through a nested adapter (Invoke_Tool below) that closes over it. That is
--  what lets SPARK check the open/close lifecycle by ownership (see #20); the
--  generic core and transport never learn that application state exists.

with Ada.Text_IO;

with Memcp_Env;

with Spark_Mcp;
with Spark_Mcp.Tools;
with Spark_Mcp.Server;
with Spark_Mcp.Http;
with Spark_Mcp.Http.Serve;

with Memcp_Resources;
with Memcp_Tools;
with Memcp_Envelope;

procedure Memcp with SPARK_Mode => On is

   --  Environment (mirrors server.py main): MEMCP_DB_PATH, MEMCP_PORT, and
   --  MEMCP_MODEL_PATH (weights; see candle_spark/scripts/install-model.sh).
   --
   --  A value longer than Max_Env (a generous bound on any real path/port) is
   --  ignored in favour of the default, so every derived string is provably
   --  bounded -- the alternative, an unbounded env value, defeats AoRTE on the
   --  concatenations below. The result is 1-based.
   Max_Env : constant := 4096;

   function Env (Name, Default : String) return String
     with Post => Env'Result'First = 1
                  and then Env'Result'Length
                             <= Natural'Max (Max_Env, Default'Length)
                  and then (if Default'Length > 0 then Env'Result'Length > 0);

   function Env (Name, Default : String) return String is
   begin
      if Memcp_Env.Exists (Name) then
         declare
            V : constant String := Memcp_Env.Value (Name);
         begin
            if V'Length in 1 .. Max_Env then
               return R : String (1 .. V'Length) do
                  R := V;
               end return;
            end if;
         end;
      end if;
      return R : String (1 .. Default'Length) do
         R := Default;
      end return;
   end Env;

   --  Parse a port with no exceptions (T'Value would raise on junk): digits
   --  only, in 1 .. 65_535, else the default 8786.
   function Parse_Port (S : String) return Spark_Mcp.Http.Port_Number is
      Acc : Natural := 0;
   begin
      if S'Length = 0 then
         return 8786;
      end if;
      for I in S'Range loop
         pragma Loop_Invariant (Acc <= 65_535);
         if S (I) not in '0' .. '9' then
            return 8786;
         end if;
         Acc := Acc * 10 + (Character'Pos (S (I)) - Character'Pos ('0'));
         if Acc > 65_535 then
            return 8786;
         end if;
      end loop;
      if Acc = 0 then
         return 8786;
      end if;
      return Spark_Mcp.Http.Port_Number (Acc);
   end Parse_Port;

   --  Convention over configuration: unless MEMCP_MODEL_PATH overrides it, look
   --  for the weights at a conventional, working-directory-independent location
   --  (install-model.sh writes here by default too). HOME-relative because
   --  `alr run` launches from memcp/, so a cwd-relative default would miss a
   --  repo-level checkout. Empty only if HOME itself is unset, in which case the
   --  embedding-dependent tools report "embedder unavailable" (as before).
   Home : constant String := Env ("HOME", "");
   Default_Model_Path : constant String :=
     (if Home'Length > 0 then Home & "/.memcp/models/all-MiniLM-L6-v2" else "");

   DB_Path    : constant String := Env ("MEMCP_DB_PATH", ":memory:");
   Model_Path : constant String := Env ("MEMCP_MODEL_PATH", Default_Model_Path);

   Port : constant Spark_Mcp.Http.Port_Number :=
     Parse_Port (Env ("MEMCP_PORT", "8786"));

   --  The owned resources, a tracked local (see the header note). Fresh, so
   --  reclaimed by its Default_Initial_Condition -- which discharges Open's
   --  Pre => Is_Reclaimed (R).
   R       : Memcp_Resources.Resources;
   Open_St : Memcp_Resources.Status;
   use type Memcp_Resources.Status;

begin
   Memcp_Resources.Open (R, DB_Path, Model_Path, Open_St);
   if Open_St /= Memcp_Resources.Ready then
      Ada.Text_IO.Put_Line
        ("memcp: could not open store at " & DB_Path & "; aborting");
      Memcp_Resources.Close (R);   --  reclaim before the scope exits
      return;
   end if;

   Ada.Text_IO.Put_Line
     ("memcp serving on http://127.0.0.1:" & Port'Image
      & " (db=" & DB_Path
      & ", embedder="
      & (if Memcp_Resources.Embedder_Loaded (R)
         then "loaded"
         else "off [" & Model_Path & "]") & ")");

   --  Instantiate the core + transport HERE, where R is open, so the tool seam
   --  can close over it. Invoke_Tool is the 3-argument generic actual the core
   --  expects; it forwards to the 4-argument Memcp_Tools.Invoke, threading R.
   declare
      procedure Invoke_Tool
        (Id        : Memcp_Tools.Tool_Id;
         Arguments : String;
         Result    : out Spark_Mcp.Tools.Result_Ptr)
        with Pre => Arguments'Length <= Spark_Mcp.Max_Field;

      procedure Invoke_Tool
        (Id        : Memcp_Tools.Tool_Id;
         Arguments : String;
         Result    : out Spark_Mcp.Tools.Result_Ptr)
      is
      begin
         Memcp_Tools.Invoke (R, Id, Arguments, Result);
      end Invoke_Tool;

      --  The generic MCP core, specialized to memcp's 9 tools. Parse_Envelope
      --  is the one json-dependent formal -- memcp supplies it (Memcp_Envelope,
      --  built on the json crate) so spark_mcp itself stays json-free.
      package MCP is new Spark_Mcp.Server
        (Server_Name    => "memcp",
         Server_Version => "0.1.0",
         Instructions   => Memcp_Tools.Instructions,
         Tool_Id        => Memcp_Tools.Tool_Id,
         Name           => Memcp_Tools.Name,
         Description     => Memcp_Tools.Description,
         Input_Schema    => Memcp_Tools.Input_Schema,
         Invoke          => Invoke_Tool,
         Parse_Envelope  => Memcp_Envelope.Parse_Envelope);

      --  The transport, specialized to the core's Dispatch. Both seams are
      --  procedures handing out exactly-sized ownership allocations, but of
      --  distinct access types in distinct packages (Spark_Mcp.Response_Ptr vs
      --  Spark_Mcp.Http.Message_Ptr), so this adapter moves between them: null
      --  (notification) passes straight through -> the transport answers 204;
      --  otherwise the response body is copied into a transport allocation and
      --  the core's allocation is freed. The one copy lives here in the
      --  composition root, off the proven hot path -- the price of keeping the
      --  core and its transport free of any shared pointer type.
      procedure Dispatch_Owned
        (Request : String; Response : out Spark_Mcp.Http.Message_Ptr);

      procedure Dispatch_Owned
        (Request : String; Response : out Spark_Mcp.Http.Message_Ptr)
      is
         use type Spark_Mcp.Response_Ptr;  --  "=" against null below
         Owned : Spark_Mcp.Response_Ptr;
      begin
         MCP.Dispatch (Request, Owned);
         if Owned = null then
            Response := null;  --  notification -> 204
         else
            Response := new String'(Owned.all);
            Spark_Mcp.Free (Owned);
         end if;
      end Dispatch_Owned;

      procedure Run is new Spark_Mcp.Http.Serve (On_Request => Dispatch_Owned);
   begin
      begin
         Run (Port);
      exception
         when others =>
            Ada.Text_IO.Put_Line ("memcp: transport error; shutting down");
      end;
   end;

   Memcp_Resources.Close (R);
end Memcp;
