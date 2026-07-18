--  Conformance-replay injection point. Inert unless Enable has been called, so
--  production (main) never touches it: normal serving takes the wall clock and
--  the candle model. When enabled, the tool layer draws its timestamps and its
--  embeddings from data the harness loads per tools/call -- reproducing the
--  Python oracle's recorded run deterministically, bypassing candle-vs-torch
--  numerical drift and pinning "now".
--
--  SPARK_Mode On, holding its FIFO clock queue + embedding table as this
--  package's Abstract_State. The clock is consumed with Peek_Clock /
--  Advance_Clock (a SPARK function may not mutate state, so the old popping
--  Next_Clock became a peek plus a separate advance).

with Candle_Spark;

package Memcp_Replay with
  SPARK_Mode     => On,
  Abstract_State => State,
  Initializes    => State
is

   procedure Enable  with Global => (In_Out => State);
   --  Arm the replay path so the tool layer draws clocks and embeddings from
   --  the harness-loaded data instead of the wall clock and the candle model.
   procedure Disable with Global => (In_Out => State);
   --  Return to normal serving (wall clock + candle model); the inert default.
   function  Enabled return Boolean with Global => (Input => State);
   --  Whether the replay path is currently armed.
   --  @return True when Enable is in effect, False otherwise.

   procedure Begin_Call with Global => (In_Out => State);
   --  Reset the per-call clock queue + embedding table. The harness calls this
   --  before each Dispatch, then Add_* the record's recorded clock/embeddings.
   procedure Add_Clock (Iso : String) with Global => (In_Out => State);
   --  Queue one recorded clock value for the current call (FIFO order).
   --  @param Iso The recorded timestamp, as an ISO-8601 string.
   procedure Add_Embedding
     (Text : String; Vec : Candle_Spark.Embedding)
     with Global => (In_Out => State);
   --  Record the vector the oracle produced for Text in the current call.
   --  @param Text The input text that was embedded.
   --  @param Vec The recorded embedding to return on a later lookup of Text.

   ----------------------------------------------------------------------------
   --  Consumed by the tool layer (meaningful only while Enabled)
   ----------------------------------------------------------------------------

   function Has_Clock return Boolean with Global => (Input => State);
   --  Whether a recorded clock value is still queued for this call.
   --  @return True while at least one recorded clock value remains queued.

   function Peek_Clock return String with Global => (Input => State);
   --  The next queued clock value (FIFO, recorded order), without consuming it.
   --  @return The next recorded clock value, or "" when none is queued (total,
   --    so callers need no precondition).

   procedure Advance_Clock with Global => (In_Out => State);
   --  Consume the clock Peek_Clock just returned (a no-op when none is queued).

   procedure Lookup_Embedding
     (Text  : String;
      Vec   : out Candle_Spark.Embedding;
      Found : out Boolean)
     with Global => (In_Out => State);
   --  The recorded vector for Text, if one was recorded this call. A miss
   --  yields the zero vector, Found => False, and is counted (see Miss_Count):
   --  it means the SPARK path embedded a text the oracle did not, which the
   --  harness surfaces as a failure rather than letting it pass silently.
   --  @param Text The input text whose recorded embedding is requested.
   --  @param Vec The recorded embedding on a hit, or the zero vector on a miss.
   --  @param Found True when Text had a recorded embedding, False on a miss.

   function Miss_Count return Natural with Global => (Input => State);
   --  Embedding lookups that missed since the last Begin_Call.
   --  @return The count of missed embedding lookups this call.
   function Last_Miss return String with Global => (Input => State);
   --  The most recent missed text (for a diagnostic line).
   --  @return The text of the most recent missed lookup, or "" if none missed.

end Memcp_Replay;
