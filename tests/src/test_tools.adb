--  Proof-of-life driver for Memcp_Tools: the 9-tool marshalling layer end to
--  end, in-process (no socket). It seeds the Memcp_Resources Store directly --
--  the same singleton Invoke reads -- then drives each tool via Invoke and
--  checks the rendered JSON. No model is loaded, so the embedding-dependent
--  tools (save/search/fetch_chunks) are checked on their "embedder unavailable"
--  path; the read/list tools are checked against real seeded rows. -gnata makes
--  the Store's and spark_mcp's Pre/Post live along the way.

with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Ada.Text_IO;

with Spark_Mcp;
with Spark_Mcp.Tools;

with Candle_Spark;
with Memcp_Store;
with Memcp_Resources;
with Memcp_Tools;
with Memcp_Extractor;

procedure Test_Tools is

   use type Memcp_Resources.Status;
   use type Memcp_Store.Op_Status;
   use type Spark_Mcp.Tools.Result_Ptr;

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

   --  True when Needle occurs anywhere in Haystack.
   function Has_Sub (Haystack, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Haystack, Needle) /= 0);

   function Img (V : Memcp_Store.Row_Id) return String is
     (Ada.Strings.Fixed.Trim (V'Image, Ada.Strings.Both));

   --  The throwaway Resources the tools run against; Call closes over it.
   Res : Memcp_Resources.Resources;

   --  Drive one tool and return its rendered payload (or a marker for an error
   --  result / null), freeing the ownership allocation.
   function Call (Id : Memcp_Tools.Tool_Id; Args : String) return String is
      R : Spark_Mcp.Tools.Result_Ptr;
   begin
      Memcp_Tools.Invoke (Res, Id, Args, R);
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
   TS   : constant String := "2026-01-01T12:00:00+00:00";

   Open_St     : Memcp_Resources.Status;
   Seed_Sum_Id : Memcp_Store.Row_Id := 0;

begin
   Memcp_Resources.Open (Res, ":memory:", "", Open_St);
   Check (Open_St = Memcp_Resources.Ready, "Resources.Open :memory: -> Ready");
   Check (not Memcp_Resources.Embedder_Loaded (Res), "no model -> embedder off");

   ------------------------------------------------------------------
   --  Empty-store shapes
   ------------------------------------------------------------------
   Check (Call (Memcp_Tools.List_Projects, "{}") = "[]",
          "list_projects (empty) -> []");
   Check (Call (Memcp_Tools.Recent, "{""projects"":[""demo""]}") = "[]",
          "recent (empty) -> []");
   --  A miss is a benign negative answer, not a failure: a plain
   --  (isError:false at the envelope) one-line message, not a "null" block.
   Check (Call (Memcp_Tools.Fetch_Summary, "{""summary_id"":999}")
            = "No summary found for id 999.",
          "fetch_summary (miss) -> message");
   Check (Call (Memcp_Tools.Forget, "{""summary_id"":999}")
            = "{""deleted"":false}",
          "forget (miss) -> deleted:false");
   Check (Call (Memcp_Tools.Fetch_Turns, "{""session_id"":""nope""}") = "[]",
          "fetch_turns (unknown) -> []");

   ------------------------------------------------------------------
   --  Argument validation / gating
   ------------------------------------------------------------------
   Check (Has_Sub (Call (Memcp_Tools.Forget, "{}"), "ERR["),
          "forget without summary_id -> error");
   Check (Has_Sub (Call (Memcp_Tools.Recent, "{ not json"), "projects"),
          "recent with malformed args -> projects required");
   Check (Has_Sub (Call (Memcp_Tools.Recent, "{""n"":5}"), "projects"),
          "recent without projects -> invalid params");
   Check (Call (Memcp_Tools.Recent, "{""projects"":[]}") = "[]",
          "recent with explicit empty projects -> []");
   Check (Has_Sub (Call (Memcp_Tools.Fetch_Turns,
                   "{""session_id"":""s"",""last"":0}"), "positive"),
          "fetch_turns last=0 -> must be positive");
   Check (Has_Sub (Call (Memcp_Tools.Fetch_Turns,
                   "{""session_id"":""s"",""last"":-3}"), "positive"),
          "fetch_turns negative last -> must be positive");
   Check (Has_Sub (Call (Memcp_Tools.Search,
                   "{""query"":""hi"",""since"":""garbage""}"), "ISO-8601"),
          "search with malformed since -> invalid params");
   Check (Has_Sub (Call (Memcp_Tools.Save,
                   "{""project"":""demo"",""diary"":""\n"",""summary"":""\t""}"),
                   "diary"),
          "save with whitespace-only diary/summary -> invalid params");
   Check (Has_Sub (Call (Memcp_Tools.Save,
            "{""project"":""demo"",""diary"":""d"",""summary"":""s""}"),
            "embedder"),
          "save without model -> embedder unavailable");
   --  A leaked-parameter save: the summary swallowed the diary across a
   --  </parameter><parameter name="diary"> boundary, with diary omitted. The
   --  salvage splits it back apart (server.py's _salvage_leaked_params), so the
   --  emptiness gate passes and we reach the embedder-unavailable path -- NOT
   --  the "diary required" rejection the strict pre-salvage code returned.
   Check (Has_Sub (Call (Memcp_Tools.Save,
            "{""project"":""demo"",""summary"":""real summary</parameter>"
            & "<parameter name=\""diary\"">the diary</parameter>""}"),
            "embedder"),
          "save with leaked diary boundary -> salvaged, reaches embedder");
   --  The leaked tags may carry an `ns:`-style namespace prefix (server.py's
   --  _LEAK_BOUNDARY matches `(?:[A-Za-z][\w.\-]*:)?`); a prefixed leak must
   --  still salvage rather than fall through to the "diary required" rejection.
   Check (Has_Sub (Call (Memcp_Tools.Save,
            "{""project"":""demo"",""summary"":""real summary</ns:parameter>"
            & "<ns:parameter name=\""diary\"">the diary</parameter>""}"),
            "embedder"),
          "save with namespace-prefixed leaked boundary -> salvaged");
   --  When the model supplies BOTH fields, a boundary-looking sequence is
   --  legitimate content, not a leak, so it must NOT be split. Here the summary
   --  is exactly a leading boundary: splitting would truncate it to empty and
   --  wrongly reject the save; leaving it intact reaches the embedder gate.
   Check (Has_Sub (Call (Memcp_Tools.Save,
            "{""project"":""demo"",""diary"":""real diary"","
            & """summary"":""</parameter><parameter name=\""diary\"">"
            & "leaked""}"),
            "embedder"),
          "save quoting boundary with both fields present -> not split");
   Check (Has_Sub (Call (Memcp_Tools.Search, "{""query"":""hi""}"), "embedder"),
          "search without model -> embedder unavailable");
   Check (Has_Sub (Call (Memcp_Tools.Fetch_Chunks, "{""query"":""hi""}"),
                   "embedder"),
          "fetch_chunks without model -> embedder unavailable");
   Check (Has_Sub (Call (Memcp_Tools.Save, "{""diary"":""d"",""summary"":""s""}"),
                   "project"),
          "save without project -> invalid params");
   --  upload_session, no-model paths. A transcript with turns needs the
   --  embedder; a turn-free one (here: empty) does not, so its success path is
   --  exercisable without a model.
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
begin
   Check (Has_Sub
            (Call (Memcp_Tools.Upload_Session,
                   "{""project"":""up"",""session_id"":""u""}"),
             "transcript_b64"),
          "upload_session without transcript_b64 -> invalid params");
   Check (Has_Sub
            (Call (Memcp_Tools.Upload_Session,
                   "{""project"":""up"",""transcript_b64"":""aGk=""}"),
             "session_id"),
          "upload_session without session_id -> invalid params");
   Check (Has_Sub
            (Call (Memcp_Tools.Upload_Session,
                   "{""project"":""up"",""session_id"":""u"","
                   & """transcript_b64"":""not*base64""}"),
             "base64"),
          "upload_session with bad base64 -> invalid params");
   --  "gA==" is valid base64 for the single byte 16#80#, which is not valid
   --  UTF-8 -- Python's .decode("utf-8") rejects it, so we must too (issue #4).
   Check (Has_Sub
            (Call (Memcp_Tools.Upload_Session,
                   "{""project"":""up"",""session_id"":""u"","
                   & """transcript_b64"":""gA==""}"),
             "UTF-8"),
          "upload_session non-UTF-8 transcript -> invalid params");
   Check (Has_Sub
            (Call (Memcp_Tools.Upload_Session,
                   "{""project"":""up"",""session_id"":""u"","
                   & """transcript_b64"":""" & B64_With_Turns & """}"),
             "embedder"),
          "upload_session with turns, no model -> embedder unavailable");
   declare
      J1 : constant String :=
        Call (Memcp_Tools.Upload_Session,
              "{""project"":""up"",""session_id"":""empty-1"","
              & """transcript_b64"":""""}");
      J2 : constant String :=
        Call (Memcp_Tools.Upload_Session,
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

   --  The genuinely-new logic under upload_session -- base64 decode + the
   --  extractor.py port -- verified directly (model-independent): only the two
   --  text-bearing user/assistant messages survive; thinking parts, a
   --  thinking-only message, and the non-JSON line are dropped; the recap is
   --  the away_summary content.
   declare
      use type Memcp_Extractor.Transcript_Ptr;
      Dec  : Memcp_Extractor.Transcript_Ptr;
      B_Ok : Boolean;
   begin
      Memcp_Extractor.Decode_Base64 (B64_With_Turns, Dec, B_Ok);
      Check (B_Ok and then Dec /= null, "extractor: base64 decodes");
      declare
         Transcript : constant String := Dec.all;
         Turns      : constant Memcp_Extractor.Turn_List :=
           Memcp_Extractor.Extract_Turns (Transcript);
         use Memcp_Extractor.Turn_Vectors;
      begin
         Check (Natural (Length (Turns)) = 2,
                "extractor: 2 turns survive (thinking/tool/non-json dropped)");
         Check (Element (Turns, 1).Text = "[user] hello world",
                "extractor: turn 1 is the user text, speaker-prefixed");
         Check (Element (Turns, 2).Text = "[assistant] hi there",
                "extractor: turn 2 is the assistant text part only");
         Check (Memcp_Extractor.Extract_Recap (Transcript) = "the recap line",
                "extractor: recap is the away_summary content");
      end;
      Memcp_Extractor.Free (Dec);
   end;
   end;
   Check (Has_Sub
            (Call (Memcp_Tools.Fetch_Turns,
                   "{""session_id"":""s"",""last"":2,""start"":0}"),
             "cannot be combined"),
          "fetch_turns last+start -> rejected");

   ------------------------------------------------------------------
   --  Seed the shared Store directly, then read it back through Invoke.
   ------------------------------------------------------------------
   declare
      R  : Memcp_Store.Save_Result;
      St : Memcp_Store.Op_Status;
   begin
      Memcp_Resources.Save
        (Res,
         Project      => "demo",
         Diary_Body   => "a diary headline",
         Summary_Body => "the full summary body",
         Embedding    => Zero,
         Has_Session  => True,
         Session_Id   => "sess-1",
         Has_Created  => True,
         Created_At   => TS,
         Result       => R,
         Status       => St);
      Check (St = Memcp_Store.Success, "seed Save -> Success");
      Seed_Sum_Id := R.Summary_Id;
   end;

   declare
      Chunks : Memcp_Store.Chunk_Input_List;
      SR     : Memcp_Store.Session_Save_Result;
      St     : Memcp_Store.Op_Status;
   begin
      Memcp_Store.Chunk_Input_Vectors.Append
        (Chunks, (Body_Len => 6, Content => "turn-0", Embedding => Zero));
      Memcp_Store.Chunk_Input_Vectors.Append
        (Chunks, (Body_Len => 6, Content => "turn-1", Embedding => Zero));
      Memcp_Resources.Save_Session
        (Res,
         Project     => "demo",
         Session_Id  => "sess-1",
         Transcript  => "raw transcript bytes",
         Chunks      => Chunks,
         Has_Created => True,
         Created_At  => TS,
         Result      => SR,
         Status      => St);
      Check (St = Memcp_Store.Success, "seed Save_Session -> Success");
   end;

   --  list_projects now reports demo.
   declare
      J : constant String := Call (Memcp_Tools.List_Projects, "{}");
   begin
      Check (Has_Sub (J, """project"":""demo""")
             and then Has_Sub (J, """diary_count"":1"),
             "list_projects (seeded) -> demo, diary_count 1");
   end;

   --  recent returns the seeded Header with its session + kind.
   declare
      J : constant String :=
        Call (Memcp_Tools.Recent, "{""projects"":[""demo""],""n"":5}");
   begin
      --  The Header's headline is derived from the *summary* body
      --  (Parse_Headline), not the diary line -- store.py parity.
      Check (Has_Sub (J, """headline"":""the full summary body""")
             and then Has_Sub (J, """session_id"":""sess-1""")
             and then Has_Sub (J, """kind"":""diary"""),
             "recent (seeded) -> headline/session/kind");
   end;

   --  fetch_summary of the seeded id returns the full body.
   declare
      J : constant String :=
        Call (Memcp_Tools.Fetch_Summary,
              "{""summary_id"":" & Img (Seed_Sum_Id) & "}");
   begin
      Check (Has_Sub (J, """body"":""the full summary body""")
             and then Has_Sub (J, """project"":""demo"""),
             "fetch_summary (seeded) -> full body");
   end;

   --  fetch_turns returns both chunks, in order, tagged with the session arg.
   declare
      J : constant String :=
        Call (Memcp_Tools.Fetch_Turns, "{""session_id"":""sess-1""}");
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
        Call (Memcp_Tools.Fetch_Turns,
              "{""session_id"":""sess-1"",""last"":1}");
   begin
      Check (Has_Sub (J, """body"":""turn-1""")
             and then not Has_Sub (J, """body"":""turn-0"""),
             "fetch_turns last=1 -> only final turn");
   end;

   --  forget the seeded summary really deletes it.
   declare
      J : constant String :=
        Call (Memcp_Tools.Forget, "{""summary_id"":" & Img (Seed_Sum_Id) & "}");
   begin
      Check (J = "{""deleted"":true}", "forget (seeded) -> deleted:true");
      Check (Call (Memcp_Tools.Fetch_Summary,
                   "{""summary_id"":" & Img (Seed_Sum_Id) & "}")
               = "No summary found for id " & Img (Seed_Sum_Id) & ".",
             "fetch_summary after forget -> message");
   end;

   Memcp_Resources.Close (Res);

   Ada.Text_IO.New_Line;
   if Failures = 0 then
      Ada.Text_IO.Put_Line ("ALL TESTS PASSED");
   else
      Ada.Text_IO.Put_Line (Failures'Image & " FAILURE(S)");
   end if;
end Test_Tools;
