--  Memcp.Tools body: one Do_* procedure per tool, each parsing its `arguments`
--  with Memcp.Json, running the request against the Memcp.Resources object
--  passed in, and rendering the reply as JSON text.
--
--  Pure marshalling: it holds no state, builds every result through the bounded
--  Memcp.Text builder so the Max_Field budget holds by construction, and never
--  raises. The Doc parsed from `arguments` is the one owning object, Closed on
--  every path.

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

   pragma Warnings
     (GNATprove, Off, "statement has no effect",
      Reason => "Closing the parsed Doc reclaims owned memory; no SPARK effect");
   pragma Warnings
     (GNATprove, Off, "*is set by ""Close"" but not used after the call",
      Reason => "the Doc is nulled by Close and never read afterwards");
   --  Both reports are the shape of the end-of-scope Doc cleanup: the handle is
   --  nulled by Close and never read again.

   pragma Warnings
     (GNATprove, Off, "*is set by ""Save_Autorecap"" but not used after the call",
      Reason => "this caller uses only Summary_Id, not the parallel Diary_Id");
   --  The autorecap path needs only Summary_Id, for the recap line.

   package MS renames Memcp.Store;
   package MJ renames Memcp.Json;
   package MR renames Memcp.Resources;
   use type MS.Op_Status;
   use type MS.Summary_Ptr;

   function Q (S : String) return String renames MJ.Q;
   --  A complete JSON string literal for S, escaped and quoted.

   function N (V : Interfaces.Integer_64) return String renames MJ.N;
   --  A JSON integer literal for V, with no leading blank.

   function F (V : Interfaces.IEEE_Float_64) return String renames MJ.F;
   --  A JSON number literal for V, with no leading blank.

   subtype Result_Ptr is Spark_Mcp.Tools.Result_Ptr;
   --  The ownership allocation a tool hands its outcome back through.

   ----------------------
   -- Result builders  --
   ----------------------

   function OK (Content : String) return Result_Ptr;
   --  A success result carrying Content, degrading to an Internal_Error when
   --  Content exceeds Max_Field rather than tripping the Invocation_Result
   --  predicate.

   function OK (Content : String) return Result_Ptr is
   begin
      if Content'Length > Spark_Mcp.Max_Field then
         return new Spark_Mcp.Tools.Invocation_Result'
           (Spark_Mcp.Tools.Failure (Internal_Error, "result too large"));
      end if;
      return new Spark_Mcp.Tools.Invocation_Result'
        (Spark_Mcp.Tools.Success (Content));
   end OK;

   function OK (Buf : Memcp.Text.Builder) return Result_Ptr;
   --  A success result carrying Buf's text, or an Internal_Error when Buf
   --  overflowed. Overflowed is the only reliable signal: a builder truncates
   --  at the cap, so its Value is malformed and still within Max_Field.

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
   --  A failure result carrying Code and Msg, or a bare "error" message when
   --  Msg exceeds Max_Field.

   function B (V : Boolean) return String is (if V then "true" else "false");
   --  A JSON boolean literal.

   function To_Nat (V : Interfaces.Integer_64) return Natural is
     (if V <= 0 then 0
      elsif V >= Interfaces.Integer_64 (Natural'Last) then Natural'Last
      else Natural (V));
   --  A JSON integer clamped to a Natural count; negatives become 0.

   function Ready (R : MR.Resources) return Boolean is (MR.Is_Open (R));
   --  True once R's Store is open, which every tool needs.

   function Is_Space (C : Character) return Boolean is
     (C = ' ' or else C in ASCII.HT .. ASCII.CR);
   --  True for ASCII whitespace: space plus HT, LF, VT, FF and CR.

   function Blank (S : String) return Boolean is
     (for all I in S'Range => Is_Space (S (I)));
   --  True when S is empty or entirely whitespace, so that save rejects a
   --  tab-or-newline-only diary or summary that Trim would let through.

   function Valid_Timestamp (S : String) return Boolean;
   --  A pragmatic ISO-8601 check: a YYYY-MM-DD date, optionally followed by
   --  a 'T' or ' ' separator and an HH:MM[...] time. A malformed
   --  since/until is rejected as invalid-params rather than silently
   --  mis-filtering the store's lexical created_at comparison.

   function Valid_Timestamp (S : String) return Boolean is
      Len : constant Natural := S'Length;

      function At_Pos (P : Positive) return Character is
        (if P <= Len then S (S'First + (P - 1)) else ASCII.NUL);
      --  The 1-based Pth character of S, or NUL past the end.

      function Is_Digit (P : Positive) return Boolean is
        (At_Pos (P) in '0' .. '9');
      --  True when the 1-based Pth character of S is a decimal digit.

      function Two (P : Positive) return Integer is
        (if Is_Digit (P) and then Is_Digit (P + 1)
         then (Character'Pos (At_Pos (P)) - Character'Pos ('0')) * 10
              + (Character'Pos (At_Pos (P + 1)) - Character'Pos ('0'))
         else -1)
        with Pre => P < Positive'Last;
      --  The two-digit field at P and P + 1 as a number, or -1 when either
      --  position does not hold a digit.

      Mon, Day, Hr, Mn : Integer;
      --  The parsed month, day, hour and minute; -1 when malformed.
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

      --  Anything after HH:MM -- seconds, fraction, timezone -- must come from
      --  the ISO time/offset alphabet: enough to reject garbage without the
      --  full grammar.
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

   --  A model sometimes emits a save() whose diary or summary value has
   --  swallowed its sibling across a leaked tag boundary --
   --  ...real</parameter><parameter name="diary">... -- and a save is usually a
   --  session's terminal turn, so splitting the value back apart beats
   --  rejecting the call and losing the memory with no retry turn left. The
   --  scanner below matches that one shape, case-insensitively:
   --    </parameter|summary|diary>        (whitespace tolerated before '>')
   --    <parameter name="summary|diary">   (either quote; whitespace tolerated
   --                                        between tags, around name and '=')
   --  with an optional `ns:`-style namespace prefix on either tag name.

   function Lower (C : Character) return Character is
     (if C in 'A' .. 'Z'
      then Character'Val (Character'Pos (C) + 32) else C);
   --  C folded to lower case over ASCII, so tag matching ignores case.

   function Lit_At (S : String; I : Positive; Lit : String) return Boolean is
     (I in S'Range
      and then Lit'Length <= S'Last - I + 1
      and then (for all K in Lit'Range =>
                  Lower (S (I + (K - Lit'First))) = Lit (K)));
   --  True when the already-lowercase literal Lit occurs in S at index I,
   --  case-folded and wholly in bounds.

   function After (S : String; E : Positive) return Natural is
     (if E < S'Last then E + 1 else 0)
     with Pre  => E in S'Range,
          Post => After'Result = 0 or else After'Result in S'Range;
   --  The index just past E, or 0 when E is the last character: an end sentinel
   --  that keeps every cursor a valid index and never forms S'Last + 1.

   function Skip_Ws (S : String; From : Positive) return Natural
     with Pre  => From in S'Range,
          Post => Skip_Ws'Result = 0
                  or else Skip_Ws'Result in From .. S'Last;
   --  First non-whitespace index at or after From, or 0 when the run reaches
   --  the end of S.

   function Skip_Ws (S : String; From : Positive) return Natural is
   begin
      for J in From .. S'Last loop
         if not Is_Space (S (J)) then
            return J;
         end if;
      end loop;
      return 0;
   end Skip_Ws;

   function Skip_Prefix (S : String; P : Positive) return Natural
     with Pre  => P in S'Range,
          Post => Skip_Prefix'Result = 0
                  or else Skip_Prefix'Result in S'Range;
   --  Index of the first tag-name character at P, skipping an optional `ns:`
   --  prefix -- a letter, then name characters, then a colon. P itself when
   --  there is no prefix; 0 when the prefix runs to the end of S.

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

   function Match_Tag_Name (S : String; P : Positive) return Natural
     with Pre  => P in S'Range,
          Post => Match_Tag_Name'Result = 0
                  or else Match_Tag_Name'Result in S'Range;
   --  Index of the last character of the close-tag name at P -- parameter,
   --  summary or diary, case-folded, after an optional namespace prefix -- or 0
   --  on no match. The one place the tag vocabulary is spelled out.

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

   procedure Find_Leak_Boundary
     (S            : String;
      Found        : out Boolean;
      B_Start      : out Positive;
      B_End        : out Positive;
      Sib_Is_Diary : out Boolean)
   with Post => (if Found then B_Start in S'Range and then B_End in S'Range);
   --  Scan S for the first leak boundary. On Found, S (B_Start .. B_End) is the
   --  matched boundary and Sib_Is_Diary says which sibling the open tag named
   --  (True => "diary", False => "summary"); B_Start and B_End are placeholders
   --  otherwise.

   procedure Find_Leak_Boundary
     (S            : String;
      Found        : out Boolean;
      B_Start      : out Positive;
      B_End        : out Positive;
      Sib_Is_Diary : out Boolean)
   is
      procedure Try_At
        (I    : Positive;
         Ok   : out Boolean;
         E    : out Positive;
         Diar : out Boolean)
      with Pre  => I in S'Range,
           Post => (if Ok then E in S'Range);
      --  Try to match a boundary starting at I. On Ok, E is the index of the
      --  closing '>' of the open tag and Diar reports the named sibling.

      procedure Try_At
        (I    : Positive;
         Ok   : out Boolean;
         E    : out Positive;
         Diar : out Boolean)
      is
         P     : Natural;
         Quote : Character;
         Adv   : Boolean;

         procedure Skip_Blanks (P : in out Natural; Adv : out Boolean)
           with Pre  => P in S'Range,
                Post => (if Adv then P in S'Range);
         --  Advance P over whitespace to the next non-blank character. Adv
         --  is False, and the caller bails, when the run reaches the end
         --  of S.

         procedure Skip_Blanks (P : in out Natural; Adv : out Boolean) is
            Q : constant Natural := Skip_Ws (S, P);
         begin
            Adv := Q /= 0;
            if Adv then
               P := Q;
            end if;
         end Skip_Blanks;

         procedure Expect (P : in out Natural; C : Character; Adv : out Boolean)
           with Pre  => P in S'Range,
                Post => (if Adv then P in S'Range);
         --  Skip whitespace, require the single character C, and advance P
         --  past it. Adv is False, and the caller bails, when the run ends,
         --  the character differs, or nothing follows C.

         procedure Expect (P : in out Natural; C : Character; Adv : out Boolean)
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
            return;   --  at least one space is required after 'parameter'
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

   function Strip (S : String) return String;
   --  S with leading and trailing ASCII whitespace removed, or "" when it is
   --  entirely whitespace.

   function Strip (S : String) return String is
      F : Natural := 0;
      --  Index of the first non-whitespace character, 0 when there is none.
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

   function Clean (Raw : String) return String;
   --  A salvaged half tidied up: one trailing </parameter|summary|diary>
   --  close tag dropped, with whitespace tolerated around it, and the result
   --  stripped.

   function Clean (Raw : String) return String is
      S  : constant String := Strip (Raw);
      LT : Natural := 0;
      --  Index of the last '<' in S, 0 when there is none.
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

   procedure Salvage
     (Diary       : String;
      Summary     : String;
      Out_Diary   : out Memcp.Text.Builder;
      Out_Summary : out Memcp.Text.Builder;
      Did         : out Boolean);
   --  Split a leaked value back into its two halves. A leak's signature is
   --  that the swallowed sibling arrives missing, so the split happens only
   --  when the boundary's named sibling slot is empty; with both fields
   --  supplied a boundary-looking sequence is legitimate content and the
   --  value is left intact rather than truncated. On a split Did is True and
   --  the halves come back through the builders, each a slice of the input
   --  and so within the Max_Field budget; otherwise Did is False, the
   --  builders are only Reset, and the caller reuses the original strings.

   procedure Salvage
     (Diary       : String;
      Summary     : String;
      Out_Diary   : out Memcp.Text.Builder;
      Out_Summary : out Memcp.Text.Builder;
      Did         : out Boolean)
   is
      procedure Emit (B : out Memcp.Text.Builder; Text : String);
      --  Reset B and fill it with Text.

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
      --  boundary. A `name="diary"` boundary inside diary names the scanned
      --  field itself, fails the empty-sibling test, and so counts as content.
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
   --  OK (Buf) then emits it only if the field budget held.

   procedure Ser_Diary (V : MS.Diary_Entry_List; Buf : out Memcp.Text.Builder);
   --  Render the diary Headers V into Buf as a JSON array.

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
     (V : MS.Project_Info_List; Buf : out Memcp.Text.Builder);
   --  Render the project rows V into Buf as a JSON array.

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
     (V : MS.Summary_Hit_List; Buf : out Memcp.Text.Builder);
   --  Render the summary search hits V into Buf as a JSON array.

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
     (V : MS.Chunk_Hit_List; Buf : out Memcp.Text.Builder);
   --  Render the chunk search hits V into Buf as a JSON array.

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

   procedure Ser_Turns
     (V : MS.Chunk_List; Session_Id : String; Buf : out Memcp.Text.Builder);
   --  Render the turns V into Buf as a JSON array. Session_Id comes from the
   --  request, the Chunk record having no session field of its own.

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

   function Embedder_Available (R : MR.Resources) return Boolean is
     (MR.Embedder_Loaded (R) or else Memcp.Replay.Enabled);
   --  True when a model is loaded or recorded vectors are being replayed; every
   --  embedding gate consults this.

   procedure Embed_One
     (R : MR.Resources; Text : String; Emb : out Candle_Spark.Embedding);
   --  Embed Text: under replay the recorded vector is injected by text
   --  lookup, otherwise the engine runs. A procedure, because logging a
   --  replay miss is a side effect.

   procedure Embed_One
     (R : MR.Resources; Text : String; Emb : out Candle_Spark.Embedding)
   is
      Found : Boolean;
      --  Whether the replay corpus held a vector for Text.
   begin
      if Memcp.Replay.Enabled then
         Memcp.Replay.Lookup_Embedding (Text, Emb, Found);
         if not Found then
            --  A miss means the corpus is out of step with the request stream,
            --  and the zero fallback vector will skew similarity, so it is
            --  worth surfacing.
            Memcp.Log.Warning
              ("replay: no recorded embedding for query text; "
               & "using zero fallback vector");
         end if;
      else
         Emb := MR.Embed (R, Text);
      end if;
   end Embed_One;

   procedure Embed_Query
     (R    : MR.Resources;
      Text : String;
      Emb  : out Candle_Spark.Embedding;
      Ok   : out Boolean);
   --  Embed Text, or hand back Ok => False and the zero vector when Text is
   --  empty or no embedder is available; the tool then reports the error.

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
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr);
   --  recent: the N most recent diary Headers across the named projects.

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
         --  `projects` is required: an omitted list is a client error, not a
         --  silent empty result. An explicit empty array still yields [].
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
     (R : MR.Resources; Result : out Result_Ptr);
   --  list_projects: every project the store has seen. Takes no arguments.

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
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr);
   --  save: a (diary line, structured summary) pair, plus the summary's
   --  embedding.

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
         --  Recover a leaked <parameter> boundary before the emptiness gate.
         Salvage (Diary_In, Summary_In, Bd_Buf, Sm_Buf, Salvaged);
         if Salvaged then
            Memcp.Log.Warning
              ("save: recovered a leaked <parameter> boundary; "
               & "split diary/summary");
         end if;
         declare
            Diary   : constant String :=
              (if Salvaged then Memcp.Text.Value (Bd_Buf) else Diary_In);
            --  The diary to save. On the common no-leak path Salvage leaves the
            --  builders empty, so the original argument is reused rather than
            --  round-tripped.

            Summary : constant String :=
              (if Salvaged then Memcp.Text.Value (Sm_Buf) else Summary_In);
            --  The summary to save, on the same terms.

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
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr);
   --  forget: delete a summary, its diary line and its embedding by id.

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
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr);
   --  search: semantic search over Summaries, within optional date bounds.

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
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr);
   --  fetch_summary: one full Summary by id.

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
               --  Through the bounded builder: the body field can be large, so
               --  a raw concatenation could not be bounded.
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
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr);
   --  fetch_chunks: semantic search over session chunks, within optional
   --  project, session and date bounds.

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
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr);
   --  fetch_turns: verbatim conversation turns, by ordinal range or tail.

   procedure Do_Fetch_Turns
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr)
   is
      D : MJ.Doc;
   begin
      MJ.Open (D, Arguments);
      declare
         Session  : constant String := MJ.Get_Str (D, "session_id");
         Last_V   : constant Interfaces.Integer_64 := MJ.Get_Int (D, "last", 0);
         Has_Last : constant Boolean := MJ.Has_Int (D, "last");
         --  Whether `last` was supplied at all, as against a real positive
         --  tail: a non-positive `last` is neither absent nor a tail, and is
         --  rejected rather than folded into "whole session".

         Has_Tail : constant Boolean := Has_Last and then Last_V > 0;
         --  Whether a usable tail length was supplied.

         Has_St   : constant Boolean := MJ.Has_Int (D, "start");
         Has_En   : constant Boolean := MJ.Has_Int (D, "end");
         Tail     : constant Positive :=
           (if Has_Tail then
              (if Last_V >= Interfaces.Integer_64 (Positive'Last)
               then Positive'Last else Positive (Last_V))
            else 1);
         --  The tail length, clamped to Positive'Last since Last_V is 64-bit.
      begin
         if Session'Length = 0 then
            Result :=
              Err (Invalid_Params, "fetch_turns: 'session_id' is required");
         elsif Has_Last and then (Has_St or else Has_En) then
            --  Mutual exclusion is checked before positivity, so this fires
            --  even for a non-positive `last` combined with start/end.
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

   procedure Upload_Decoded
     (R          : MR.Resources;
      Project    : String;
      Session_Id : String;
      Transcript : String;
      Result     : out Result_Ptr)
     with Pre => Transcript'First = 1 and then Transcript'Last < Natural'Last;
   --  upload_session once the transcript is decoded: extract turns, embed
   --  each, save the session, then write the autorecap Header for a fresh
   --  session that carries a recap line.

   procedure Upload_Decoded
     (R          : MR.Resources;
      Project    : String;
      Session_Id : String;
      Transcript : String;
      Result     : out Result_Ptr)
   is
      Turns  : constant ME.Turn_List := ME.Extract_Turns (Transcript);
      --  The text-bearing turns of the transcript, in order.

      Chunks : MS.Chunk_Input_List := MS.Chunk_Input_Vectors.Empty_Vector;
      --  The turns paired with their embeddings, as the chunk rows to save.
   begin
      --  Every turn is embedded, so a model is required only when there are
      --  turns.
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
         Rep : constant Boolean :=
           Memcp.Replay.Enabled and then Memcp.Replay.Has_Clock;
         --  Whether the first replay clock -- the session-row and chunks
         --  timestamp -- is available.

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

         --  Autorecap fallback: only for a freshly-recorded session carrying a
         --  recap line, and never over a real save.
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
     (R : MR.Resources; Arguments : String; Result : out Result_Ptr);
   --  upload_session: decode the base64 transcript, then hand it to
   --  Upload_Decoded, so the Doc is Closed and the transcript Freed once.

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
            --  A blank session_id is rejected as well as a missing one: it
            --  would collapse every upload onto the (project, "") idempotency
            --  key and lose transcripts.
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
