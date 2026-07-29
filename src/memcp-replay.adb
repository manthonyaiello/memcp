--  Recorded clocks kept as a vector plus a consumption cursor, recorded
--  embeddings as a vector searched linearly: a fixture holds a few hundred
--  entries, so neither wants an index.

with Ada.Containers; use type Ada.Containers.Count_Type;

with SPARK.Containers.Formal.Unbounded_Vectors;

with Memcp.Text;

package body Memcp.Replay with
  SPARK_Mode    => On,
  Refined_State =>
    (State =>
       (Is_On, Clocks, Clock_Cur, Embs, Misses, Miss_Text))
is

   type Clock_Entry (Len : Natural) is record
      Value : String (1 .. Len);
   end record;
   --  One recorded clock value, indefinite so the vector needs no owning
   --  element.

   --  The recorded clock values of one call, in recorded order.
   package Clock_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Clock_Entry);

   type Emb_Entry (Len : Natural) is record
      Text : String (1 .. Len);
      Vec  : Candle_Spark.Embedding;
   end record;
   --  One recorded embedding, keyed by the text it was produced from.

   --  The recorded embeddings of one call.
   package Emb_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Emb_Entry);

   Max_Entries : constant Clock_Vectors.Capacity_Range := 1_000_000;
   --  Soft cap on recorded entries per call, keeping Add_* clear of
   --  Count_Type'Last; an Add past it is silently dropped.

   Is_On     : Boolean := False;
   --  Whether the replay path is armed.

   Clocks    : Clock_Vectors.Vector;
   --  Recorded clock values for the current call.

   Clock_Cur : Natural := 0;
   --  How many of Clocks have been consumed by Advance_Clock.

   Embs      : Emb_Vectors.Vector;
   --  Recorded embeddings for the current call.

   Misses    : Natural := 0;
   --  Embedding lookups that found no recorded vector, saturating rather than
   --  overflowing.

   Miss_Text : Memcp.Text.Builder;
   --  The text of the most recent missed lookup.

   ------------
   -- Enable --
   ------------

   procedure Enable  is begin Is_On := True;  end Enable;
   procedure Disable is begin Is_On := False; end Disable;
   function  Enabled return Boolean is (Is_On);

   ----------------
   -- Begin_Call --
   ----------------

   procedure Begin_Call is
   begin
      Clock_Vectors.Clear (Clocks);
      Emb_Vectors.Clear (Embs);
      Clock_Cur := 0;
      Misses    := 0;
      Memcp.Text.Reset (Miss_Text);
   end Begin_Call;

   ---------------
   -- Add_Clock --
   ---------------

   procedure Add_Clock (Iso : String) is
   begin
      if Clock_Vectors.Length (Clocks) < Max_Entries then
         Clock_Vectors.Append (Clocks, (Len => Iso'Length, Value => Iso));
      end if;
   end Add_Clock;

   -------------------
   -- Add_Embedding --
   -------------------

   procedure Add_Embedding
     (Text : String; Vec : Candle_Spark.Embedding) is
   begin
      if Emb_Vectors.Length (Embs) < Max_Entries then
         Emb_Vectors.Append
           (Embs, (Len => Text'Length, Text => Text, Vec => Vec));
      end if;
   end Add_Embedding;

   ---------------
   -- Has_Clock --
   ---------------

   function Has_Clock return Boolean is
     (Clock_Cur < Natural (Clock_Vectors.Length (Clocks)));

   ----------------
   -- Peek_Clock --
   ----------------

   function Peek_Clock return String is
     (if Clock_Cur < Natural (Clock_Vectors.Length (Clocks))
      then Clock_Vectors.Element (Clocks, Clock_Cur + 1).Value
      else "");

   -------------------
   -- Advance_Clock --
   -------------------

   procedure Advance_Clock is
   begin
      if Clock_Cur < Natural (Clock_Vectors.Length (Clocks)) then
         Clock_Cur := Clock_Cur + 1;
      end if;
   end Advance_Clock;

   ----------------------
   -- Lookup_Embedding --
   ----------------------

   procedure Lookup_Embedding
     (Text  : String;
      Vec   : out Candle_Spark.Embedding;
      Found : out Boolean) is
   begin
      for I in 1 .. Natural (Emb_Vectors.Length (Embs)) loop
         declare
            E : constant Emb_Entry := Emb_Vectors.Element (Embs, I);
         begin
            if E.Text = Text then
               Vec   := E.Vec;
               Found := True;
               return;
            end if;
         end;
      end loop;
      Vec   := [others => 0.0];
      Found := False;
      if Misses < Natural'Last then
         Misses := Misses + 1;
      end if;
      Memcp.Text.Reset (Miss_Text);
      Memcp.Text.Add (Miss_Text, Text);
   end Lookup_Embedding;

   ----------------
   -- Miss_Count --
   ----------------

   function Miss_Count return Natural is (Misses);
   function Last_Miss  return String  is (Memcp.Text.Value (Miss_Text));

end Memcp.Replay;
