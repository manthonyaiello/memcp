with Ada.Containers; use type Ada.Containers.Count_Type;

package body Memcp_Text with SPARK_Mode => On is

   -----------
   -- Reset --
   -----------

   procedure Reset (B : out Builder) is
   begin
      B.Chars := Char_Vectors.Empty_Vector;
      B.Over  := False;
   end Reset;

   ---------
   -- Add --
   ---------

   procedure Add (B : in out Builder; C : Character) is
   begin
      if Char_Vectors.Length (B.Chars) >= Cap then
         B.Over := True;
      else
         Char_Vectors.Append (B.Chars, C);
      end if;
   end Add;

   procedure Add (B : in out Builder; S : String) is
   begin
      for I in S'Range loop
         pragma Loop_Invariant
           (Char_Vectors.Length (B.Chars) <= Cap);
         if Char_Vectors.Length (B.Chars) >= Cap then
            B.Over := True;
         else
            Char_Vectors.Append (B.Chars, S (I));
         end if;
      end loop;
   end Add;

   ----------------
   -- Overflowed --
   ----------------

   function Overflowed (B : Builder) return Boolean is (B.Over);

   ------------
   -- Length --
   ------------

   function Length (B : Builder) return Natural is
     (Natural (Char_Vectors.Length (B.Chars)));

   -----------
   -- Value --
   -----------

   function Value (B : Builder) return String is
      Len : constant Natural := Natural (Char_Vectors.Length (B.Chars));
   begin
      return R : String (1 .. Len) do
         for I in 1 .. Len loop
            R (I) := Char_Vectors.Element (B.Chars, I);
         end loop;
      end return;
   end Value;

end Memcp_Text;
