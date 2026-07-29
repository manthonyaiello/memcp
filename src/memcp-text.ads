--  Memcp.Text: a bounded string builder, proved free of run-time errors, which
--  confines the index reasoning of a string built by appending in a loop to one
--  unit. Accumulation stops at a cap: an Add that would pass it truncates and
--  flags the builder rather than fault.

with Ada.Containers; use type Ada.Containers.Count_Type;
with SPARK.Containers.Formal.Unbounded_Vectors;

with Spark_Mcp;

package Memcp.Text with SPARK_Mode => On is

   Max_Len : constant := Spark_Mcp.Max_Field;
   --  Cap on a builder's accumulated length.

   type Builder is limited private;
   --  An opaque bounded string accumulator.

   procedure Reset (B : out Builder);
   --  Start (or restart) an empty builder.
   --  @param B The builder to (re)initialize to the empty state.

   procedure Add (B : in out Builder; S : String);
   --  Append S, or as much of it as fits: an Add that would pass Max_Len
   --  truncates and sets Overflowed.
   --  @param B The builder being appended to.
   --  @param S The text to append.

   procedure Add (B : in out Builder; C : Character);
   --  Append C, or set Overflowed if the builder is already at Max_Len.
   --  @param B The builder being appended to.
   --  @param C The character to append.

   function Overflowed (B : Builder) return Boolean;
   --  True once an Add was truncated at the cap, so Value is incomplete and the
   --  caller owes an error rather than the text.
   --  @param B The builder to query.
   --  @return True if any Add was truncated at the cap, False otherwise.

   function Length (B : Builder) return Natural
     with Post => Length'Result <= Max_Len;
   --  The accumulated length.
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
   --  The character vector a Builder accumulates into.

   type Builder is limited record
      Chars : Char_Vectors.Vector;   --  The accumulated characters.
      Over  : Boolean := False;      --  True once an Add was truncated at the cap.
   end record
     with Dynamic_Predicate =>
       Char_Vectors.Length (Builder.Chars)
         <= Char_Vectors.Capacity_Range (Max_Len);
   --  Full view of Builder: the accumulated characters and the truncation flag.

   Cap : constant Char_Vectors.Capacity_Range :=
     Char_Vectors.Capacity_Range (Max_Len);
   --  Max_Len in the vector's capacity units.

end Memcp.Text;
