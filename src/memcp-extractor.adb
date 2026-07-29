--  Memcp.Extractor body: hand-rolled base64 and UTF-8 acceptance, then one json
--  parse per transcript line, with every parsed tree released on the spot.

with Ada.Containers;         use type Ada.Containers.Count_Type;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with JSON.Types;
with JSON.Parsers;

with Memcp.Text;

package body Memcp.Extractor with SPARK_Mode => On is

   pragma Warnings
     (GNATprove, Off, "statement has no effect",
      Reason => "reclaiming owned memory has no SPARK-modelled effect");
   --  This and the three pragmas below discard the flow reports of ownership
   --  reclamation: Free and Destroy null their argument as they reclaim it, and
   --  a Parse whose tree is discarded keeps only its Status.

   pragma Warnings
     (GNATprove, Off, "*is set by ""Free"" but not used after the call",
      Reason => "Free nulls its argument as it reclaims it; not read after");
   pragma Warnings
     (GNATprove, Off, "*is set by ""Destroy"" but not used after the call",
      Reason => "Destroy nulls the parser as it reclaims it; not read after");
   pragma Warnings
     (GNATprove, Off, "*is set by ""Parse"" but not used after the call",
      Reason => "the parser is destroyed after Parse; its post-state is unread");

   pragma Warnings
     (GNATprove, Off, "*is set by ""Add_Piece"" but not used after the call",
      Reason => "the final part count is never read after the last Add_Piece");
   --  The running part count Add_Piece keeps: its final increment is never
   --  read, which is the counter idiom rather than a dead store.

   --  A JSON value model wide enough for any transcript line; the numeric
   --  bounds limit only what the tokenizer accepts, and only strings are read.
   package Types is new JSON.Types
     (Integer_Type => Long_Long_Integer, Float_Type => Long_Float);

   --  The line parser over that model; 512 levels of nesting is far past
   --  anything a transcript line carries.
   package Parsers is new JSON.Parsers
     (Types => Types, Default_Maximum_Depth => 512);

   use type Types.Value_Kind;
   use type Types.JSON_Value_Access;

   Whitespace : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set
       (' ' & ASCII.HT & ASCII.LF & ASCII.VT & ASCII.FF & ASCII.CR);
   --  The whole ASCII whitespace set, not just the space a bare Trim would
   --  drop: \r and \n line ends have to come off too.

   function Strip (S : String) return String is
     (Ada.Strings.Fixed.Trim (S, Whitespace, Whitespace));
   --  S with ASCII whitespace trimmed from both ends.

   ------------
   -- Sextet --
   ------------

   function Sextet (C : Character) return Integer;
   --  The base64 sextet for C, or -1 when C is not in the standard alphabet.

   function Sextet (C : Character) return Integer is
   begin
      case C is
         when 'A' .. 'Z' => return Character'Pos (C) - Character'Pos ('A');
         when 'a' .. 'z' => return Character'Pos (C) - Character'Pos ('a') + 26;
         when '0' .. '9' => return Character'Pos (C) - Character'Pos ('0') + 52;
         when '+'        => return 62;
         when '/'        => return 63;
         when others     => return -1;
      end case;
   end Sextet;

   ----------------
   -- Valid_Utf8 --
   ----------------

   function Valid_Utf8 (S : String) return Boolean;
   --  True when S, taken as one octet per Character, is well-formed UTF-8
   --  per RFC 3629: overlong forms, surrogates U+D800 .. DFFF and code
   --  points above U+10FFFF are all rejected.

   function Valid_Utf8 (S : String) return Boolean is
      I : Integer := S'First;
      --  Index of the octet that starts the sequence under examination.

      function Byte (K : Integer) return Natural is (Character'Pos (S (K)))
        with Pre => K in S'Range;
      --  The octet at K as a number.

      function Cont (K : Integer) return Boolean is
        (K in S'Range and then Byte (K) in 16#80# .. 16#BF#);
      --  True when K is in range and holds a 10xxxxxx continuation octet.
   begin
      while I <= S'Last loop
         pragma Loop_Invariant (I >= S'First);
         pragma Loop_Variant (Increases => I);
         declare
            B0 : constant Natural := Byte (I);
         begin
            if B0 <= 16#7F# then                    --  ASCII
               I := I + 1;
            elsif B0 in 16#C2# .. 16#DF# then       --  2-byte
               if not Cont (I + 1) then
                  return False;
               end if;
               I := I + 2;
            elsif B0 = 16#E0# then                  --  3-byte, no overlong
               if I + 2 > S'Last
                 or else Byte (I + 1) not in 16#A0# .. 16#BF#
                 or else not Cont (I + 2)
               then
                  return False;
               end if;
               I := I + 3;
            elsif B0 = 16#ED# then                  --  3-byte, no surrogate
               if I + 2 > S'Last
                 or else Byte (I + 1) not in 16#80# .. 16#9F#
                 or else not Cont (I + 2)
               then
                  return False;
               end if;
               I := I + 3;
            elsif B0 in 16#E1# .. 16#EC# | 16#EE# .. 16#EF# then  --  3-byte
               if not Cont (I + 1) or else not Cont (I + 2) then
                  return False;
               end if;
               I := I + 3;
            elsif B0 = 16#F0# then                  --  4-byte, no overlong
               if I + 3 > S'Last
                 or else Byte (I + 1) not in 16#90# .. 16#BF#
                 or else not Cont (I + 2) or else not Cont (I + 3)
               then
                  return False;
               end if;
               I := I + 4;
            elsif B0 = 16#F4# then                  --  4-byte, <= U+10FFFF
               if I + 3 > S'Last
                 or else Byte (I + 1) not in 16#80# .. 16#8F#
                 or else not Cont (I + 2) or else not Cont (I + 3)
               then
                  return False;
               end if;
               I := I + 4;
            elsif B0 in 16#F1# .. 16#F3# then       --  4-byte
               if not Cont (I + 1) or else not Cont (I + 2)
                 or else not Cont (I + 3)
               then
                  return False;
               end if;
               I := I + 4;
            else                                    --  C0,C1,F5..FF, stray cont
               return False;
            end if;
         end;
      end loop;
      return True;
   end Valid_Utf8;

   -------------------
   -- Decode_Base64 --
   -------------------

   procedure Decode_Base64
     (Encoded : String;
      Decoded : out Transcript_Ptr;
      Ok      : out Boolean)
   is
      Groups : constant Natural := Encoded'Length / 4;
      --  Number of 4-character groups in Encoded.

      B      : Memcp.Text.Builder;
      --  The decoded bytes; the builder's own cap is Max_Transcript.
   begin
      Decoded := null;
      Ok      := False;
      Memcp.Text.Reset (B);

      --  Padding included, standard base64 is a whole number of 4-character
      --  groups; anything else is malformed.
      if Encoded'Length mod 4 /= 0 then
         return;
      end if;

      for G in 1 .. Groups loop
         declare
            Base    : constant Natural := Encoded'First + (G - 1) * 4;
            C0      : constant Character := Encoded (Base);
            C1      : constant Character := Encoded (Base + 1);
            C2      : constant Character := Encoded (Base + 2);
            C3      : constant Character := Encoded (Base + 3);
            Is_Last : constant Boolean := (G = Groups);
            N0      : constant Integer := Sextet (C0);
            N1      : constant Integer := Sextet (C1);
            N2, N3  : Integer;
         begin
            --  The first two characters are always data, never padding.
            if N0 < 0 or else N1 < 0 then
               return;
            end if;

            if C2 = '=' then
               --  Two-pad group "xx==": one byte, only as the final group.
               if C3 /= '=' or else not Is_Last then
                  return;
               end if;
               Memcp.Text.Add (B, Character'Val (N0 * 4 + N1 / 16));

            elsif C3 = '=' then
               --  One-pad group "xxx=": two bytes, only as the final group.
               if not Is_Last then
                  return;
               end if;
               N2 := Sextet (C2);
               if N2 < 0 then
                  return;
               end if;
               Memcp.Text.Add (B, Character'Val (N0 * 4 + N1 / 16));
               Memcp.Text.Add (B, Character'Val ((N1 mod 16) * 16 + N2 / 4));

            else
               --  Full group -> three bytes.
               N2 := Sextet (C2);
               N3 := Sextet (C3);
               if N2 < 0 or else N3 < 0 then
                  return;
               end if;
               Memcp.Text.Add (B, Character'Val (N0 * 4 + N1 / 16));
               Memcp.Text.Add (B, Character'Val ((N1 mod 16) * 16 + N2 / 4));
               Memcp.Text.Add (B, Character'Val ((N2 mod 4) * 64 + N3));
            end if;
         end;

         --  Past Max_Transcript the transcript is refused, not truncated and
         --  never a runtime fault.
         if Memcp.Text.Overflowed (B) then
            return;
         end if;
      end loop;

      --  Refuse a payload that is not valid UTF-8 rather than store mojibake to
      --  be handed back later.
      declare
         V : constant String := Memcp.Text.Value (B);
         --  The decoded bytes, still unvalidated.
      begin
         if not Valid_Utf8 (V) then
            return;   --  Ok stays False: refused like malformed base64
         end if;
         Decoded := new String'(V);
         Ok      := True;
      end;
   end Decode_Base64;

   ----------------
   -- Str_Member --
   ----------------

   function Str_Member
     (Obj : access constant Types.JSON_Value; Key : String) return String;
   --  The string value of member Key of Obj, or "" when Obj is null, is not
   --  an object, or has no such string member.

   function Str_Member
     (Obj : access constant Types.JSON_Value; Key : String) return String
   is
   begin
      if Obj = null or else Types.Kind (Obj) /= Types.Object_Kind then
         return "";
      end if;
      declare
         M : constant access constant Types.JSON_Value := Types.Get (Obj, Key);
      begin
         if M /= null and then Types.Kind (M) = Types.String_Kind then
            return Types.Value (M);
         end if;
         return "";
      end;
   end Str_Member;

   -------------
   -- Obj_Get --
   -------------

   function Obj_Get
     (Obj : access constant Types.JSON_Value; Key : String)
      return access constant Types.JSON_Value;
   --  The member Key of Obj, or null when Obj is null, is not an object, or
   --  has no such member.

   function Obj_Get
     (Obj : access constant Types.JSON_Value; Key : String)
      return access constant Types.JSON_Value
   is
   begin
      if Obj = null or else Types.Kind (Obj) /= Types.Object_Kind then
         return null;
      end if;
      return Types.Get (Obj, Key);
   end Obj_Get;

   ----------------
   -- Parse_Line --
   ----------------

   procedure Parse_Line
     (Line : String;
      Doc  : out Types.JSON_Value_Access;
      Ok   : out Boolean)
     with Post => (if not Ok then Doc = null);
   --  Parse one transcript line. Doc is null, with nothing leaked, when the
   --  line is blank or is not a JSON object; otherwise the caller owns the
   --  tree and must Free it.

   procedure Parse_Line
     (Line : String;
      Doc  : out Types.JSON_Value_Access;
      Ok   : out Boolean)
   is
      P     : Parsers.Parser;
      --  The line's parser, destroyed on every path below.

      Local : aliased Types.JSON_Value_Access;
      --  The parsed tree, handed to Doc only when it is a JSON object.
   begin
      Doc := null;
      Ok  := False;
      if Line'Length = 0 or else Line'Length = Positive'Last then
         return;
      end if;

      Parsers.Create (P, Line);
      begin
         Parsers.Parse (P, Local);
      exception
         when Parsers.Parse_Error =>
            Parsers.Destroy (P);
            Types.Free (Local);  --  null on the error path
            return;
      end;
      Parsers.Destroy (P);

      if Local /= null and then Types.Kind (Local) = Types.Object_Kind then
         Doc := Local;
         Ok  := True;
      else
         Types.Free (Local);
      end if;
   end Parse_Line;

   -----------------------
   -- Append_Text_Parts --
   -----------------------

   procedure Append_Text_Parts
     (B       : in out Memcp.Text.Builder;
      Content : access constant Types.JSON_Value);
   --  Append the text of a message's content field to B, joining the pieces
   --  with a blank line. Content is either a bare string or a list of typed
   --  parts of which only "text" is kept; nothing is appended when nothing
   --  survives.

   procedure Append_Text_Parts
     (B       : in out Memcp.Text.Builder;
      Content : access constant Types.JSON_Value)
   is
      Count : Natural := 0;
      --  Pieces appended so far; nonzero is what earns a separator.

      procedure Add_Piece (Text : String);
      --  Append Text stripped, preceded by a blank line unless it is first.
      --  A piece that strips to nothing is dropped.

      procedure Add_Piece (Text : String) is
         S : constant String := Strip (Text);
      begin
         if S'Length = 0 then
            return;
         end if;
         if Count > 0 then
            Memcp.Text.Add (B, ASCII.LF & ASCII.LF);
         end if;
         Memcp.Text.Add (B, S);
         if Count < Natural'Last then
            Count := Count + 1;
         end if;
      end Add_Piece;

   begin
      if Content = null then
         return;
      end if;

      if Types.Kind (Content) = Types.String_Kind then
         Add_Piece (Types.Value (Content));

      elsif Types.Kind (Content) = Types.Array_Kind then
         for I in 1 .. Types.Length (Content) loop
            declare
               Part : constant access constant Types.JSON_Value :=
                 Types.Get (Content, I);
            begin
               if Part /= null
                 and then Types.Kind (Part) = Types.Object_Kind
                 and then Str_Member (Part, "type") = "text"
               then
                  Add_Piece (Str_Member (Part, "text"));
               end if;
            end;
         end loop;
      end if;
   end Append_Text_Parts;

   -------------------
   -- Extract_Turns --
   -------------------

   function Extract_Turns (Transcript : String) return Turn_List is
      Turns : Turn_List := Turn_Vectors.Empty_Vector;
      --  The turns accumulated so far, in transcript order.

      Start : Natural := Transcript'First;
      --  First index of the line the scan below is inside.

      procedure Process_Line (Line : String);
      --  Append the turn for one line to Turns, or nothing when the line is
      --  not a user/assistant message with surviving text.

      procedure Process_Line (Line : String) is
         Doc : Types.JSON_Value_Access;
         Ok  : Boolean;
      begin
         if Line'Length = 0 then
            return;
         end if;
         Parse_Line (Line, Doc, Ok);
         if not Ok then
            return;
         end if;

         declare
            T_Kind : constant String := Str_Member (Doc, "type");
            Msg    : constant access constant Types.JSON_Value :=
              Obj_Get (Doc, "message");
         begin
            if (T_Kind = "user" or else T_Kind = "assistant")
              and then Msg /= null
              and then Types.Kind (Msg) = Types.Object_Kind
            then
               declare
                  Role_Raw : constant String := Str_Member (Msg, "role");
                  Role     : constant String :=
                    (if Role_Raw'Length > 0 then Role_Raw else T_Kind);
                  PB       : Memcp.Text.Builder;
               begin
                  Memcp.Text.Reset (PB);
                  Append_Text_Parts (PB, Obj_Get (Msg, "content"));

                  if Memcp.Text.Length (PB) > 0 then
                     declare
                        Parts : constant String := Memcp.Text.Value (PB);
                        TB    : Memcp.Text.Builder;
                     begin
                        Memcp.Text.Reset (TB);
                        Memcp.Text.Add (TB, "[");
                        Memcp.Text.Add (TB, Role);
                        Memcp.Text.Add (TB, "] ");
                        Memcp.Text.Add (TB, Parts);
                        declare
                           S : constant String := Memcp.Text.Value (TB);
                        begin
                           --  Capacity guard, out of reach for a transcript
                           --  bounded by Max_Transcript.
                           if Turn_Vectors.Length (Turns)
                             < Turn_Vectors.Capacity_Range'Last
                           then
                              Turn_Vectors.Append
                                (Turns, (Len => S'Length, Text => S));
                           end if;
                        end;
                     end;
                  end if;
               end;
            end if;
         end;

         Types.Free (Doc);
      end Process_Line;

   begin
      for I in Transcript'Range loop
         pragma Loop_Invariant
           (Start >= Transcript'First and then Start <= I);
         if Transcript (I) = ASCII.LF then
            Process_Line (Strip (Transcript (Start .. I - 1)));
            Start := I + 1;
         end if;
      end loop;
      if Start <= Transcript'Last then
         Process_Line (Strip (Transcript (Start .. Transcript'Last)));
      end if;
      return Turns;
   end Extract_Turns;

   -------------------
   -- Extract_Recap --
   -------------------

   function Extract_Recap (Transcript : String) return String is
      Last  : Memcp.Text.Builder;
      --  The most recent non-empty recap seen, and the result.

      Start : Natural := Transcript'First;
      --  First index of the line the scan below is inside.

      procedure Process_Line (Line : String);
      --  Replace Last with this line's recap, when it is a non-empty
      --  away_summary.

      procedure Process_Line (Line : String) is
         Doc : Types.JSON_Value_Access;
         Ok  : Boolean;
      begin
         if Line'Length = 0 then
            return;
         end if;
         Parse_Line (Line, Doc, Ok);
         if not Ok then
            return;
         end if;

         if Str_Member (Doc, "type") = "system"
           and then Str_Member (Doc, "subtype") = "away_summary"
         then
            declare
               Content : constant String := Strip (Str_Member (Doc, "content"));
            begin
               if Content'Length > 0 then
                  Memcp.Text.Reset (Last);   --  keep only the last one
                  Memcp.Text.Add (Last, Content);
               end if;
            end;
         end if;

         Types.Free (Doc);
      end Process_Line;

   begin
      Memcp.Text.Reset (Last);
      for I in Transcript'Range loop
         pragma Loop_Invariant
           (Start >= Transcript'First and then Start <= I);
         if Transcript (I) = ASCII.LF then
            Process_Line (Strip (Transcript (Start .. I - 1)));
            Start := I + 1;
         end if;
      end loop;
      if Start <= Transcript'Last then
         Process_Line (Strip (Transcript (Start .. Transcript'Last)));
      end if;
      return Memcp.Text.Value (Last);
   end Extract_Recap;

end Memcp.Extractor;
