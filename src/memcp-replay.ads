--  Memcp.Replay: deterministic clocks and embeddings, recorded per call. Inert
--  until Enable, so normal serving takes the wall clock and the live embedding
--  model; once armed, both come from the recorded data instead, which pins "now"
--  and side-steps numerical drift between embedding implementations.

with Candle_Spark;

package Memcp.Replay with
  SPARK_Mode     => On,
  Abstract_State => State,
  Initializes    => State
is

   procedure Enable  with Global => (In_Out => State);
   --  Arm the replay path: clocks and embeddings come from the recorded data.
   procedure Disable with Global => (In_Out => State);
   --  Return to the wall clock and the live embedding model; the default.
   function  Enabled return Boolean with Global => (Input => State);
   --  Whether the replay path is currently armed.
   --  @return True when Enable is in effect, False otherwise.

   procedure Begin_Call with Global => (In_Out => State);
   --  Discard the recorded clocks and embeddings, starting a fresh call.
   procedure Add_Clock (Iso : String) with Global => (In_Out => State);
   --  Queue one recorded clock value for the current call (FIFO order).
   --  @param Iso The recorded timestamp, as an ISO-8601 string.
   procedure Add_Embedding
     (Text : String; Vec : Candle_Spark.Embedding)
     with Global => (In_Out => State);
   --  Record the vector produced for Text in the current call.
   --  @param Text The input text that was embedded.
   --  @param Vec The recorded embedding to return on a later lookup of Text.

   ----------------------------------------------------------------------------
   --  The recorded side: meaningful only while Enabled
   ----------------------------------------------------------------------------

   function Has_Clock return Boolean with Global => (Input => State);
   --  Whether a recorded clock value is still queued for this call.
   --  @return True while at least one recorded clock value remains queued.

   function Peek_Clock return String with Global => (Input => State);
   --  The next queued clock value (FIFO, recorded order), without consuming it.
   --  @return The next recorded clock value, or "" when none is queued.

   procedure Advance_Clock with Global => (In_Out => State);
   --  Consume the clock Peek_Clock just returned (a no-op when none is queued).

   procedure Lookup_Embedding
     (Text  : String;
      Vec   : out Candle_Spark.Embedding;
      Found : out Boolean)
     with Global => (In_Out => State);
   --  The recorded vector for Text, if one was recorded this call. A miss yields
   --  the zero vector and is counted, since it means a text was embedded on this
   --  call that was never recorded.
   --  @param Text The input text whose recorded embedding is requested.
   --  @param Vec The recorded embedding on a hit, or the zero vector on a miss.
   --  @param Found True when Text had a recorded embedding, False on a miss.

   function Miss_Count return Natural with Global => (Input => State);
   --  Embedding lookups that missed since the last Begin_Call.
   --  @return The count of missed embedding lookups this call.
   function Last_Miss return String with Global => (Input => State);
   --  The most recent missed text.
   --  @return The text of the most recent missed lookup, or "" if none missed.

end Memcp.Replay;
