--  Memcp.Json body: the json crate is instantiated here and nowhere else, and
--  every value it yields is read through an observer that never leaves this
--  body.

with Ada.Containers;         use type Ada.Containers.Count_Type;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;

with JSON.Types;
with JSON.Parsers;

with Spark_Mcp.Writer;

package body Memcp.Json with SPARK_Mode => On is

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
   --  The four suppressions above are the shape of end-of-scope reclamation: the
   --  handle each call nulls is genuinely not read afterwards.

   package Types is new Standard.JSON.Types
     (Integer_Type => Long_Long_Integer, Float_Type => Long_Float);
   --  The json value model. Its numeric bounds only limit what the tokenizer
   --  accepts, and 64-bit integers cover every id and ordinal that reaches the
   --  Store. Standard.JSON, because this package's own simple name shadows the
   --  withed library unit JSON.

   package Parsers is new Standard.JSON.Parsers
     (Types => Types, Default_Maximum_Depth => 512);
   --  The parser over that value model, with a nesting cap.

   use type Types.Value_Kind;
   use type Types.JSON_Value_Access;

   type Impl_Record is record
      Root : Types.JSON_Value_Access;
      --  The owned value tree.
   end record;
   --  Completion of the spec's incomplete type. It holds the tree and nothing
   --  else: Parse returns a document independent of the parser, so Open destroys
   --  the parser at once.

   procedure Free_Impl is
     new Ada.Unchecked_Deallocation (Impl_Record, Impl_Access);
   --  Reclaim the node itself, once its tree has been freed.

   ----------
   -- Open --
   ----------

   procedure Open (D : out Doc; Text : String) is
   begin
      D.Is_Valid := False;
      D.Impl     := null;

      --  Parsers.Create requires Text'Length < Positive'Last.
      if Text'Length = Natural'Last then
         return;
      end if;

      declare
         P : Parsers.Parser;
         --  The parser, reclaimed by Parsers.Destroy on every path.

         R : aliased Types.JSON_Value_Access;
         --  The parsed tree: moved into D.Impl when it is an object, freed
         --  otherwise.
      begin
         Parsers.Create (P, Text);

         begin
            Parsers.Parse (P, R);
         exception
            --  Malformed JSON: leave the tree null and Valid False, still
            --  releasing the parser.
            when Parsers.Parse_Error =>
               Parsers.Destroy (P);
               Types.Free (R);  --  null on the error path (Parse leaves it so)
               return;
         end;

         Parsers.Destroy (P);

         if R /= null and then Types.Kind (R) = Types.Object_Kind then
            D.Impl     := new Impl_Record'(Root => R);  --  move tree into node
            D.Is_Valid := True;
         else
            Types.Free (R);                    --  not an object: discard it
         end if;
      end;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (D : in out Doc) is
   begin
      if D.Impl /= null then
         Types.Free (D.Impl.Root);
         Free_Impl (D.Impl);
      end if;
      D.Is_Valid := False;
   end Close;

   -----------
   -- Valid --
   -----------

   function Valid (D : Doc) return Boolean is (D.Is_Valid);

   ------------
   -- Member --
   ------------

   function Get_Member
     (Impl : not null access constant Impl_Record; Key : String)
      return access constant Types.JSON_Value;
   --  The member for Key, or null when it is absent or the doc is not a
   --  usable object. Takes the node as an access parameter rather than the
   --  Doc, so the observer crosses only one level of ownership.

   function Get_Member
     (Impl : not null access constant Impl_Record; Key : String)
      return access constant Types.JSON_Value
   is
   begin
      if Impl.Root = null
        or else Types.Kind (Impl.Root) /= Types.Object_Kind
      then
         return null;
      end if;
      return Types.Get (Impl.Root, Key);
   end Get_Member;

   function Member
     (D : Doc; Key : String) return access constant Types.JSON_Value;
   --  The member for Key of an open, valid D; null otherwise. Every public
   --  getter reads this observer and returns a plain value, so no json access
   --  type escapes the package.

   function Member
     (D : Doc; Key : String) return access constant Types.JSON_Value
   is
   begin
      if not D.Is_Valid or else D.Impl = null then
         return null;
      end if;
      return Get_Member (D.Impl, Key);
   end Member;

   ---------
   -- Has --
   ---------

   function Has (D : Doc; Key : String) return Boolean is
     (Member (D, Key) /= null);

   -------------
   -- Get_Str --
   -------------

   function Get_Str
     (D : Doc; Key : String; Default : String := "") return String
   is
      M : constant access constant Types.JSON_Value := Member (D, Key);
   begin
      if M /= null and then Types.Kind (M) = Types.String_Kind then
         return Types.Value (M);
      else
         return Default;
      end if;
   end Get_Str;

   -------------
   -- Has_Str --
   -------------

   function Has_Str (D : Doc; Key : String) return Boolean is
      M : constant access constant Types.JSON_Value := Member (D, Key);
   begin
      return M /= null and then Types.Kind (M) = Types.String_Kind;
   end Has_Str;

   -------------
   -- Get_Int --
   -------------

   function Get_Int
     (D : Doc; Key : String; Default : Interfaces.Integer_64)
      return Interfaces.Integer_64
   is
      M : constant access constant Types.JSON_Value := Member (D, Key);
   begin
      if M /= null and then Types.Kind (M) = Types.Integer_Kind then
         return Interfaces.Integer_64 (Long_Long_Integer'(Types.Value (M)));
      else
         return Default;
      end if;
   end Get_Int;

   -------------
   -- Has_Int --
   -------------

   function Has_Int (D : Doc; Key : String) return Boolean is
      M : constant access constant Types.JSON_Value := Member (D, Key);
   begin
      return M /= null and then Types.Kind (M) = Types.Integer_Kind;
   end Has_Int;

   ---------------
   -- Get_Names --
   ---------------

   function Get_Names (D : Doc; Key : String) return Memcp.Store.Name_List is
      use Memcp.Store;
      Result : Name_List := Name_Vectors.Empty_Vector;
      M      : constant access constant Types.JSON_Value := Member (D, Key);
   begin
      if M = null or else Types.Kind (M) /= Types.Array_Kind then
         return Result;
      end if;
      for I in 1 .. Types.Length (M) loop
         pragma Loop_Invariant
           (Name_Vectors.Length (Result) <= Name_Vectors.Capacity_Range (I - 1));
         declare
            E : constant access constant Types.JSON_Value := Types.Get (M, I);
         begin
            if E /= null and then Types.Kind (E) = Types.String_Kind then
               declare
                  S : constant String := Types.Value (E);
               begin
                  Name_Vectors.Append (Result, (Len => S'Length, Value => S));
               end;
            end if;
         end;
      end loop;
      return Result;
   end Get_Names;

   -------
   -- Q --
   -------

   function Q (S : String) return String is
     (if S'Length <= Spark_Mcp.Max_Field
      then Spark_Mcp.Writer.Quoted (S)
      else Spark_Mcp.Writer.Quoted (""));

   -------
   -- N --
   -------

   function N (V : Interfaces.Integer_64) return String is
     (Ada.Strings.Fixed.Trim (V'Image, Ada.Strings.Both));

   -------
   -- F --
   -------

   function F (V : Interfaces.IEEE_Float_64) return String is
     (Ada.Strings.Fixed.Trim (V'Image, Ada.Strings.Both));

end Memcp.Json;
