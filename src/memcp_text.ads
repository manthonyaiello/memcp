--  A small, SPARK-proved bounded string builder shared by the marshalling
--  layers (Memcp_Tools' JSON serializers, Memcp_Extractor's turn assembly).
--
--  Building an arbitrary-length string by concatenation in a loop is the one
--  spot where AoRTE is not free: a growing String index can overflow. This
--  builder confines that reasoning to one proved unit. It accumulates into a
--  SPARKlib character vector whose length is bounded by Max_Len (= Max_Field);
--  Add stops and raises the Overflowed flag rather than exceed it, so a
--  pathologically large payload degrades to an error instead of a runtime
--  fault. Value then hands back an ordinary String (1 .. Length), which every
--  consumer already bounds by Max_Field.

with Ada.Containers; use type Ada.Containers.Count_Type;
with SPARK.Containers.Formal.Unbounded_Vectors;

with Spark_Mcp;

package Memcp_Text with SPARK_Mode => On is

   Max_Len : constant := Spark_Mcp.Max_Field;
   --  The cap: the same field budget the whole response layer rests on.

   type Builder is limited private;
   --  An opaque, bounded string accumulator; see the private completion.

   procedure Reset (B : out Builder);
   --  Start (or restart) an empty builder.
   --  @param B The builder to (re)initialize to the empty state.

   procedure Add (B : in out Builder; S : String);
   --  Append S. If it would push the length past Max_Len, append what fits and
   --  set Overflowed -- never a runtime fault, never past the cap.
   --  @param B The builder being appended to.
   --  @param S The text to append.

   procedure Add (B : in out Builder; C : Character);
   --  Append one character (same cap behaviour).
   --  @param B The builder being appended to.
   --  @param C The character to append.

   function Overflowed (B : Builder) return Boolean;
   --  True once an Add hit the cap; the accumulated Value is then truncated and
   --  the caller should report an error rather than emit it.
   --  @param B The builder to query.
   --  @return True if any Add was truncated at the cap, False otherwise.

   function Length (B : Builder) return Natural
     with Post => Length'Result <= Max_Len;
   --  The current accumulated length, never exceeding Max_Len.
   --  @param B The builder to query.
   --  @return The number of characters accumulated so far.

   function Value (B : Builder) return String
     with Post => Value'Result'First = 1
                  and then Value'Result'Length = Length (B);
   --  The accumulated text, 1-based.
   --  @param B The builder to read.
   --  @return The accumulated characters as a String indexed 1 .. Length (B).

private

   package Char_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Character);
   --  The SPARK formal character vector the builder accumulates into.

   type Builder is limited record
      Chars : Char_Vectors.Vector;   --  The accumulated characters.
      Over  : Boolean := False;      --  True once an Add was truncated at the cap.
   end record
     with Dynamic_Predicate =>
       Char_Vectors.Length (Builder.Chars)
         <= Char_Vectors.Capacity_Range (Max_Len);
   --  Bounded accumulator: the predicate confines the length to Max_Len so the
   --  concatenation loop is AoRTE-free.

   Cap : constant Char_Vectors.Capacity_Range :=
     Char_Vectors.Capacity_Range (Max_Len);
   --  The cap expressed in the vector's capacity units.

end Memcp_Text;
