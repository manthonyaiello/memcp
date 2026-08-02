--  memcp: the composition root. Reads the configuration out of the
--  environment, wires the concrete tools into the generic MCP core and the core
--  into the HTTP transport, and owns the resources the tools run against.

with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;

with Memcp.Env;

with Spark_Mcp;
with Spark_Mcp.Tools;
with Spark_Mcp.Server;
with Spark_Mcp.Http;
with Spark_Mcp.Http.Serve;

with Memcp.Log;
with Memcp.Resources;
with Memcp.Tools;
with Memcp.Envelope;

procedure Main with SPARK_Mode => On is

   Max_Env : constant := 4096;
   --  Longest environment value Env will honour -- a generous bound on any real
   --  path or port. A longer one is ignored, which is what keeps every string
   --  derived below provably bounded.

   function Env (Name, Default : String) return String
     with Post => Env'Result'First = 1
                  and then Env'Result'Length
                             <= Natural'Max (Max_Env, Default'Length)
                  and then (if Default'Length > 0 then Env'Result'Length > 0);
   --  The value of environment variable Name, or Default when it is unset or
   --  longer than Max_Env.

   function Env (Name, Default : String) return String is
   begin
      if Memcp.Env.Exists (Name) then
         declare
            V : constant String := Memcp.Env.Value (Name);
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

   function Parse_Port (S : String) return Spark_Mcp.Http.Port_Number;
   --  S as a port number: digits only, in 1 .. 65_535, else the default
   --  8786. Hand-rolled rather than 'Value, which raises on junk.

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

   Home : constant String := Env ("HOME", "");
   --  The user's home directory, "" when HOME is unset.

   Default_Model_Path : constant String :=
     (if Home'Length > 0 then Home & "/.memcp/models/all-MiniLM-L6-v2" else "");
   --  Where the weights live absent MEMCP_MODEL_PATH: HOME-relative, so it is
   --  independent of the working directory `alr run` launches from, and the
   --  location install-model.sh writes to by default. Empty when HOME is unset,
   --  which leaves the embedder unavailable.

   Default_DB_Path : constant String :=
     (if Home'Length > 0 then Home & "/.memcp/memcp.db" else ":memory:");
   --  Where the store lives absent MEMCP_DB_PATH: HOME-relative, on the same
   --  footing as Default_Model_Path. ":memory:" only when HOME is unset, since
   --  a store with no on-disk parent keeps nothing across a restart and anchors
   --  no sessions directory for upload_session to write into.

   DB_Path    : constant String := Env ("MEMCP_DB_PATH", Default_DB_Path);
   --  Database file the store opens.

   Model_Path : constant String := Env ("MEMCP_MODEL_PATH", Default_Model_Path);
   --  Directory the embedding weights are loaded from.

   Port : constant Spark_Mcp.Http.Port_Number :=
     Parse_Port (Env ("MEMCP_PORT", "8786"));
   --  TCP port the transport binds.

   R       : Memcp.Resources.Resources;
   --  The store and embedder the tools run against. A tracked local rather than
   --  package state: the nested steps below reach it up-level, which is what
   --  lets SPARK check its open/close lifecycle by ownership. Fresh here, so
   --  Open's Pre holds.

   Open_St : Memcp.Resources.Status;
   --  How the Open below ended.
   use type Memcp.Resources.Status;

   Dir_Ok  : Boolean;
   --  Whether the directory holding DB_Path is there to open a file under.

   procedure Ensure_Directory_Of (Path : String; Ok : out Boolean)
     with Global => null;
   --  Create the directory the file Path names lives in, reporting in Ok
   --  whether it is there afterwards. sqlite opens no file under a directory
   --  that does not exist, so without this the HOME-relative default fails on a
   --  machine where ~/.memcp has never been created. A Path holding no '/' --
   --  ":memory:", a bare filename -- names no directory to create, and is Ok.
   --  @param Path The store path whose containing directory is wanted.
   --  @param Ok False when the directory is absent and could not be created.

   procedure Ensure_Directory_Of (Path : String; Ok : out Boolean) is
   begin
      Ok := True;

      for I in reverse Path'Range loop
         if Path (I) = '/' then
            if I > Path'First then
               pragma Warnings
                 (GNATprove, Off, "no Global contract available*",
                  Reason => "Create_Path is not SPARK_Mode => On, so SPARK must assume this");
               --  Accepted: the filesystem mutation stays hidden from SPARK, and
               --  nothing else here reads or depends on that state.

               pragma Warnings
                 (GNATprove, Off, "no Always_Terminates aspect available*",
                  Reason => "Create_Path is not SPARK_Mode => On, so SPARK must assume this");

               Ada.Directories.Create_Path (Path (Path'First .. I - 1));

               pragma Warnings (GNATprove, On, "no Always_Terminates aspect available*");
               pragma Warnings (GNATprove, On, "no Global contract available*");
            end if;
            return;
         end if;
      end loop;
   exception
      when others =>
         pragma Warnings
           (GNATprove, Off, "this statement is never reached",
            Reason => "Create_Path is not SPARK_Mode => On, so SPARK cannot see it raise");
         Ok := False;
         pragma Warnings (GNATprove, On, "this statement is never reached");
   end Ensure_Directory_Of;

   procedure Open_Database (Status : out Memcp.Resources.Status);
   --  Open R against DB_Path and Model_Path, reporting the outcome.

   procedure Open_Database (Status : out Memcp.Resources.Status) is
   begin
      Memcp.Resources.Open (R, DB_Path, Model_Path, Status);
   end Open_Database;

   procedure Connect_To_Server (Port : Spark_Mcp.Http.Port_Number)
     with Pre => Default_DB_Path'Length <= Max_Env + 16
                 and then DB_Path'Length
                            <= Natural'Max (Max_Env, Default_DB_Path'Length)
                 and then Default_Model_Path'Length <= Max_Env + 31
                 and then Model_Path'Length
                            <= Natural'Max (Max_Env, Default_Model_Path'Length);
   --  Serve on Port until the transport gives up. The core and the transport
   --  are instantiated here, where R is open, so the tool seam can close
   --  over it.
   --
   --  Pre: proved in its own context, so the bounds Env's Post already puts
   --  on DB_Path and Model_Path -- facts about constants with variable input
   --  -- do not reach here on their own, and the log line below needs them to
   --  be provably bounded.

   procedure Connect_To_Server (Port : Spark_Mcp.Http.Port_Number) is

      procedure Invoke_Tool
        (Id        : Memcp.Tools.Tool_Id;
         Arguments : String;
         Result    : out Spark_Mcp.Tools.Result_Ptr)
        with Pre => Arguments'Length <= Spark_Mcp.Max_Field;
      --  The three-argument Invoke actual the core expects, forwarding to the
      --  four-argument Memcp.Tools.Invoke with R.

      procedure Invoke_Tool
        (Id        : Memcp.Tools.Tool_Id;
         Arguments : String;
         Result    : out Spark_Mcp.Tools.Result_Ptr)
      is
      begin
         Memcp.Tools.Invoke (R, Id, Arguments, Result);
      end Invoke_Tool;

      --  The generic MCP core, specialized to memcp's tools and to
      --  Memcp.Envelope for the one json-dependent formal, Parse_Envelope.
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

      procedure Dispatch_Owned
        (Request : String; Response : out Spark_Mcp.Http.Message_Ptr);
      --  The core's Dispatch as the transport's handler. Both seams hand out
      --  exactly-sized ownership allocations, but of distinct access types
      --  (Spark_Mcp.Response_Ptr and Spark_Mcp.Http.Message_Ptr), so the body
      --  copies into a transport allocation and frees the core's. Null -- a
      --  notification -- passes straight through. That one copy is the price of
      --  the core and its transport sharing no pointer type.

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
      --  The transport's blocking accept loop, answered by Dispatch_Owned.

   begin
      Ada.Text_IO.Put_Line
         ("memcp serving on http://127.0.0.1:" & Port'Image
         & " (db=" & DB_Path
         & ", embedder="
         & (if Memcp.Resources.Embedder_Loaded (R)
            then "loaded"
            else "off [" & Model_Path & "]") & ")");

      Run (Port);
   exception
      when others =>
         Ada.Text_IO.Put_Line ("memcp: transport error; shutting down");
   end Connect_To_Server;

begin
   Ensure_Directory_Of (DB_Path, Dir_Ok);

   if not Dir_Ok then
      Memcp.Log.Error
        ("cannot create the directory holding " & DB_Path & "; aborting");

      pragma Warnings
        (GNATprove, Off, "no Global contract available*",
         Reason => "Set_Exit_Status is not SPARK_Mode => On, so SPARK must assume this");
      --  Accepted: the exit status is process state SPARK does not model, and
      --  nothing here reads it back.

      pragma Warnings
        (GNATprove, Off, "no Always_Terminates aspect available*",
         Reason => "Set_Exit_Status is not SPARK_Mode => On, so SPARK must assume this");

      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);

      pragma Warnings (GNATprove, On, "no Always_Terminates aspect available*");
      pragma Warnings (GNATprove, On, "no Global contract available*");

      return;
   end if;

   Open_Database (Open_St);

   if Open_St = Memcp.Resources.Ready then
      Connect_To_Server (Port);

   else
      Ada.Text_IO.Put_Line
        ("memcp: could not open store at " & DB_Path & "; aborting");
   end if;

   Memcp.Resources.Close (R);
end Main;
