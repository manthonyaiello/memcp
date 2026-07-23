--  memcp's concrete tool set: each Invoke branch parses its arguments with
--  Memcp.Json, runs the request against the Memcp.Resources object passed in,
--  and renders the reply as JSON text matching the matching @mcp.tool in
--  server.py.
--
--  SPARK_Mode On. It is pure marshalling: it holds no state (the Store/Embedder
--  live in the Resources object, reached through its total operations),
--  builds every result through the bounded Memcp.Text builder (so the response
--  layer's Max_Field budget holds by construction), and provably never raises
--  -- so no exception handler is needed and Dispatch's "never raises" contract
--  is a theorem, not folklore. The Doc parsed from `arguments` is the one owning
--  object; it is Closed on every path.

with Ada.Containers;         use type Ada.Containers.Count_Type;

with Interfaces;             use type Interfaces.Integer_64;

with Spark_Mcp;              use Spark_Mcp;

with Candle_Spark;
with Memcp.Store;
with Memcp.Replay;
with Memcp.Json;
with Memcp.Log;
with Memcp.Extractor;
with Memcp.Text;

package body Memcp.Tools with SPARK_Mode => On is

   --  Each tool Closes the Doc it parsed from `arguments` on every path; the
   --  Doc is an ownership handle nulled by Close and never read afterwards, so
   --  the "set by Close" / "no effect" reports are the expected shape of that
   --  end-of-scope cleanup.
   pragma Warnings
     (GNATprove, Off, "statement has no effect",
      Reason => "Closing the parsed Doc reclaims owned memory; no SPARK effect");
   pragma Warnings
     (GNATprove, Off, "*is set by ""Close"" but not used after the call",
      Reason => "the Doc is nulled by Close and never read afterwards");
   --  The upload autorecap path needs only Save_Autorecap's Summary_Id (for the
   --  recap line); the parallel Diary_Id is a valid output this caller ignores.
   pragma Warnings
     (GNATprove, Off, "*is set by ""Save_Autorecap"" but not used after the call",
      Reason => "this caller uses only Summary_Id, not the parallel Diary_Id");

   package MS renames Memcp.Store;
   package MJ renames Memcp.Json;
   package MR renames Memcp.Resources;
   use type MS.Op_Status;
   use type MS.Summary_Ptr;

   function Q (S : String) return String renames MJ.Q;
   function N (V : Interfaces.Integer_64) return String renames MJ.N;
   function F (V : Interfaces.IEEE_Float_64) return String renames MJ.F;

   subtype Result_Ptr is Spark_Mcp.Tools.Result_Ptr;

   ----------------------
   -- Result builders  --
   ----------------------

   --  Success/Failure ownership allocations. OK guards Max_Field so a
   --  pathologically large payload degrades to an Internal_Error rather than
   --  tripping the Invocation_Result predicate.
   function OK (Content : String) return Result_Ptr is
   begin
      if Content'Length > Spark_Mcp.Max_Field then
         return new Spark_Mcp.Tools.Invocation_Result'
           (Spark_Mcp.Tools.Failure (Internal_Error, "result too large"));
      end if;
      return new Spark_Mcp.Tools.Invocation_Result'
        (Spark_Mcp.Tools.Success (Content));
   end OK;

   --  The builder-fed overload: a serializer that overflowed the field budget
   --  truncated its JSON at the cap, so its Value is malformed. Consulting
   --  Overflowed is the ONLY reliable signal -- Value'Length is bounded by
   --  Max_Field by construction (Memcp.Text.Length's postcondition), so a
   --  length check can never catch a payload truncated exactly at the cap.
   --  Emitting truncated JSON as a Success is the bug this overload closes.
   function OK (Buf : Memcp.Text.Builder) return Result_Ptr is
   begin
      if Memcp.Text.Overflowed (Buf) then
         return new Spark_Mcp.Tools.Invocation_Result'
           (Spark_Mcp.Tools.Failure (Internal_Error, "result too large"));
      end if;
      return new Spark_Mcp.Tools.Invocation_Result'
        (Spark_Mcp.Tools.Success (Memcp.Text.Value (Buf)));
   end OK;

   function Err (Code : Error_Code; Msg : String) return Result_Ptr is
     (new Spark_Mcp.Tools.Invocation_Result'
        (Spark_Mcp.Tools.Failure
           (Code, (if Msg'Length > Spark_Mcp.Max_Field then "error" else Msg))));

   --  A JSON boolean literal.
   function B (V : Boolean) return String is (if V then "true" else "false");

   --  Clamp a JSON integer to a Natural count (negatives -> 0).
   function To_Nat (V : Interfaces.Integer_64) return Natural is
     (if V <= 0 then 0
      elsif V >= Interfaces.Integer_64 (Natural'Last) then Natural'Last
      else Natural (V));

   --  True once the Resources' Store is open; every tool needs it.
   function Ready (R : MR.Resources) return Boolean is (MR.Is_Open (R));

   --  A character Python's str.strip() treats as whitespace (ASCII subset:
   --  space plus HT/LF/VT/FF/CR).
   function Is_Space (C : Character) return Boolean is
     (C = ' ' or else C in ASCII.HT .. ASCII.CR);

   --  True when S is empty or entirely whitespace -- i.e. Python's
   --  `not (v and v.strip())`. save() uses this so a tab/newline-only diary or
   --  summary is rejected; Ada.Strings.Fixed.Trim strips only spaces and would
   --  let it through.
   function Blank (S : String) return Boolean is
     (for all I in S'Range => Is_Space (S (I)));

   --  A pragmatic ISO-8601 check mirroring datetime.fromisoformat for the
   --  timestamps this server stores: a YYYY-MM-DD date, optionally followed by
   --  a 'T'/' ' separator and an HH:MM[...] time. A malformed since/until is
   --  rejected with invalid-params rather than silently mis-filtering the
   --  store's lexical created_at comparison (server.py raises ValueError here).
   function Valid_Timestamp (S : String) return Boolean is
      Len : constant Natural := S'Length;

      --  The 1-based Pth character of S, or NUL past the end.
      function At_Pos (P : Positive) return Character is
        (if P <= Len then S (S'First + (P - 1)) else ASCII.NUL);

      function Is_Digit (P : Positive) return Boolean is
        (At_Pos (P) in '0' .. '9');

      --  The two-digit field at P, P+1 as a number, or -1 if not two digits.
      --  Only ever called with small literal positions; the bound keeps the
      --  P + 1 arithmetic overflow-free.
      function Two (P : Positive) return Integer is
        (if Is_Digit (P) and then Is_Digit (P + 1)
         then (Character'Pos (At_Pos (P)) - Character'Pos ('0')) * 10
              + (Character'Pos (At_Pos (P + 1)) - Character'Pos ('0'))
         else -1)
        with Pre => P < Positive'Last;

      Mon, Day, Hr, Mn : Integer;
   begin
      --  Date: YYYY-MM-DD, at least 10 characters.
      if Len < 10 then
         return False;
      end if;
      for P in Positive range 1 .. 4 loop
         if not Is_Digit (P) then
            return False;
         end if;
      end loop;
      if At_Pos (5) /= '-' or else At_Pos (8) /= '-' then
         return False;
      end if;
      Mon := Two (6);
      Day := Two (9);
      if Mon not in 1 .. 12 or else Day not in 1 .. 31 then
         return False;
      end if;

      if Len = 10 then
         return True;   --  date only
      end if;

      --  Separator + HH:MM.
      if At_Pos (11) /= 'T' and then At_Pos (11) /= ' ' then
         return False;
      end if;
      Hr := Two (12);
      if At_Pos (14) /= ':' then
         return False;
      end if;
      Mn := Two (15);
      if Hr not in 0 .. 23 or else Mn not in 0 .. 59 then
         return False;
      end if;

      --  Anything after HH:MM (seconds, fraction, timezone) must come from the
      --  ISO time/offset alphabet -- enough to reject garbage without
      --  re-deriving the full grammar.
      for P in Positive range 17 .. Len loop
         if At_Pos (P) not in '0' .. '9'
           and then At_Pos (P) /= ':'
           and then At_Pos (P) /= '.'
           and then At_Pos (P) /= '+'
           and then At_Pos (P) /= '-'
           and then At_Pos (P) /= 'Z'
         then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Timestamp;

   -------------------------------------
   -- save leaked-parameter salvage --
   -------------------------------------

   --  Port of server.py's _salvage_leaked_params. When a model emits a save()
   --  whose diary or summary value has swallowed its sibling parameter across a
   --  leaked tag boundary -- ...real</parameter><parameter name="diary">... --
   --  split it back apart and save, rather than reject the whole call. A save is
   --  usually the terminal turn of a session, so rejecting a leaked save (as the
   --  strict path would) can lose the memory with no retry turn left.
   --
   --  SPARK has no regex, so this is a narrow literal-boundary scanner matching
   --  the concrete leak shape, case-insensitively:
   --    </parameter|summary|diary>        (whitespace tolerated before '>')
   --    <parameter name="summary|diary">   (either quote; whitespace tolerated
   --                                        between tags, around name and '=')
   --  A leading `ns:`-style namespace prefix on either tag name is tolerated,
   --  matching server.py's _LEAK_BOUNDARY/_TRAILING_CLOSE `(?:[A-Za-z][\w.\-]*:)?`.

   --  ASCII case-fold, so tag matching ignores case like Python's re.IGNORECASE.
   function Lower (C : Character) return Character is
     (if C in 'A' .. 'Z'
      then Character'Val (Character'Pos (C) + 32) else C);

   --  True when the already-lowercase literal Lit occurs in S at index I,
   --  case-folded and wholly in bounds. The length guard makes the per-char
   --  index arithmetic range- and overflow-safe.
   function Lit_At (S : String; I : Positive; Lit : String) return Boolean is
     (I in S'Range
      and then Lit'Length <= S'Last - I + 1
      and then (for all K in Lit'Range =>
                  Lower (S (I + (K - Lit'First))) = Lit (K)));

   --  The index just past E, or 0 when E is the last character (an end
   --  sentinel that keeps every cursor a valid index and never forms S'Last+1).
   function After (S : String; E : Positive) return Natural is
     (if E < S'Last then E + 1 else 0)
     with Pre  => E in S'Range,
          Post => After'Result = 0 or else After'Result in S'Range;

   --  First non-whitespace index at or after From, or 0 if the run reaches the
   --  end of S.
   function Skip_Ws (S : String; From : Positive) return Natural
     with Pre  => From in S'Range,
          Post => Skip_Ws'Result = 0
                  or else Skip_Ws'Result in From .. S'Last;
   function Skip_Ws (S : String; From : Positive) return Natural is
   begin
      for J in From .. S'Last loop
         if not Is_Space (S (J)) then
            return J;
         end if;
      end loop;
      return 0;
   end Skip_Ws;

   --  Skip an optional `ns:`-style namespace prefix at P -- Python's
   --  `(?:[A-Za-z][\w.\-]*:)?`, i.e. a letter, then name characters, then a
   --  colon. Returns the index of the first tag-name character (= P when there
   --  is no prefix), or 0 if such a prefix runs to the end of S with nothing
   --  after it.
   function Skip_Prefix (S : String; P : Positive) return Natural
     with Pre  => P in S'Range,
          Post => Skip_Prefix'Result = 0
                  or else Skip_Prefix'Result in S'Range;
   function Skip_Prefix (S : String; P : Positive) return Natural is
      R : Positive := P;
   begin
      if S (P) not in 'A' .. 'Z' | 'a' .. 'z' then
         return P;   --  not a prefix start: the tag name begins at P
      end if;
      --  Advance over the prefix token [A-Za-z][A-Za-z0-9_.-]*.
      while R < S'Last
        and then S (R + 1) in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9'
                              | '_' | '.' | '-'
      loop
         pragma Loop_Invariant (R in S'Range);
         pragma Loop_Variant (Increases => R);
         R := R + 1;
      end loop;
      --  A ':' immediately after makes P .. R a namespace prefix.
      if R < S'Last and then S (R + 1) = ':' then
         return After (S, R + 1);
      end if;
      return P;   --  no terminating colon: not a prefix, name starts at P
   end Skip_Prefix;

   --  At P, skip an optional namespace prefix, then match a close-tag name
   --  (parameter|summary|diary) case-folded. Returns the index of the name's
   --  last character, or 0 on no match. Shared by Try_At and Clean so the tag
   --  vocabulary lives in one place.
   function Match_Tag_Name (S : String; P : Positive) return Natural
     with Pre  => P in S'Range,
          Post => Match_Tag_Name'Result = 0
                  or else Match_Tag_Name'Result in S'Range;
   function Match_Tag_Name (S : String; P : Positive) return Natural is
      Q : constant Natural := Skip_Prefix (S, P);
   begin
      if Q = 0 then
         return 0;
      elsif Lit_At (S, Q, "parameter") then
         return Q + 8;
      elsif Lit_At (S, Q, "summary") then
         return Q + 6;
      elsif Lit_At (S, Q, "diary") then
         return Q + 4;
      else
         return 0;
      end if;
   end Match_Tag_Name;

   --  Scan S for the first leak boundary. On Found, S (B_Start .. B_End) is the
   --  matched boundary and Sib_Is_Diary tells which sibling the open tag named
   --  (True => "diary", False => "summary"); B_Start/B_End are placeholders
   --  otherwise.
   procedure Find_Leak_Boundary
     (S            : String;
      Found        : out Boolean;
      B_Start      : out Positive;
      B_End        : out Positive;
      Sib_Is_Diary : out Boolean)
   with Post => (if Found then B_Start in S'Range and then B_End in S'Range);

   procedure Find_Leak_Boundary
     (S            : String;
      Found        : out Boolean;
      B_Start      : out Positive;
      B_End        : out Positive;
      Sib_Is_Diary : out Boolean)
   is
      --  Try to match a boundary starting at I. On Ok, E is the index of the
      --  closing '>' of the open tag and Diar reports the named sibling.
      procedure Try_At
        (I    : Positive;
         Ok   : out Boolean;
         E    : out Positive;
         Diar : out Boolean)
      with Pre  => I in S'Range,
           Post => (if Ok then E in S'Range);

      procedure Try_At
        (I    : Positive;
         Ok   : out Boolean;
         E    : out Positive;
         Diar : out Boolean)
      is
         P     : Natural;
         Quote : Character;
         Adv   : Boolean;

         --  Advance P over whitespace to the next non-ws char. Adv is False
         --  (caller bails) when the run reaches the end of S.
         procedure Skip_Blanks (P : in out Natural; Adv : out Boolean)
           with Pre  => P in S'Range,
                Post => (if Adv then P in S'Range)
         is
            Q : constant Natural := Skip_Ws (S, P);
         begin
            Adv := Q /= 0;
            if Adv then
               P := Q;
            end if;
         end Skip_Blanks;

         --  Skip whitespace, require the single character C, and advance P
         --  past it. Adv is False (caller bails) when the run ends, the char
         --  differs, or nothing follows C.
         procedure Expect (P : in out Natural; C : Character; Adv : out Boolean)
           with Pre  => P in S'Range,
                Post => (if Adv then P in S'Range)
         is
            Q : constant Natural := Skip_Ws (S, P);
         begin
            if Q = 0 or else S (Q) /= C then
               Adv := False;
            else
               P   := After (S, Q);
               Adv := P /= 0;
            end if;
         end Expect;

      begin
         Ok   := False;
         E    := I;
         Diar := False;

         --  Close tag: "</" [ns:] (parameter|summary|diary) optional-ws ">".
         if not Lit_At (S, I, "</") then
            return;
         end if;
         P := After (S, I + 1);
         if P = 0 then
            return;
         end if;
         declare
            NE : constant Natural := Match_Tag_Name (S, P);
         begin
            if NE = 0 then
               return;
            end if;
            P := After (S, NE);
         end;
         if P = 0 then
            return;
         end if;
         Expect (P, '>', Adv);
         if not Adv then
            return;
         end if;

         --  Optional whitespace between the tags, then the open tag:
         --  "<" [ns:] "parameter".
         Skip_Blanks (P, Adv);
         if not Adv then
            return;
         end if;
         if S (P) /= '<' then
            return;
         end if;
         P := After (S, P);
         if P = 0 then
            return;
         end if;
         declare
            Q : constant Natural := Skip_Prefix (S, P);
         begin
            if Q = 0 or else not Lit_At (S, Q, "parameter") then
               return;
            end if;
            P := After (S, Q + 8);
         end;
         if P = 0 or else not Is_Space (S (P)) then
            return;   --  server.py requires at least one space after 'parameter'
         end if;

         --  "name" optional-ws "=" optional-ws quote.
         Skip_Blanks (P, Adv);
         if not Adv then
            return;
         end if;
         if not Lit_At (S, P, "name") then
            return;
         end if;
         P := After (S, P + 3);
         if P = 0 then
            return;
         end if;
         Expect (P, '=', Adv);
         if not Adv then
            return;
         end if;
         Skip_Blanks (P, Adv);
         if not Adv then
            return;
         end if;
         if S (P) /= '"' and then S (P) /= ''' then
            return;
         end if;
         Quote := S (P);
         P := After (S, P);
         if P = 0 then
            return;
         end if;

         --  Sibling name, then the matching closing quote.
         if Lit_At (S, P, "summary") then
            Diar := False;
            P := After (S, P + 6);
         elsif Lit_At (S, P, "diary") then
            Diar := True;
            P := After (S, P + 4);
         else
            return;
         end if;
         if P = 0 or else S (P) /= Quote then
            return;
         end if;
         P := After (S, P);
         if P = 0 then
            return;
         end if;

         --  Optional whitespace, then the closing '>' of the open tag.
         declare
            Q : constant Natural := Skip_Ws (S, P);
         begin
            if Q = 0 or else S (Q) /= '>' then
               return;
            end if;
            E  := Q;
            Ok := True;
         end;
      end Try_At;

   begin
      Found        := False;
      B_Start      := 1;
      B_End        := 1;
      Sib_Is_Diary := False;
      if S'Length = 0 then
         return;
      end if;
      for I in S'Range loop
         declare
            Ok   : Boolean;
            E    : Positive;
            Diar : Boolean;
         begin
            Try_At (I, Ok, E, Diar);
            if Ok then
               Found        := True;
               B_Start      := I;
               B_End        := E;
               Sib_Is_Diary := Diar;
               return;
            end if;
         end;
      end loop;
   end Find_Leak_Boundary;

   --  Python's str.strip(): the text with leading/trailing ASCII whitespace
   --  removed (or "" when all-whitespace).
   function Strip (S : String) return String is
      F : Natural := 0;
   begin
      for I in S'Range loop
         if not Is_Space (S (I)) then
            F := I;
            exit;
         end if;
      end loop;
      if F = 0 then
         return "";
      end if;
      declare
         L : Positive := F;
      begin
         for I in reverse F .. S'Last loop
            if not Is_Space (S (I)) then
               L := I;
               exit;
            end if;
         end loop;
         return S (F .. L);
      end;
   end Strip;

   --  server.py's _TRAILING_CLOSE.sub("", value).strip() applied to a salvaged
   --  half: drop one trailing </parameter|summary|diary> close tag (whitespace
   --  tolerated around it) plus surrounding whitespace.
   function Clean (Raw : String) return String is
      S  : constant String := Strip (Raw);
      LT : Natural := 0;
   begin
      if S'Length = 0 or else S (S'Last) /= '>' then
         return S;
      end if;
      --  The trailing close tag, if any, opens at the last '<' in S.
      for I in reverse S'Range loop
         if S (I) = '<' then
            LT := I;
            exit;
         end if;
      end loop;
      if LT = 0 or else not Lit_At (S, LT, "</") or else LT > S'Last - 2 then
         return S;
      end if;
      declare
         P  : constant Positive := LT + 2;   --  the close-tag name
         NE : constant Natural := Match_Tag_Name (S, P);
      begin
         if NE = 0 then
            return S;
         end if;
         declare
            Nxt : constant Natural := After (S, NE);
            G   : Natural;
         begin
            if Nxt = 0 then
               return S;   --  name ran to end; S(S'Last) is '>', so impossible
            end if;
            G := Skip_Ws (S, Nxt);
            --  Only ws may separate the name from the '>' already at S'Last.
            if G = S'Last then
               return Strip (S (S'First .. LT - 1));
            else
               return S;
            end if;
         end;
      end;
   end Clean;

   --  server.py's _salvage_leaked_params, tightened against a false positive.
   --  A leak's defining signature is that the swallowed sibling "arrives
   --  missing", so we only split when the boundary's *named* sibling slot is
   --  actually empty: diary carrying a `name="summary"` boundary while summary
   --  is empty, or summary carrying a `name="diary"` boundary while diary is
   --  empty. When the model supplied both fields, a boundary-looking sequence
   --  is legitimate content (e.g. a memory that quotes this leak format), so
   --  the value is left intact rather than truncated. (server.py splits
   --  regardless and would drop the after-boundary text of such a value; this
   --  narrowing only changes that both-fields-present case, never a genuine
   --  leak, and matches the existing test_tools regression.)
   --
   --  On a split the two halves are handed back through bounded builders (their
   --  content is a slice of the input, so within the Max_Field budget) and Did
   --  is True. With no split Did is False and the builders are only Reset (no
   --  O(n) copy): the caller reuses the original strings verbatim.
   procedure Salvage
     (Diary       : String;
      Summary     : String;
      Out_Diary   : out Memcp.Text.Builder;
      Out_Summary : out Memcp.Text.Builder;
      Did         : out Boolean)
   is
      procedure Emit (B : out Memcp.Text.Builder; Text : String) is
      begin
         Memcp.Text.Reset (B);
         Memcp.Text.Add (B, Text);
      end Emit;

      Found : Boolean;
      BS    : Positive;
      BE    : Positive;
      SibD  : Boolean;
   begin
      --  Diary swallowed the (missing) summary across a `name="summary"`
      --  boundary. A `name="diary"` boundary inside diary itself names the
      --  scanned field and so fails the empty-sibling test -- treated as
      --  legitimate content, not a leak.
      Find_Leak_Boundary (Diary, Found, BS, BE, SibD);
      if Found and then not SibD and then Summary'Length = 0 then
         declare
            Before : constant String := Clean (Diary (Diary'First .. BS - 1));
            Aft : constant String :=
              Clean ((if BE < Diary'Last then Diary (BE + 1 .. Diary'Last)
                      else ""));
         begin
            Emit (Out_Diary, Before);
            Emit (Out_Summary, Aft);
         end;
         Did := True;
         return;
      end if;

      --  Summary swallowed the (missing) diary across a `name="diary"`
      --  boundary (the common serialization glitch).
      Find_Leak_Boundary (Summary, Found, BS, BE, SibD);
      if Found and then SibD and then Diary'Length = 0 then
         declare
            Before : constant String :=
              Clean (Summary (Summary'First .. BS - 1));
            Aft : constant String :=
              Clean ((if BE < Summary'Last then Summary (BE + 1 .. Summary'Last)
                      else ""));
         begin
            Emit (Out_Summary, Before);
            Emit (Out_Diary, Aft);
         end;
         Did := True;
         return;
      end if;

      --  No salvageable boundary: signal the caller to reuse the inputs.
      Memcp.Text.Reset (Out_Diary);
      Memcp.Text.Reset (Out_Summary);
      Did := False;
   end Salvage;

   ----------------------
   -- List serializers --
   ----------------------

   --  Each builds its JSON array into the caller's bounded Memcp.Text builder;
   --  OK (Buf) then emits it only if it did not overflow the field budget.

   procedure Ser_Diary (V : MS.Diary_Entry_List; Buf : out Memcp.Text.Builder)
   is
   begin
      Memcp.Text.Reset (Buf);
      Memcp.Text.Add (Buf, "[");
      for I in MS.Diary_Vectors.First_Index (V)
               .. MS.Diary_Vectors.Last_Index (V)
      loop
         declare
            E : constant MS.Diary_Entry := MS.Diary_Vectors.Element (V, I);
         begin
            if I > MS.Diary_Vectors.First_Index (V) then
               Memcp.Text.Add (Buf, ",");
            end if;
            Memcp.Text.Add (Buf, "{""diary_id"":");
            Memcp.Text.Add (Buf, N (E.Id));
            Memcp.Text.Add (Buf, ",""project"":");
            Memcp.Text.Add (Buf, Q (E.Project));
            Memcp.Text.Add (Buf, ",""summary_id"":");
            Memcp.Text.Add (Buf, N (E.Summary_Id));
            Memcp.Text.Add (Buf, ",""session_id"":");
            Memcp.Text.Add
              (Buf, (if E.Has_Session then Q (E.Session) else "null"));
            Memcp.Text.Add (Buf, ",""created_at"":");
            Memcp.Text.Add (Buf, Q (E.Created_At));
            Memcp.Text.Add (Buf, ",""headline"":");
            Memcp.Text.Add (Buf, Q (E.Headline));
            Memcp.Text.Add (Buf, ",""kind"":");
            Memcp.Text.Add (Buf, Q (E.Kind));
            Memcp.Text.Add (Buf, "}");
         end;
      end loop;
      Memcp.Text.Add (Buf, "]");
   end Ser_Diary;

   procedure Ser_Projects
     (V : MS.Project_Info_List; Buf : out Memcp.Text.Builder)
   is
   begin
      Memcp.Text.Reset (Buf);
      Memcp.Text.Add (Buf, "[");
      for I in MS.Project_Vectors.First_Index (V)
               .. MS.Project_Vectors.Last_Index (V)
      loop
         declare
            E : constant MS.Project_Info := MS.Project_Vectors.Element (V, I);
         begin
            if I > MS.Project_Vectors.First_Index (V) then
               Memcp.Text.Add (Buf, ",");
            end if;
            Memcp.Text.Add (Buf, "{""project"":");
            Memcp.Text.Add (Buf, Q (E.Name));
            Memcp.Text.Add (Buf, ",""diary_count"":");
            Memcp.Text.Add (Buf, N (E.Diary_Count));
            Memcp.Text.Add (Buf, ",""latest_at"":");
            Memcp.Text.Add
              (Buf, (if E.Has_Latest then Q (E.Latest_At) else "null"));
            Memcp.Text.Add (Buf, "}");
         end;
      end loop;
      Memcp.Text.Add (Buf, "]");
   end Ser_Projects;

   procedure Ser_Summary_Hits
     (V : MS.Summary_Hit_List; Buf : out Memcp.Text.Builder)
   is
   begin
      Memcp.Text.Reset (Buf);
      Memcp.Text.Add (Buf, "[");
      for I in MS.Summary_Hit_Vectors.First_Index (V)
               .. MS.Summary_Hit_Vectors.Last_Index (V)
      loop
         declare
            E : constant MS.Summary_Hit :=
              MS.Summary_Hit_Vectors.Element (V, I);
         begin
            if I > MS.Summary_Hit_Vectors.First_Index (V) then
               Memcp.Text.Add (Buf, ",");
            end if;
            Memcp.Text.Add (Buf, "{""summary_id"":");
            Memcp.Text.Add (Buf, N (E.Id));
            Memcp.Text.Add (Buf, ",""project"":");
            Memcp.Text.Add (Buf, Q (E.Project));
            Memcp.Text.Add (Buf, ",""session_id"":");
            Memcp.Text.Add
              (Buf, (if E.Has_Session then Q (E.Session) else "null"));
            Memcp.Text.Add (Buf, ",""created_at"":");
            Memcp.Text.Add (Buf, Q (E.Created_At));
            Memcp.Text.Add (Buf, ",""headline"":");
            Memcp.Text.Add (Buf, Q (E.Headline));
            Memcp.Text.Add (Buf, ",""kind"":");
            Memcp.Text.Add (Buf, Q (E.Kind));
            Memcp.Text.Add (Buf, ",""distance"":");
            Memcp.Text.Add (Buf, F (E.Distance));
            Memcp.Text.Add (Buf, "}");
         end;
      end loop;
      Memcp.Text.Add (Buf, "]");
   end Ser_Summary_Hits;

   procedure Ser_Chunk_Hits
     (V : MS.Chunk_Hit_List; Buf : out Memcp.Text.Builder)
   is
   begin
      Memcp.Text.Reset (Buf);
      Memcp.Text.Add (Buf, "[");
      for I in MS.Chunk_Hit_Vectors.First_Index (V)
               .. MS.Chunk_Hit_Vectors.Last_Index (V)
      loop
         declare
            E : constant MS.Chunk_Hit := MS.Chunk_Hit_Vectors.Element (V, I);
         begin
            if I > MS.Chunk_Hit_Vectors.First_Index (V) then
               Memcp.Text.Add (Buf, ",");
            end if;
            Memcp.Text.Add (Buf, "{""chunk_id"":");
            Memcp.Text.Add (Buf, N (E.Id));
            Memcp.Text.Add (Buf, ",""session_row_id"":");
            Memcp.Text.Add (Buf, N (E.Session_Row_Id));
            Memcp.Text.Add (Buf, ",""session_id"":");
            Memcp.Text.Add (Buf, Q (E.Session));
            Memcp.Text.Add (Buf, ",""project"":");
            Memcp.Text.Add (Buf, Q (E.Project));
            Memcp.Text.Add (Buf, ",""ordinal"":");
            Memcp.Text.Add (Buf, N (E.Ordinal));
            Memcp.Text.Add (Buf, ",""body"":");
            Memcp.Text.Add (Buf, Q (E.Content));
            Memcp.Text.Add (Buf, ",""created_at"":");
            Memcp.Text.Add (Buf, Q (E.Created_At));
            Memcp.Text.Add (Buf, ",""distance"":");
            Memcp.Text.Add (Buf, F (E.Distance));
            Memcp.Text.Add (Buf, "}");
         end;
      end loop;
      Memcp.Text.Add (Buf, "]");
   end Ser_Chunk_Hits;

   --  fetch_turns: the turn's session_id is the request argument (the Chunk
   --  record has no session field), matching server.py.
   procedure Ser_Turns
     (V : MS.Chunk_List; Session_Id : String; Buf : out Memcp.Text.Builder)
   is
   begin
      Memcp.Text.Reset (Buf);
      Memcp.Text.Add (Buf, "[");
      for I in MS.Chunk_Vectors.First_Index (V)
               .. MS.Chunk_Vectors.Last_Index (V)
      loop
         declare
            E : constant MS.Chunk := MS.Chunk_Vectors.Element (V, I);
         begin
            if I > MS.Chunk_Vectors.First_Index (V) then
               Memcp.Text.Add (Buf, ",");
            end if;
            Memcp.Text.Add (Buf, "{""session_id"":");
            Memcp.Text.Add (Buf, Q (Session_Id));
            Memcp.Text.Add (Buf, ",""project"":");
            Memcp.Text.Add (Buf, Q (E.Project));
            Memcp.Text.Add (Buf, ",""ordinal"":");
            Memcp.Text.Add (Buf, N (E.Ordinal));
            Memcp.Text.Add (Buf, ",""body"":");
            Memcp.Text.Add (Buf, Q (E.Content));
            Memcp.Text.Add (Buf, ",""created_at"":");
            Memcp.Text.Add (Buf, Q (E.Created_At));
            Memcp.Text.Add (Buf, "}");
         end;
      end loop;
      Memcp.Text.Add (Buf, "]");
   end Ser_Turns;

   -----------
   -- Embed --
   -----------

   --  An embedder is usable when a model is loaded OR we are replaying recorded
   --  vectors (conformance). Every embedding-gate consults this.
   function Embedder_Available (R : MR.Resources) return Boolean is
     (MR.Embedder_Loaded (R) or else Memcp.Replay.Enabled);

   --  Embed one text. Under replay the recorded vector is injected by text
   --  lookup (a miss is counted and surfaced by the harness); otherwise the
   --  candle engine runs. A procedure -- a SPARK function may not have
   --  the side effect of counting a replay miss.
   procedure Embed_One
     (R : MR.Resources; Text : String; Emb : out Candle_Spark.Embedding)
   is
      Found : Boolean;
   begin
      if Memcp.Replay.Enabled then
         Memcp.Replay.Lookup_Embedding (Text, Emb, Found);
         if not Found then
            --  A replay run expects every embedding to be pre-recorded; a miss
            --  means the corpus is out of step with the request stream and the
            --  zero fallback vector will skew similarity. Record it -- the
            --  Python source stays silent here, but the whole point of replay
            --  is determinism, so a miss is worth surfacing.
            Memcp.Log.Warning
              ("replay: no recorded embedding for query text; "
               & "using zero fallback vector");
         end if;
      else
         Emb := MR.Embed (R, Text);
      end if;
   end Embed_One;

   --  Embed Text, or Ok => False (zero vector) when no embedder is available or
   --  Text is empty. The tool then reports the appropriate error.
   procedure Embed_Query
     (R    : MR.Resources;
      Text : String;
      Emb  : out Candle_Spark.Embedding;
      Ok   : out Boolean)
   is
   begin
      if Text'Length = 0 or else not Embedder_Available (R) then
         Emb := [others => 0.0];
         Ok  := False;
      else
         Embed_One (R, Text, Emb);
         Ok := True;
      end if;
   end Embed_Query;

   -----------
   -- Tools --
   -----------

   procedure Do_Recent
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr)
   is
      D       : MJ.Doc;
      Entries : MS.Diary_Entry_List;
      St      : MS.Op_Status;
      Buf     : Memcp.Text.Builder;
   begin
      MJ.Open (D, Arguments);
      if not MJ.Has (D, "projects") then
         --  server.py makes `projects` a required argument; an omitted list is
         --  a client error, not a silent empty result (an explicit empty array
         --  still legitimately yields []).
         Result := Err (Invalid_Params, "recent: 'projects' is required");
      else
         MR.Recent_Diary
           (R, MJ.Get_Names (D, "projects"), To_Nat (MJ.Get_Int (D, "n", 5)),
            Entries, St);
         if St = MS.Success then
            Ser_Diary (Entries, Buf);
            Result := OK (Buf);
         else
            Result := Err (Internal_Error, "recent: store error");
         end if;
      end if;
      MJ.Close (D);
   end Do_Recent;

   procedure Do_List_Projects
     (R : MR.Resources; Result : out Result_Ptr)
   is
      Projs : MS.Project_Info_List;
      St    : MS.Op_Status;
      Buf   : Memcp.Text.Builder;
   begin
      MR.List_Projects (R, Projs, St);
      if St = MS.Success then
         Ser_Projects (Projs, Buf);
         Result := OK (Buf);
      else
         Result := Err (Internal_Error, "list_projects: store error");
      end if;
   end Do_List_Projects;

   procedure Do_Save
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr)
   is
      D : MJ.Doc;
   begin
      MJ.Open (D, Arguments);
      declare
         Project    : constant String := MJ.Get_Str (D, "project");
         Diary_In   : constant String := MJ.Get_Str (D, "diary");
         Summary_In : constant String := MJ.Get_Str (D, "summary");
         Bd_Buf     : Memcp.Text.Builder;
         Sm_Buf     : Memcp.Text.Builder;
         Salvaged   : Boolean;
      begin
         --  Recover a leaked <parameter> boundary before the emptiness gate:
         --  a save is usually a session's terminal turn, so splitting and
         --  saving beats rejecting (which loses the memory with no retry).
         Salvage (Diary_In, Summary_In, Bd_Buf, Sm_Buf, Salvaged);
         if Salvaged then
            Memcp.Log.Warning
              ("save: recovered a leaked <parameter> boundary; "
               & "split diary/summary");
         end if;
         declare
            --  On the common no-leak path Salvage leaves the builders empty;
            --  reuse the original arguments rather than round-tripping them
            --  through the builders.
            Diary   : constant String :=
              (if Salvaged then Memcp.Text.Value (Bd_Buf) else Diary_In);
            Summary : constant String :=
              (if Salvaged then Memcp.Text.Value (Sm_Buf) else Summary_In);
            Emb     : Candle_Spark.Embedding;
            Emb_Ok  : Boolean;
         begin
            if Project'Length = 0 then
               Result := Err (Invalid_Params, "save: 'project' is required");
            elsif Blank (Diary) or else Blank (Summary) then
               Result := Err
                 (Invalid_Params,
                  "save: 'diary' and 'summary' are required, non-empty, and "
                  & "separate string arguments");
            else
               Embed_Query (R, Summary, Emb, Emb_Ok);
               if not Emb_Ok then
                  Result := Err
                    (Internal_Error,
                     "save: embedder unavailable (set MEMCP_MODEL_PATH)");
               else
                  declare
                     Res     : MS.Save_Result;
                     St      : MS.Op_Status;
                     Rep     : constant Boolean :=
                       Memcp.Replay.Enabled and then Memcp.Replay.Has_Clock;
                     Arg_Cre : constant Boolean := MJ.Has_Str (D, "created_at");
                     Has_Cre : constant Boolean := Rep or else Arg_Cre;
                     TS      : constant String :=
                       (if Rep then Memcp.Replay.Peek_Clock
                        elsif Arg_Cre then MJ.Get_Str (D, "created_at")
                        else "");
                  begin
                     if Rep then
                        Memcp.Replay.Advance_Clock;
                     end if;
                     MR.Save
                       (R,
                        Project      => Project,
                        Diary_Body   => Diary,
                        Summary_Body => Summary,
                        Embedding    => Emb,
                        Has_Session  => MJ.Has_Str (D, "session_id"),
                        Session_Id   => MJ.Get_Str (D, "session_id"),
                        Has_Created  => Has_Cre,
                        Created_At   => TS,
                        Result       => Res,
                        Status       => St);
                     if St = MS.Success then
                        Result := OK
                          ("{""summary_id"":" & N (Res.Summary_Id)
                           & ",""diary_id"":" & N (Res.Diary_Id)
                           & ",""already_existed"":" & B (Res.Already_Existed)
                           & ",""replaced"":" & B (Res.Replaced) & "}");
                     else
                        Result := Err (Internal_Error, "save: store error");
                     end if;
                  end;
               end if;
            end if;
         end;
      end;
      MJ.Close (D);
   end Do_Save;

   procedure Do_Forget
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr)
   is
      D : MJ.Doc;
   begin
      MJ.Open (D, Arguments);
      if not MJ.Has_Int (D, "summary_id") then
         Result := Err (Invalid_Params, "forget: 'summary_id' is required");
      else
         declare
            Deleted : Boolean;
            St      : MS.Op_Status;
         begin
            MR.Forget_Summary
              (R, MS.Row_Id (MJ.Get_Int (D, "summary_id", 0)), Deleted, St);
            if St = MS.Success then
               Result := OK ("{""deleted"":" & B (Deleted) & "}");
            else
               Result := Err (Internal_Error, "forget: store error");
            end if;
         end;
      end if;
      MJ.Close (D);
   end Do_Forget;

   procedure Do_Search
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr)
   is
      D : MJ.Doc;
   begin
      MJ.Open (D, Arguments);
      declare
         Query  : constant String := MJ.Get_Str (D, "query");
         Emb    : Candle_Spark.Embedding;
         Emb_Ok : Boolean;
      begin
         if Query'Length = 0 then
            Result := Err (Invalid_Params, "search: 'query' is required");
         elsif (MJ.Has_Str (D, "since")
                and then not Valid_Timestamp (MJ.Get_Str (D, "since")))
           or else (MJ.Has_Str (D, "until")
                    and then not Valid_Timestamp (MJ.Get_Str (D, "until")))
         then
            Result := Err
              (Invalid_Params,
               "search: 'since'/'until' must be ISO-8601 timestamps");
         else
            Embed_Query (R, Query, Emb, Emb_Ok);
            if not Emb_Ok then
               Result := Err
                 (Internal_Error,
                  "search: embedder unavailable (set MEMCP_MODEL_PATH)");
            else
               declare
                  Hits : MS.Summary_Hit_List;
                  St   : MS.Op_Status;
                  Buf  : Memcp.Text.Builder;
               begin
                  MR.Search_Summaries
                    (R,
                     Query_Emb => Emb,
                     Projects  => MJ.Get_Names (D, "projects"),
                     Limit     => To_Nat (MJ.Get_Int (D, "limit", 5)),
                     Has_Since => MJ.Has_Str (D, "since"),
                     Since     => MJ.Get_Str (D, "since"),
                     Has_Until => MJ.Has_Str (D, "until"),
                     Until_At  => MJ.Get_Str (D, "until"),
                     Result    => Hits,
                     Status    => St);
                  if St = MS.Success then
                     Ser_Summary_Hits (Hits, Buf);
                     Result := OK (Buf);
                  else
                     Result := Err (Internal_Error, "search: store error");
                  end if;
               end;
            end if;
         end if;
      end;
      MJ.Close (D);
   end Do_Search;

   procedure Do_Fetch_Summary
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr)
   is
      D : MJ.Doc;
   begin
      MJ.Open (D, Arguments);
      if not MJ.Has_Int (D, "summary_id") then
         Result :=
           Err (Invalid_Params, "fetch_summary: 'summary_id' is required");
      else
         declare
            Ptr : MS.Summary_Ptr;
            St  : MS.Op_Status;
            Id  : constant Interfaces.Integer_64 :=
              MJ.Get_Int (D, "summary_id", 0);
         begin
            MR.Fetch_Summary (R, MS.Row_Id (Id), Ptr, St);
            if St /= MS.Success then
               Result := Err (Internal_Error, "fetch_summary: store error");
            elsif Ptr = null then
               --  A miss is a valid negative answer, not a failure.
               Result := OK ("No summary found for id " & N (Id) & ".");
            else
               --  Built through the bounded builder: the body field can be
               --  large, so a raw concatenation could not be bounded for AoRTE.
               declare
                  Buf : Memcp.Text.Builder;
               begin
                  Memcp.Text.Reset (Buf);
                  Memcp.Text.Add (Buf, "{""summary_id"":");
                  Memcp.Text.Add (Buf, N (Ptr.Id));
                  Memcp.Text.Add (Buf, ",""project"":");
                  Memcp.Text.Add (Buf, Q (Ptr.Project));
                  Memcp.Text.Add (Buf, ",""session_id"":");
                  Memcp.Text.Add
                    (Buf,
                     (if Ptr.Has_Session then Q (Ptr.Session) else "null"));
                  Memcp.Text.Add (Buf, ",""created_at"":");
                  Memcp.Text.Add (Buf, Q (Ptr.Created_At));
                  Memcp.Text.Add (Buf, ",""headline"":");
                  Memcp.Text.Add (Buf, Q (Ptr.Headline));
                  Memcp.Text.Add (Buf, ",""body"":");
                  Memcp.Text.Add (Buf, Q (Ptr.Content));
                  Memcp.Text.Add (Buf, ",""kind"":");
                  Memcp.Text.Add (Buf, Q (Ptr.Kind));
                  Memcp.Text.Add (Buf, "}");
                  Result := OK (Buf);
               end;
            end if;
            MS.Free (Ptr);   --  null-safe; frees the hit, no-op on a miss/error
         end;
      end if;
      MJ.Close (D);
   end Do_Fetch_Summary;

   procedure Do_Fetch_Chunks
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr)
   is
      D : MJ.Doc;
   begin
      MJ.Open (D, Arguments);
      declare
         Query  : constant String := MJ.Get_Str (D, "query");
         Emb    : Candle_Spark.Embedding;
         Emb_Ok : Boolean;
      begin
         if Query'Length = 0 then
            Result := Err (Invalid_Params, "fetch_chunks: 'query' is required");
         elsif (MJ.Has_Str (D, "since")
                and then not Valid_Timestamp (MJ.Get_Str (D, "since")))
           or else (MJ.Has_Str (D, "until")
                    and then not Valid_Timestamp (MJ.Get_Str (D, "until")))
         then
            Result := Err
              (Invalid_Params,
               "fetch_chunks: 'since'/'until' must be ISO-8601 timestamps");
         else
            Embed_Query (R, Query, Emb, Emb_Ok);
            if not Emb_Ok then
               Result := Err
                 (Internal_Error,
                  "fetch_chunks: embedder unavailable (set MEMCP_MODEL_PATH)");
            else
               declare
                  Hits : MS.Chunk_Hit_List;
                  St   : MS.Op_Status;
                  Buf  : Memcp.Text.Builder;
               begin
                  MR.Search_Chunks
                    (R,
                     Query_Emb   => Emb,
                     Projects    => MJ.Get_Names (D, "projects"),
                     Session_Ids => MJ.Get_Names (D, "session_ids"),
                     Limit       => To_Nat (MJ.Get_Int (D, "limit", 5)),
                     Has_Since   => MJ.Has_Str (D, "since"),
                     Since       => MJ.Get_Str (D, "since"),
                     Has_Until   => MJ.Has_Str (D, "until"),
                     Until_At    => MJ.Get_Str (D, "until"),
                     Result      => Hits,
                     Status      => St);
                  if St = MS.Success then
                     Ser_Chunk_Hits (Hits, Buf);
                     Result := OK (Buf);
                  else
                     Result := Err (Internal_Error, "fetch_chunks: store error");
                  end if;
               end;
            end if;
         end if;
      end;
      MJ.Close (D);
   end Do_Fetch_Chunks;

   procedure Do_Fetch_Turns
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr)
   is
      D : MJ.Doc;
   begin
      MJ.Open (D, Arguments);
      declare
         Session  : constant String := MJ.Get_Str (D, "session_id");
         Last_V   : constant Interfaces.Integer_64 := MJ.Get_Int (D, "last", 0);
         --  `last` present at all (server.py's `tail is not None`), vs. a real
         --  positive tail. A non-positive `last` is neither absent nor a tail:
         --  server.py rejects it rather than folding it into "whole session".
         Has_Last : constant Boolean := MJ.Has_Int (D, "last");
         Has_Tail : constant Boolean := Has_Last and then Last_V > 0;
         Has_St   : constant Boolean := MJ.Has_Int (D, "start");
         Has_En   : constant Boolean := MJ.Has_Int (D, "end");
         --  Clamp a positive tail to Positive'Last (Last_V is 64-bit).
         Tail     : constant Positive :=
           (if Has_Tail then
              (if Last_V >= Interfaces.Integer_64 (Positive'Last)
               then Positive'Last else Positive (Last_V))
            else 1);
      begin
         if Session'Length = 0 then
            Result :=
              Err (Invalid_Params, "fetch_turns: 'session_id' is required");
         elsif Has_Last and then (Has_St or else Has_En) then
            --  server.py checks mutual exclusion on `tail is not None`, before
            --  the positivity check -- so this fires even for a non-positive
            --  `last` combined with start/end.
            Result := Err
              (Invalid_Params,
               "fetch_turns: 'last' cannot be combined with 'start'/'end'");
         elsif Has_Last and then Last_V <= 0 then
            Result := Err
              (Invalid_Params, "fetch_turns: 'last' must be positive");
         else
            declare
               Turns : MS.Chunk_List;
               St    : MS.Op_Status;
               Buf   : Memcp.Text.Builder;
            begin
               MR.Fetch_Turns
                 (R,
                  Session_Id  => Session,
                  Has_Project => MJ.Has_Str (D, "project"),
                  Project     => MJ.Get_Str (D, "project"),
                  Has_Start   => Has_St,
                  Start_Ord   => MS.Row_Id (MJ.Get_Int (D, "start", 0)),
                  Has_End     => Has_En,
                  End_Ord     => MS.Row_Id (MJ.Get_Int (D, "end", 0)),
                  Has_Tail    => Has_Tail,
                  Tail        => Tail,
                  Result      => Turns,
                  Status      => St);
               if St = MS.Success then
                  Ser_Turns (Turns, Session, Buf);
                  Result := OK (Buf);
               else
                  Result := Err (Internal_Error, "fetch_turns: store error");
               end if;
            end;
         end if;
      end;
      MJ.Close (D);
   end Do_Fetch_Turns;

   package ME renames Memcp.Extractor;

   --  The body of upload_session once the transcript is decoded: extract turns,
   --  embed each, save the session, then (for a fresh session with a recap
   --  line) write the autorecap Header. Split out so Do_Upload_Session keeps a
   --  single Doc-close and one Free of the decoded transcript.
   procedure Upload_Decoded
     (R          : MR.Resources;
      Project    : String;
      Session_Id : String;
      Transcript : String;
      Result     : out Result_Ptr)
     with Pre => Transcript'First = 1 and then Transcript'Last < Natural'Last
   is
      Turns  : constant ME.Turn_List := ME.Extract_Turns (Transcript);
      Chunks : MS.Chunk_Input_List := MS.Chunk_Input_Vectors.Empty_Vector;
   begin
      --  Every turn is embedded (store.py embed_batch); a model is only
      --  *required* when there are turns to embed.
      if not ME.Turn_Vectors.Is_Empty (Turns)
        and then not Embedder_Available (R)
      then
         Result := Err
           (Internal_Error,
            "upload_session: embedder unavailable (set MEMCP_MODEL_PATH)");
         return;
      end if;

      for I in ME.Turn_Vectors.First_Index (Turns)
               .. ME.Turn_Vectors.Last_Index (Turns)
      loop
         declare
            T   : constant ME.Turn := ME.Turn_Vectors.Element (Turns, I);
            Emb : Candle_Spark.Embedding;
         begin
            Embed_One (R, T.Text, Emb);
            if MS.Chunk_Input_Vectors.Length (Chunks)
              < MS.Chunk_Input_Vectors.Capacity_Range'Last
            then
               MS.Chunk_Input_Vectors.Append
                 (Chunks,
                  (Body_Len => T.Len, Content => T.Text, Embedding => Emb));
            end if;
         end;
      end loop;

      declare
         Res : MS.Session_Save_Result;
         St  : MS.Op_Status;
         --  First replay clock: the session-row / chunks timestamp.
         Rep : constant Boolean :=
           Memcp.Replay.Enabled and then Memcp.Replay.Has_Clock;
         TS  : constant String :=
           (if Rep then Memcp.Replay.Peek_Clock else "");
      begin
         if Rep then
            Memcp.Replay.Advance_Clock;
         end if;
         MR.Save_Session
           (R,
            Project     => Project,
            Session_Id  => Session_Id,
            Transcript  => Transcript,
            Chunks      => Chunks,
            Has_Created => Rep,
            Created_At  => TS,
            Result      => Res,
            Status      => St);

         if St /= MS.Success then
            Result := Err (Internal_Error, "upload_session: store error");
            return;
         end if;

         --  Autorecap fallback: only for a freshly-recorded session with a
         --  recap line. A real save() is never overwritten (Save_Autorecap
         --  short-circuits too).
         declare
            Recap_Id : MS.Row_Id := 0;
            Wrote    : Boolean := False;
         begin
            if not Res.Already_Existed and then Embedder_Available (R) then
               declare
                  Recap : constant String := ME.Extract_Recap (Transcript);
               begin
                  if Recap'Length > 0 then
                     declare
                        Emb      : Candle_Spark.Embedding;
                        Rep2     : constant Boolean :=
                          Memcp.Replay.Enabled
                          and then Memcp.Replay.Has_Clock;
                        TS2      : constant String :=
                          (if Rep2 then Memcp.Replay.Peek_Clock else "");
                        Sum_Id   : MS.Row_Id;
                        Diary_Id : MS.Row_Id;
                        R_St     : MS.Op_Status;
                     begin
                        Embed_One (R, Recap, Emb);
                        if Rep2 then
                           Memcp.Replay.Advance_Clock;
                        end if;
                        MR.Save_Autorecap
                          (R,
                           Project     => Project,
                           Session_Id  => Session_Id,
                           Recap_Text  => Recap,
                           Embedding   => Emb,
                           Has_Created => Rep2,
                           Created_At  => TS2,
                           Summary_Id  => Sum_Id,
                           Diary_Id    => Diary_Id,
                           Written     => Wrote,
                           Status      => R_St);
                        if R_St = MS.Success and then Wrote then
                           Recap_Id := Sum_Id;
                        else
                           Wrote := False;
                        end if;
                     end;
                  end if;
               end;
            end if;

            Result := OK
              ("{""session_row_id"":" & N (Res.Session_Row_Id)
               & ",""chunk_count"":"
               & N (Interfaces.Integer_64 (Res.Chunk_Count))
               & ",""already_existed"":" & B (Res.Already_Existed)
               & ",""autorecap_summary_id"":"
               & (if Wrote then N (Recap_Id) else "null") & "}");
         end;
      end;
   end Upload_Decoded;

   procedure Do_Upload_Session
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr)
   is
      D : MJ.Doc;
   begin
      MJ.Open (D, Arguments);
      declare
         Project    : constant String := MJ.Get_Str (D, "project");
         Session_Id : constant String := MJ.Get_Str (D, "session_id");
         B64        : constant String := MJ.Get_Str (D, "transcript_b64");
         Decoded    : ME.Transcript_Ptr;
         B64_Ok     : Boolean;
      begin
         if Project'Length = 0 then
            Result := Err (Invalid_Params, "upload_session: 'project' is required");
         elsif Blank (Session_Id) then
            --  server.py makes session_id a required argument; we further reject
            --  a blank one, since an empty session_id collapses every upload
            --  onto the (project, "") idempotency key and loses transcripts.
            Result := Err
              (Invalid_Params, "upload_session: 'session_id' is required");
         elsif not MJ.Has_Str (D, "transcript_b64") then
            Result := Err
              (Invalid_Params, "upload_session: 'transcript_b64' is required");
         else
            ME.Decode_Base64 (B64, Decoded, B64_Ok);
            if not B64_Ok then
               Result := Err
                 (Invalid_Params,
                  "upload_session: transcript_b64 is not valid "
                  & "base64-encoded UTF-8");
            else
               Upload_Decoded (R, Project, Session_Id, Decoded.all, Result);
               ME.Free (Decoded);
            end if;
         end if;
      end;
      MJ.Close (D);
   end Do_Upload_Session;

   ------------
   -- Invoke --
   ------------

   procedure Invoke
     (R         : MR.Resources;
      Id        : Tool_Id;
      Arguments : String;
      Result    : out Spark_Mcp.Tools.Result_Ptr)
   is
   begin
      if not Ready (R) then
         Result := Err (Internal_Error, "store not open");
         return;
      end if;

      case Id is
         when Recent         => Do_Recent (R, Arguments, Result);
         when List_Projects  => Do_List_Projects (R, Result);
         when Save           => Do_Save (R, Arguments, Result);
         when Forget         => Do_Forget (R, Arguments, Result);
         when Search         => Do_Search (R, Arguments, Result);
         when Fetch_Summary  => Do_Fetch_Summary (R, Arguments, Result);
         when Fetch_Chunks   => Do_Fetch_Chunks (R, Arguments, Result);
         when Fetch_Turns    => Do_Fetch_Turns (R, Arguments, Result);
         when Upload_Session => Do_Upload_Session (R, Arguments, Result);
      end case;
   end Invoke;

end Memcp.Tools;
