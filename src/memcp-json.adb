with Ada.Containers;         use type Ada.Containers.Count_Type;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;

with JSON.Types;
with JSON.Parsers;

with Spark_Mcp.Writer;

package body Memcp.Json with SPARK_Mode => On is

   --  Ownership-reclamation discards. Types.Free / Parsers.Destroy release
   --  owned memory and null their argument; a Parse whose tree is discarded
   --  keeps only its Status. In each case the reclaimed handle is genuinely not
   --  read afterwards, so the "set but not used" / "no effect" reports are the
   --  expected shape of end-of-scope cleanup (mirrors json-spark's own
   --  suppressions in json-parsers.adb).
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

   --  Same value model as Memcp.Envelope: the numeric bounds only limit what the
   --  tokenizer accepts; tool arguments read strings/ints and re-serialised
   --  subtrees, so the exact numeric range is immaterial. 64-bit integers cover
   --  every id/ordinal a tool passes to the Store.
   --  Standard.JSON, not the bare "JSON": Memcp.Json's own simple name (Json)
   --  shadows the withed library unit JSON here (Ada's usual rule for a name
   --  that is both a library unit and, case-insensitively, the current
   --  package's own identifier), so the reference must be fully qualified.
   package Types is new Standard.JSON.Types
     (Integer_Type => Long_Long_Integer, Float_Type => Long_Float);
   package Parsers is new Standard.JSON.Parsers
     (Types => Types, Default_Maximum_Depth => 512);

   use type Types.Value_Kind;
   use type Types.JSON_Value_Access;

   --  Completion of the Taft-amendment type: the owned value tree. The parser
   --  is NOT kept -- Parse returns a document independent of the parser (json's
   --  contract), so Open destroys the parser at once and Impl owns only Root.
   type Impl_Record is record
      Root : Types.JSON_Value_Access;
   end record;

   procedure Free_Impl is
     new Ada.Unchecked_Deallocation (Impl_Record, Impl_Access);

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
         --  Parsers.Destroy reclaims P on every path, and json now annotates
         --  Parser ownership (Post => not Has_Storage) + Always_Terminates, so
         --  the structural leak analysis discharges cleanly -- no justification.
         P : Parsers.Parser;
         R : aliased Types.JSON_Value_Access;
      begin
         Parsers.Create (P, Text);

         begin
            Parsers.Parse (P, R);
         exception
            --  Malformed JSON (Parse_Error): leave the tree null and Valid
            --  False; the parser is still released.
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

   --  The member for Key, or null when absent / the doc is not a usable object.
   --  The observer is rooted at the access parameter Impl (json's own idiom),
   --  so no observe crosses two levels of ownership (SPARK RM 3.10). Every
   --  public getter reads the returned observer and hands back a plain value,
   --  so no JSON access type escapes this package.
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
