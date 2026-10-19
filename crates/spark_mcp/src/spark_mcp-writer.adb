--  Spark_Mcp.Writer body: escaping in one pass into a worst-case-sized buffer.

with Ada.Unchecked_Deallocation;

package body Spark_Mcp.Writer with SPARK_Mode => On is

   type Buffer_Ptr is access String;
   --  Escape's working buffer.

   procedure Free is new Ada.Unchecked_Deallocation (String, Buffer_Ptr);
   --  Reclaim a Buffer_Ptr's String, leaving the pointer null.

   Hex_Digit : constant array (0 .. 15) of Character := "0123456789abcdef";
   --  Lowercase hex digits indexed by value, for the "\u00XX" form.

   ------------
   -- Escape --
   ------------

   function Escape (S : String) return String is
      Buf  : Buffer_Ptr := new String'(1 .. Max_Expansion * S'Length => ' ');
      --  The escaped content, built in place. Sized for the worst case, so one
      --  pass never overflows, and on the heap, since that case is six times S;
      --  initialized in full so flow analysis sees Buf (1 .. Last) as defined.

      Last : Natural := 0;
      --  Index in Buf of the last character written.
   begin
      for I in S'Range loop
         pragma Loop_Invariant (Last <= Max_Expansion * (I - S'First));

         declare
            C    : constant Character := S (I);
            Code : constant Natural   := Character'Pos (C);
         begin
            case C is
               when '"' =>
                  Buf (Last + 1 .. Last + 2) := "\""";
                  Last := Last + 2;
               when '\' =>
                  Buf (Last + 1 .. Last + 2) := "\\";
                  Last := Last + 2;
               when Character'Val (8) =>   --  backspace
                  Buf (Last + 1 .. Last + 2) := "\b";
                  Last := Last + 2;
               when Character'Val (9) =>   --  tab
                  Buf (Last + 1 .. Last + 2) := "\t";
                  Last := Last + 2;
               when Character'Val (10) =>  --  line feed
                  Buf (Last + 1 .. Last + 2) := "\n";
                  Last := Last + 2;
               when Character'Val (12) =>  --  form feed
                  Buf (Last + 1 .. Last + 2) := "\f";
                  Last := Last + 2;
               when Character'Val (13) =>  --  carriage return
                  Buf (Last + 1 .. Last + 2) := "\r";
                  Last := Last + 2;
               when Character'Val (0)  .. Character'Val (7)
                  |  Character'Val (11)
                  |  Character'Val (14) .. Character'Val (31) =>
                  --  Any other control character: \u00XX.
                  Buf (Last + 1 .. Last + 6) :=
                    "\u00" & Hex_Digit (Code / 16) & Hex_Digit (Code mod 16);
                  Last := Last + 6;
               when others =>
                  Buf (Last + 1) := C;
                  Last := Last + 1;
            end case;
         end;
      end loop;

      return R : constant String := Buf (1 .. Last) do
         Free (Buf);
      end return;
   end Escape;

   ------------
   -- Quoted --
   ------------

   function Quoted (S : String) return String is
      E : constant String := Escape (S);
   begin
      return R : String (1 .. E'Length + 2) := (others => '"') do
         R (2 .. E'Length + 1) := E;
      end return;
   end Quoted;

   ------------
   -- Concat --
   ------------

   function Concat (Left, Right : String) return String is
   begin
      return R : String (1 .. Left'Length + Right'Length) := (others => ' ') do
         R (1 .. Left'Length) := Left;
         R (Left'Length + 1 .. R'Last) := Right;
      end return;
   end Concat;

end Spark_Mcp.Writer;
