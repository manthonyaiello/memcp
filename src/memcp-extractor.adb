with Ada.Containers;         use type Ada.Containers.Count_Type;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with JSON.Types;
with JSON.Parsers;

with Memcp.Text;

package body Memcp.Extractor with SPARK_Mode => On is

   --  Ownership-reclamation discards (see Memcp.Json for the rationale): Free /
   --  Destroy null their argument as they reclaim it, and a Parse whose tree is
   --  discarded keeps only its Status. The reclaimed handles are not read after.
   pragma Warnings
     (GNATprove, Off, "statement has no effect",
      Reason => "reclaiming owned memory has no SPARK-modelled effect");
   pragma Warnings
     (GNATprove, Off, "*is set by ""Free"" but not used after the call",
      Reason => "Free nulls its argument as it reclaims it; not read after");
   pragma Warnings
     (GNATprove, Off, "*is set by ""Destroy"" but not used after the call",
      Reason => "Destroy nulls the parser as it reclaims it; not read after");
   pragma Warnings
     (GNATprove, Off, "*is set by ""Parse"" but not used after the call",
      Reason => "the parser is destroyed after Parse; its post-state is unread");
   --  Add_Piece keeps a running count of appended parts; its final increment is
   --  never read, which is inherent to the counter idiom, not a dead store.
   pragma Warnings
     (GNATprove, Off, "*is set by ""Add_Piece"" but not used after the call",
      Reason => "the final part count is never read after the last Add_Piece");

   --  A JSON value model wide enough for any transcript line. Numeric ranges
   --  only bound what the tokenizer accepts; the extractor reads only strings.
   package Types is new JSON.Types
     (Integer_Type => Long_Long_Integer, Float_Type => Long_Float);

   package Parsers is new JSON.Parsers
     (Types => Types, Default_Maximum_Depth => 512);

   use type Types.Value_Kind;
   use type Types.JSON_Value_Access;

   --  Python str.strip() removes ASCII whitespace; mirror that exact set (a
   --  bare Trim would only drop spaces, and \r\n line ends would survive).
   Whitespace : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set
       (' ' & ASCII.HT & ASCII.LF & ASCII.VT & ASCII.FF & ASCII.CR);

   function Strip (S : String) return String is
     (Ada.Strings.Fixed.Trim (S, Whitespace, Whitespace));

   ------------
   -- Sextet --
   ------------

   --  The base64 sextet for C, or -1 if C is outside the standard alphabet.
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

   --  True when S (a byte sequence, one octet per Character) is well-formed
   --  UTF-8 per RFC 3629 -- the same acceptance Python's bytes.decode("utf-8")
   --  enforces (rejects overlong forms, surrogates U+D800..DFFF, and code
   --  points above U+10FFFF). upload_session refuses a transcript that fails
   --  this, matching server.py, rather than persisting mojibake.
   function Valid_Utf8 (S : String) return Boolean is
      I : Integer := S'First;

      function Byte (K : Integer) return Natural is (Character'Pos (S (K)))
        with Pre => K in S'Range;

      --  A continuation octet 10xxxxxx present at K (in range).
      function Cont (K : Integer) return Boolean is
        (K in S'Range and then Byte (K) in 16#80# .. 16#BF#);
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
      B      : Memcp.Text.Builder;
   begin
      Decoded := null;
      Ok      := False;
      Memcp.Text.Reset (B);

      --  Standard base64 is always a whole number of 4-char groups (padding
      --  included); anything else is malformed (Python's "Incorrect padding").
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

         --  A decoded transcript past the field budget is refused (never a
         --  runtime fault); the caller reports it like malformed base64.
         if Memcp.Text.Overflowed (B) then
            return;
         end if;
      end loop;

      --  Python decodes the bytes as UTF-8 and rejects an invalid encoding;
      --  do the same so a non-UTF-8 payload is refused, not persisted as
      --  mojibake and later re-emitted by fetch_turns/fetch_chunks.
      declare
         V : constant String := Memcp.Text.Value (B);
      begin
         if not Valid_Utf8 (V) then
            return;   --  Ok stays False -- the caller reports it like bad base64
         end if;
         Decoded := new String'(V);
         Ok      := True;
      end;
   end Decode_Base64;

   ----------------
   -- Str_Member --
   ----------------

   --  The string value of member Key of Obj, or "" (Obj null / not object /
   --  member absent or not a string). Observer rooted at the access parameter.
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

   --  The member Key of Obj as an observer, or null (null-safe, statement form).
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

   --  Parse one transcript line. Doc is null (no leak) when the line is blank
   --  or not a JSON object. The caller destroys any returned tree via Free.
   procedure Parse_Line
     (Line : String;
      Doc  : out Types.JSON_Value_Access;
      Ok   : out Boolean)
     with Post => (if not Ok then Doc = null)
   is
      --  P and Local are released on every path (Destroy/Free below); json's
      --  ownership + Always_Terminates contracts prove leak-freedom and
      --  termination, so these discharge cleanly.
      P     : Parsers.Parser;
      Local : aliased Types.JSON_Value_Access;
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

   --  extractor.py _text_parts: append the user/assistant text of a content
   --  field (a bare string, or a list of typed parts, only "text" kept) into B,
   --  joined with a blank line. Appends nothing when nothing survives.
   procedure Append_Text_Parts
     (B       : in out Memcp.Text.Builder;
      Content : access constant Types.JSON_Value)
   is
      Count : Natural := 0;

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
      Start : Natural := Transcript'First;

      --  Append the turn for one transcript line to Turns (nothing for a line
      --  that is not a surviving user/assistant message).
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
      Start : Natural := Transcript'First;

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
