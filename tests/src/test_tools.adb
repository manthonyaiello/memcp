--  Drives all ten Memcp.Tools entry points in process, with no socket: seeds
--  Memcp.Resources directly, then calls each tool through Invoke and checks the
--  rendered JSON. No model is loaded, so save, search and fetch_chunks are
--  checked on their "embedder unavailable" path and the read/list tools against
--  seeded rows. Built with -gnata, so every Pre/Post crossed is live.

with Ada.Strings.Fixed;
with Ada.Text_IO;

with Spark_Mcp;
with Spark_Mcp.Tools;

with Candle_Spark;
with Memcp.Store;
with Memcp.Resources;
with Memcp.Tools;
with Memcp.Extractor;
with Memcp.Hooks;

procedure Test_Tools with SPARK_Mode => Off is

   use type Memcp.Resources.Status;
   use type Memcp.Store.Op_Status;
   use type Spark_Mcp.Tools.Result_Ptr;

   Failures : Natural := 0;
   --  Number of failed checks; reported by the closing banner.

   procedure Check (Cond : Boolean; Label : String);
   --  Report Cond as one ok/FAIL line labelled Label, counting failures.

   procedure Check (Cond : Boolean; Label : String) is
   begin
      if Cond then
         Ada.Text_IO.Put_Line ("ok   - " & Label);
      else
         Ada.Text_IO.Put_Line ("FAIL - " & Label);
         Failures := Failures + 1;
      end if;
   end Check;

   function Has_Sub (Haystack, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Haystack, Needle) /= 0);
   --  True when Needle occurs anywhere in Haystack.

   function Img (V : Memcp.Store.Row_Id) return String is
     (Ada.Strings.Fixed.Trim (V'Image, Ada.Strings.Both));
   --  V as a trimmed decimal string, for splicing into JSON arguments.

   Res : Memcp.Resources.Resources;
   --  The throwaway Resources every tool call runs against.

   function Call (Id : Memcp.Tools.Tool_Id; Args : String) return String;
   --  Drive one tool and return its rendered payload, or a marker for an
   --  error or null result, freeing the ownership allocation.

   function Call (Id : Memcp.Tools.Tool_Id; Args : String) return String is
      R : Spark_Mcp.Tools.Result_Ptr;
   begin
      Memcp.Tools.Invoke (Res, Id, Args, R);
      if R = null then
         return "<null>";
      end if;
      return S : constant String :=
        (if R.Ok then R.Content
         else "ERR[" & Ada.Strings.Fixed.Trim (R.Code'Image, Ada.Strings.Both)
              & "]:" & R.Message)
      do
         Spark_Mcp.Tools.Free (R);
      end return;
   end Call;

   Zero : constant Candle_Spark.Embedding := [others => 0.0];
   --  The embedding every seeded row carries: no model is loaded here.

   TS   : constant String := "2026-01-01T12:00:00+00:00";
   --  created_at for the seeded rows.

   Surf_M : constant String := """surface"":""bench:bench-id""";
   --  The surface member, spliced into an arguments object that has others.

   Surf : constant String := "{" & Surf_M & "}";
   --  An arguments object carrying nothing but the surface.

   Open_St     : Memcp.Resources.Status;
   Seed_Sum_Id : Memcp.Store.Row_Id := 0;
   --  Summary id of the seeded row, filled in by the seeding Save below.

begin
   Memcp.Resources.Open (Res, ":memory:", "", Open_St);
   Check (Open_St = Memcp.Resources.Ready, "Resources.Open :memory: -> Ready");
   Check (not Memcp.Resources.Embedder_Loaded (Res), "no model -> embedder off");

   ------------------------------------------------------------------
   --  Empty-store shapes
   ------------------------------------------------------------------
   --  Every shape below carries Surf, so these check the payload; the warning
   --  a call without it earns has its own block further down.
   Check (Call (Memcp.Tools.List_Projects, Surf) = "{""entries"":[]}",
          "list_projects (empty) -> empty entries");
   Check (Call (Memcp.Tools.Recent, "{""projects"":[""demo""]," & Surf_M & "}")
            = "{""entries"":[],""findings"":[]}",
          "recent (empty) -> empty entries, no findings");
   --  A miss is a benign answer: a null entry with isError false at the
   --  envelope, not an error.
   Check (Call (Memcp.Tools.Fetch_Summary, "{""summary_id"":999," & Surf_M & "}")
            = "{""entry"":null}",
          "fetch_summary (miss) -> null entry");
   Check (Call (Memcp.Tools.Forget, "{""summary_id"":999," & Surf_M & "}")
            = "{""deleted"":false}",
          "forget (miss) -> deleted:false");
   Check (Call (Memcp.Tools.Fetch_Turns, "{""session_id"":""nope""," & Surf_M & "}")
            = "{""entries"":[]}",
          "fetch_turns (unknown) -> empty entries");

   ------------------------------------------------------------------
   --  Argument validation / gating
   ------------------------------------------------------------------
   Check (Has_Sub (Call (Memcp.Tools.Forget, "{}"), "ERR["),
          "forget without summary_id -> error");
   Check (Has_Sub (Call (Memcp.Tools.Recent, "{ not json"), "projects"),
          "recent with malformed args -> projects required");
   Check (Has_Sub (Call (Memcp.Tools.Recent, "{""n"":5}"), "projects"),
          "recent without projects -> invalid params");
   Check (Call (Memcp.Tools.Recent, "{""projects"":[]," & Surf_M & "}")
            = "{""entries"":[],""findings"":[]}",
          "recent with explicit empty projects -> empty entries");
   Check (Has_Sub (Call (Memcp.Tools.Fetch_Turns,
                   "{""session_id"":""s"",""last"":0}"), "positive"),
          "fetch_turns last=0 -> must be positive");
   Check (Has_Sub (Call (Memcp.Tools.Fetch_Turns,
                   "{""session_id"":""s"",""last"":-3}"), "positive"),
          "fetch_turns negative last -> must be positive");
   Check (Has_Sub (Call (Memcp.Tools.Search,
                   "{""query"":""hi"",""since"":""garbage""}"), "ISO-8601"),
          "search with malformed since -> invalid params");
   Check (Has_Sub (Call (Memcp.Tools.Save,
                   "{""project"":""demo"",""header"":""\n"",""summary"":""\t""}"),
                   "header"),
          "save with whitespace-only header/summary -> invalid params");
   Check (Has_Sub (Call (Memcp.Tools.Save,
            "{""project"":""demo"",""header"":""h"",""summary"":""s""}"),
            "embedder"),
          "save without model -> embedder unavailable");
   --  A leaked-parameter save: the summary swallowed the header across a
   --  </parameter><parameter name="header"> boundary, with header omitted. The
   --  salvage must split it back apart, so the emptiness gate passes and the
   --  call reaches the embedder-unavailable path rather than "header required".
   Check (Has_Sub (Call (Memcp.Tools.Save,
            "{""project"":""demo"",""summary"":""real summary</parameter>"
            & "<parameter name=\""header\"">the header</parameter>""}"),
            "embedder"),
          "save with leaked header boundary -> salvaged, reaches embedder");
   --  A leaked tag may carry an `ns:`-style namespace prefix; it must still
   --  salvage rather than fall through to "header required".
   Check (Has_Sub (Call (Memcp.Tools.Save,
            "{""project"":""demo"",""summary"":""real summary</ns:parameter>"
            & "<ns:parameter name=\""header\"">the header</parameter>""}"),
            "embedder"),
          "save with namespace-prefixed leaked boundary -> salvaged");
   --  With both fields supplied, a boundary-looking sequence is content, not a
   --  leak. This summary is exactly a leading boundary: splitting it would
   --  truncate it to empty and reject the save, so reaching the embedder gate is
   --  what says it was left intact.
   Check (Has_Sub (Call (Memcp.Tools.Save,
            "{""project"":""demo"",""header"":""real header"","
            & """summary"":""</parameter><parameter name=\""header\"">"
            & "leaked""}"),
            "embedder"),
          "save quoting boundary with both fields present -> not split");
   Check (Has_Sub (Call (Memcp.Tools.Search, "{""query"":""hi""}"), "embedder"),
          "search without model -> embedder unavailable");
   Check (Has_Sub (Call (Memcp.Tools.Fetch_Chunks, "{""query"":""hi""}"),
                   "embedder"),
          "fetch_chunks without model -> embedder unavailable");
   Check (Has_Sub (Call (Memcp.Tools.Save, "{""header"":""h"",""summary"":""s""}"),
                   "project"),
          "save without project -> invalid params");
   --  upload_session, no-model paths. A transcript with turns needs the
   --  embedder; a turn-free one does not, so its success path is exercisable
   --  without a model.
   declare
   B64_With_Turns : constant String :=
     "eyJ0eXBlIjoidXNlciIsIm1lc3NhZ2UiOnsicm9sZSI6InVzZXIiLCJjb250ZW50Ijoi"
     & "aGVsbG8gd29ybGQifX0KeyJ0eXBlIjoiYXNzaXN0YW50IiwibWVzc2FnZSI6eyJyb2xl"
     & "IjoiYXNzaXN0YW50IiwiY29udGVudCI6W3sidHlwZSI6InRoaW5raW5nIiwidGhpbmtp"
     & "bmciOiJzZWNyZXQifSx7InR5cGUiOiJ0ZXh0IiwidGV4dCI6ImhpIHRoZXJlIn1dfX0K"
     & "eyJ0eXBlIjoiYXNzaXN0YW50IiwibWVzc2FnZSI6eyJyb2xlIjoiYXNzaXN0YW50Iiwi"
     & "Y29udGVudCI6W3sidHlwZSI6InRoaW5raW5nIiwidGhpbmtpbmciOiJvbmx5IHRoaW5r"
     & "aW5nIn1dfX0Kbm90IGpzb24gYXQgYWxsCnsidHlwZSI6InN5c3RlbSIsInN1YnR5cGUi"
     & "OiJhd2F5X3N1bW1hcnkiLCJjb250ZW50IjoidGhlIHJlY2FwIGxpbmUifQo=";
   --  A JSONL transcript carrying two text-bearing turns, a thinking-only
   --  message, a non-JSON line and an away_summary recap.
begin
   Check (Has_Sub
            (Call (Memcp.Tools.Upload_Session,
                   "{""project"":""up"",""session_id"":""u""}"),
             "transcript_b64"),
          "upload_session without transcript_b64 -> invalid params");
   Check (Has_Sub
            (Call (Memcp.Tools.Upload_Session,
                   "{""project"":""up"",""transcript_b64"":""aGk=""}"),
             "session_id"),
          "upload_session without session_id -> invalid params");
   Check (Has_Sub
            (Call (Memcp.Tools.Upload_Session,
                   "{""project"":""up"",""session_id"":""u"","
                   & """transcript_b64"":""not*base64""}"),
             "base64"),
          "upload_session with bad base64 -> invalid params");
   --  "gA==" is valid base64 for the single byte 16#80#, which is not valid
   --  UTF-8; the transcript has to be rejected on that ground.
   Check (Has_Sub
            (Call (Memcp.Tools.Upload_Session,
                   "{""project"":""up"",""session_id"":""u"","
                   & """transcript_b64"":""gA==""}"),
             "UTF-8"),
          "upload_session non-UTF-8 transcript -> invalid params");
   Check (Has_Sub
            (Call (Memcp.Tools.Upload_Session,
                   "{""project"":""up"",""session_id"":""u"","
                   & """transcript_b64"":""" & B64_With_Turns & """}"),
             "embedder"),
          "upload_session with turns, no model -> embedder unavailable");
   declare
      J1 : constant String :=
        Call (Memcp.Tools.Upload_Session,
              "{""project"":""up"",""session_id"":""empty-1"","
              & """transcript_b64"":""""}");
      J2 : constant String :=
        Call (Memcp.Tools.Upload_Session,
              "{""project"":""up"",""session_id"":""empty-1"","
              & """transcript_b64"":""""}");
   begin
      Check (Has_Sub (J1, """chunk_count"":0")
             and then Has_Sub (J1, """already_existed"":false")
             and then Has_Sub (J1, """autorecap_summary_id"":null"),
             "upload_session (empty transcript) -> 0 chunks, fresh");
      Check (Has_Sub (J2, """already_existed"":true"),
             "upload_session (repeat) -> idempotent already_existed:true");
   end;

   --  Base64 decode and turn extraction, checked directly and independently of
   --  any model: only the two text-bearing user/assistant messages survive,
   --  thinking parts and the non-JSON line are dropped, and the recap is the
   --  away_summary content.
   declare
      use type Memcp.Extractor.Transcript_Ptr;
      Dec  : Memcp.Extractor.Transcript_Ptr;
      B_Ok : Boolean;
   begin
      Memcp.Extractor.Decode_Base64 (B64_With_Turns, Dec, B_Ok);
      Check (B_Ok and then Dec /= null, "extractor: base64 decodes");
      declare
         Transcript : constant String := Dec.all;
         Turns      : constant Memcp.Extractor.Turn_List :=
           Memcp.Extractor.Extract_Turns (Transcript);
         use Memcp.Extractor.Turn_Vectors;
      begin
         Check (Natural (Length (Turns)) = 2,
                "extractor: 2 turns survive (thinking/tool/non-json dropped)");
         Check (Element (Turns, 1).Text = "[user] hello world",
                "extractor: turn 1 is the user text, speaker-prefixed");
         Check (Element (Turns, 2).Text = "[assistant] hi there",
                "extractor: turn 2 is the assistant text part only");
         Check (Memcp.Extractor.Extract_Recap (Transcript) = "the recap line",
                "extractor: recap is the away_summary content");
      end;
      Memcp.Extractor.Free (Dec);
   end;
   end;
   Check (Has_Sub
            (Call (Memcp.Tools.Fetch_Turns,
                   "{""session_id"":""s"",""last"":2,""start"":0}"),
             "cannot be combined"),
          "fetch_turns last+start -> rejected");

   ------------------------------------------------------------------
   --  Seed the shared Store directly, then read it back through Invoke.
   ------------------------------------------------------------------
   declare
      R  : Memcp.Store.Save_Result;
      St : Memcp.Store.Op_Status;
   begin
      Memcp.Resources.Save
        (Res,
         Project      => "demo",
         Header_Text  => "an authored header",
         Summary_Body => "the full summary body",
         Embedding    => Zero,
         Has_Session  => True,
         Session_Id   => "sess-1",
         Has_Created  => True,
         Created_At   => TS,
         Surface       => "",
         Surface_Label => "",
         Result       => R,
         Status       => St);
      Check (St = Memcp.Store.Success, "seed Save -> Success");
      Seed_Sum_Id := R.Summary_Id;
   end;

   declare
      Chunks : Memcp.Store.Chunk_Input_List;
      SR     : Memcp.Store.Session_Save_Result;
      St     : Memcp.Store.Op_Status;
   begin
      Memcp.Store.Chunk_Input_Vectors.Append
        (Chunks, (Body_Len => 6, Content => "turn-0", Embedding => Zero));
      Memcp.Store.Chunk_Input_Vectors.Append
        (Chunks, (Body_Len => 6, Content => "turn-1", Embedding => Zero));
      Memcp.Resources.Save_Session
        (Res,
         Project     => "demo",
         Session_Id  => "sess-1",
         Transcript  => "raw transcript bytes",
         Chunks      => Chunks,
         Has_Created => True,
         Created_At  => TS,
         Surface       => "",
         Surface_Label => "",
         Result      => SR,
         Status      => St);
      Check (St = Memcp.Store.Success, "seed Save_Session -> Success");
   end;

   --  list_projects reports the seeded project.
   declare
      J : constant String := Call (Memcp.Tools.List_Projects, "{}");
   begin
      Check (Has_Sub (J, """project"":""demo""")
             and then Has_Sub (J, """header_count"":1"),
             "list_projects (seeded) -> demo, header_count 1");
   end;

   --  recent returns the seeded Header with its session + kind.
   declare
      J : constant String :=
        Call (Memcp.Tools.Recent, "{""projects"":[""demo""],""n"":5}");
   begin
      --  The Header is what save was handed, not anything read off the body.
      Check (Has_Sub (J, """header"":""an authored header""")
             and then not Has_Sub (J, """header"":""the full summary body""")
             and then Has_Sub (J, """session_id"":""sess-1""")
             and then Has_Sub (J, """kind"":""authored"""),
             "recent (seeded) -> authored header/session/kind");
   end;

   --  fetch_summary of the seeded id returns the full body.
   declare
      J : constant String :=
        Call (Memcp.Tools.Fetch_Summary,
              "{""summary_id"":" & Img (Seed_Sum_Id) & "}");
   begin
      Check (Has_Sub (J, """body"":""the full summary body""")
             and then Has_Sub (J, """project"":""demo"""),
             "fetch_summary (seeded) -> full body");
   end;

   --  fetch_turns returns both chunks, in order, tagged with the session arg.
   declare
      J : constant String :=
        Call (Memcp.Tools.Fetch_Turns, "{""session_id"":""sess-1""}");
   begin
      Check (Has_Sub (J, """body"":""turn-0""")
             and then Has_Sub (J, """body"":""turn-1""")
             and then Has_Sub (J, """ordinal"":0")
             and then Has_Sub (J, """session_id"":""sess-1"""),
             "fetch_turns (seeded) -> both turns");
   end;

   --  fetch_turns tail: last=1 yields only the final turn.
   declare
      J : constant String :=
        Call (Memcp.Tools.Fetch_Turns,
              "{""session_id"":""sess-1"",""last"":1}");
   begin
      Check (Has_Sub (J, """body"":""turn-1""")
             and then not Has_Sub (J, """body"":""turn-0"""),
             "fetch_turns last=1 -> only final turn");
   end;

   --  forget the seeded summary really deletes it.
   declare
      J : constant String :=
        Call (Memcp.Tools.Forget,
              "{""summary_id"":" & Img (Seed_Sum_Id) & "," & Surf_M & "}");
   begin
      Check (J = "{""deleted"":true}", "forget (seeded) -> deleted:true");
      Check (Call (Memcp.Tools.Fetch_Summary,
                   "{""summary_id"":" & Img (Seed_Sum_Id) & "," & Surf_M & "}")
               = "{""entry"":null}",
             "fetch_summary after forget -> null entry");
   end;

   ------------------------------------------------------------------
   --  The surface argument is fail-soft: a write missing it, or carrying
   --  something that is not `label:id`, still lands and says so. Driven
   --  through upload_session with a turn-free transcript, the one write path
   --  that needs no embedder.
   ------------------------------------------------------------------
   declare
      function Upload (Session, Surface_Arg : String) return String is
        (Call (Memcp.Tools.Upload_Session,
               "{""project"":""surf"",""session_id"":""" & Session
               & """,""transcript_b64"":""e30=""" & Surface_Arg & "}"));
      --  upload_session for a fresh session, with Surface_Arg spliced in as a
      --  further member (or nothing at all).
   begin
      declare
         J : constant String := Upload ("u-none", "");
      begin
         Check (Has_Sub (J, """session_row_id"":"),
                "upload_session: no surface -> still written");
         Check (Has_Sub (J, """warning"":") and then Has_Sub (J, "SessionStart"),
                "upload_session: no surface -> warning names the hook");
      end;

      declare
         J : constant String :=
           Upload ("u-bad", ",""surface"":""no-separator""");
      begin
         Check (Has_Sub (J, """session_row_id"":"),
                "upload_session: malformed surface -> still written");
         Check (Has_Sub (J, """warning"":")
                and then Has_Sub (J, "label:id"),
                "upload_session: malformed surface -> warning names the shape");
      end;

      declare
         J : constant String :=
           Upload ("u-ok", ",""surface"":""lab:9f3c""");
      begin
         Check (Has_Sub (J, """session_row_id"":")
                and then not Has_Sub (J, """warning"":"),
                "upload_session: a usable surface warns about nothing");
      end;
   end;

   ------------------------------------------------------------------
   --  Every tool warns about a surface it did not get
   ------------------------------------------------------------------
   --  Gating the writes alone would leave the fault behind an event that may
   --  never happen: a session whose Header comes from SessionEnd never calls
   --  save. A read is the earliest moment this can be said.
   declare
      procedure Warns (Id : Memcp.Tools.Tool_Id; Args, Label : String);
      --  Check that Id warns about the surface in Args, and answers anyway.

      procedure Warns (Id : Memcp.Tools.Tool_Id; Args, Label : String) is
         J : constant String := Call (Id, Args);
      begin
         Check (Has_Sub (J, """warning"":") and then Has_Sub (J, "`doctor`"),
                Label & ": warns, and names the remedy");
         Check (not Has_Sub (J, "ERR["), Label & ": served anyway");
      end Warns;
   begin
      Warns (Memcp.Tools.Recent, "{""projects"":[""demo""]}", "recent");
      Warns (Memcp.Tools.List_Projects, "{}", "list_projects");
      Warns (Memcp.Tools.Fetch_Summary, "{""summary_id"":999}",
             "fetch_summary");
      Warns (Memcp.Tools.Forget, "{""summary_id"":999}", "forget");
      Warns (Memcp.Tools.Fetch_Turns, "{""session_id"":""nope""}",
             "fetch_turns");
      --  search and fetch_chunks warn through the same seam, but stop at the
      --  embedder gate before reaching it with no model loaded.

      --  A surface that arrives in the wrong shape is discarded, and says so
      --  differently: the hook ran, the value did not survive the trip.
      declare
         J : constant String :=
           Call (Memcp.Tools.Recent,
                 "{""projects"":[""demo""],""surface"":""no-separator""}");
      begin
         Check (Has_Sub (J, "label:id"),
                "recent: a malformed surface names the shape expected");
      end;
   end;

   ------------------------------------------------------------------
   --  Findings: reported by recent, written nowhere
   ------------------------------------------------------------------
   declare
      Before : constant String :=
        Call (Memcp.Tools.Recent, "{""projects"":[""dark""]," & Surf_M & "}");

      procedure Seed_Gap (Session : String);
      --  A session that saved a summary and never uploaded a transcript.

      procedure Seed_Gap (Session : String) is
         R  : Memcp.Store.Save_Result;
         St : Memcp.Store.Op_Status;
      begin
         Memcp.Resources.Save
           (Res,
            Project      => "dark",
            Header_Text  => "h " & Session,
            Summary_Body => "b " & Session,
            Embedding    => Zero,
            Has_Session  => True,
            Session_Id   => Session,
            Has_Created  => True,
            Created_At   => TS,
            Surface       => "9f3c",
            Surface_Label => "otherbox",
            Result       => R,
            Status       => St);
         Check (St = Memcp.Store.Success, "findings: seed " & Session);
      end Seed_Gap;
   begin
      Check (Has_Sub (Before, """findings"":[]"),
             "findings: a healthy fleet reports none");

      Seed_Gap ("g-1");
      Seed_Gap ("g-2");
      Seed_Gap ("g-3");

      declare
         J : constant String :=
           Call (Memcp.Tools.Recent,
                 "{""projects"":[""dark""]," & Surf_M & "}");
      begin
         Check (Has_Sub (J, """surface"":""otherbox"""),
                "findings: the degraded surface is named");
         Check (Has_Sub (J, """missing_transcript"":3"),
                "findings: the sessions with no transcript are counted");

         --  The finding must not become project history. It is rendered into
         --  a member of this one answer; nothing about the corpus changed, so
         --  a later read sees the same three Headers and no fourth.
         declare
            K : constant String :=
              Call (Memcp.Tools.Recent,
                    "{""projects"":[""dark""],""n"":50," & Surf_M & "}");
            Hits : Natural := 0;
            Pos  : Natural := K'First;
         begin
            loop
               Pos := Ada.Strings.Fixed.Index
                 (K (Pos .. K'Last), """summary_id"":");
               exit when Pos = 0;
               Hits := Hits + 1;
               Pos := Pos + 1;
            end loop;
            Check (Hits = 3, "findings: no finding was filed as a Header");
         end;
      end;
   end;

   ------------------------------------------------------------------
   --  doctor: a remedy per fault, on a fleet seeded one fault at a time
   ------------------------------------------------------------------
   --  Every assertion is on the remedy, not the diagnosis: a check that only
   --  read "unhealthy" would pass while emitting something nobody can act on.
   --  Driven on a fresh store, because a healthy answer is one of the cases.
   Memcp.Resources.Close (Res);
   Memcp.Resources.Open (Res, ":memory:", "", Open_St);
   Check (Open_St = Memcp.Resources.Ready, "doctor: fresh store -> Ready");

   declare
      procedure Check_In (Surface, Version, Host, Install : String);
      --  One SessionStart check-in from Surface, reporting the three facts
      --  only a hook on that surface can know.

      procedure Check_In (Surface, Version, Host, Install : String) is
         J : constant String :=
           Call (Memcp.Tools.Recent,
                 "{""projects"":[""doc""],""surface"":""" & Surface
                 & """,""hook_version"":""" & Version
                 & """,""host"":""" & Host
                 & """,""install_host"":""" & Install & """}");
      begin
         Check (not Has_Sub (J, "ERR["), "doctor: check-in from " & Surface);
      end Check_In;

      procedure Seed_Gap (Session, Surface, Label : String);
      --  A session on Surface that saved a summary no transcript followed.

      procedure Seed_Gap (Session, Surface, Label : String) is
         R  : Memcp.Store.Save_Result;
         St : Memcp.Store.Op_Status;
      begin
         Memcp.Resources.Save
           (Res,
            Project       => "doc",
            Header_Text   => "h " & Session,
            Summary_Body  => "b " & Session,
            Embedding     => Zero,
            Has_Session   => True,
            Session_Id    => Session,
            Has_Created   => True,
            Created_At    => TS,
            Surface       => Surface,
            Surface_Label => Label,
            Result        => R,
            Status        => St);
         Check (St = Memcp.Store.Success, "doctor: seed " & Session);
      end Seed_Gap;

      Current : constant String := Memcp.Hooks.Hook_Version;
      --  The release this server shipped with, so the test does not go stale
      --  on the next bump.
   begin
      --  Asked by a caller with no surface, about a fleet it knows nothing
      --  about: the least context doctor is ever invoked with, and the fault
      --  that sent the caller here.
      declare
         J : constant String := Call (Memcp.Tools.Doctor, "{}");
      begin
         Check (Has_Sub (J, """calling_surface"":null"),
                "doctor: no surface -> says whose call it cannot place");
         Check (Has_Sub (J, """fault"":""no-surface"""),
                "doctor: no surface -> a fault of its own");
         Check (Has_Sub (J, "install.sh"),
                "doctor: no surface -> remedy names the install step");
         Check (Has_Sub (J, """surfaces"":[]"),
                "doctor: an empty fleet is still an answer");
      end;

      --  One surface, current, writing nothing: the healthy answer.
      Check_In ("one:one-id", Current, "hostone", "hostone");
      declare
         J : constant String :=
           Call (Memcp.Tools.Doctor, "{""surface"":""one:one-id""}");
      begin
         Check (Has_Sub (J, """healthy"":true")
                and then Has_Sub (J, """faults"":[]"),
                "doctor: a healthy fleet reports healthy, with no remedy");
         Check (Has_Sub (J, """calling_surface"":""one"""),
                "doctor: names the surface asking");
         Check (Has_Sub (J, """hook_version"":""" & Current & """"),
                "doctor: the roster carries what the surface reported");
      end;

      --  A surface running hooks older than this server shipped with.
      Check_In ("two:two-id", "0.4.0", "hosttwo", "hosttwo");
      declare
         J : constant String :=
           Call (Memcp.Tools.Doctor, "{""surface"":""one:one-id""}");
      begin
         Check (Has_Sub (J, """fault"":""hook-stale"""),
                "doctor: stale hooks -> a fault");
         Check (Has_Sub (J, "0.4.0") and then Has_Sub (J, Current),
                "doctor: stale hooks -> names the version gap");
         Check (Has_Sub (J, "deploy.sh two"),
                "doctor: stale hooks -> names the update step and the surface");
      end;

      --  A surface whose hooks are too old to report a version at all, which
      --  reads the same as one that has not checked in since memcp recorded
      --  them -- and takes the same remedy.
      Check_In ("three:three-id", "", "", "");
      declare
         J : constant String :=
           Call (Memcp.Tools.Doctor, "{""surface"":""one:one-id""}");
      begin
         Check (Has_Sub (J, """fault"":""hook-version-unknown"""),
                "doctor: no version on record -> a fault");
         Check (Has_Sub (J, "deploy.sh three"),
                "doctor: no version on record -> names the surface and step");
      end;

      --  A config that turned up on a host it was not minted on: two machines
      --  writing under one surface id.
      Check_In ("four:four-id", Current, "clone", "original");
      declare
         J : constant String :=
           Call (Memcp.Tools.Doctor, "{""surface"":""one:one-id""}");
      begin
         Check (Has_Sub (J, """fault"":""inherited-config"""),
                "doctor: an inherited config -> a fault");
         Check (Has_Sub (J, "original") and then Has_Sub (J, "clone"),
                "doctor: an inherited config -> names both hosts");
         Check (Has_Sub (J, "MEMCP_SURFACE_ID"),
                "doctor: an inherited config -> remedy offers the re-roll");
         Check (Has_Sub (J, "MEMCP_SURFACE_HOST"),
                "doctor: a rename is not a clone, and takes the other branch");
      end;

      --  Summaries with no transcripts behind them, on the surface asking:
      --  the remedy it can run without an ssh destination, plus the log that
      --  says why.
      Seed_Gap ("g-1", "one-id", "one");
      Seed_Gap ("g-2", "one-id", "one");
      Seed_Gap ("g-3", "one-id", "one");

      declare
         J : constant String :=
           Call (Memcp.Tools.Doctor, "{""surface"":""one:one-id""}");
      begin
         Check (Has_Sub (J, """fault"":""transcripts-missing"""),
                "doctor: transcripts not arriving -> a fault");
         Check (Has_Sub (J, """surface"":""one"""),
                "doctor: transcripts not arriving -> names the surface");
         Check (Has_Sub (J, "deploy.sh --local"),
                "doctor: the surface asking gets the local remedy");
         Check (Has_Sub (J, "memcp-hook.log"),
                "doctor: and where to look when the remedy does not take");
         Check (Has_Sub (J, """latest"":""" & TS & """"),
                "doctor: every fault dates its newest evidence");
         Check (Has_Sub (J, """missing_transcript"":3"),
                "doctor: the roster carries the counts behind the fault");
      end;
   end;

   Memcp.Resources.Close (Res);

   Ada.Text_IO.New_Line;
   if Failures = 0 then
      Ada.Text_IO.Put_Line ("ALL TESTS PASSED");
   else
      Ada.Text_IO.Put_Line (Failures'Image & " FAILURE(S)");
   end if;
end Test_Tools;
