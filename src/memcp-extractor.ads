--  Memcp.Extractor: base64-decode an uploaded transcript and split a Claude
--  Code `.jsonl` into its verbatim conversation turns plus the last
--  away_summary recap. Each transcript line is parsed with the json library
--  here, so that dependency stays contained.

with Ada.Unchecked_Deallocation;

with SPARK.Containers.Formal.Unbounded_Vectors;

with Spark_Mcp;

package Memcp.Extractor with SPARK_Mode => On is

   type Turn (Len : Natural) is record
      Text : String (1 .. Len);
   end record;
   --  One verbatim turn, its text sized by the discriminant so a list of turns
   --  holds no owning element.
   --  @field Len Length of the turn's text; discriminant that sizes Text.
   --  @field Text The verbatim turn text.

   package Turn_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Turn);
   --  Vector of Turn records in transcript order.

   subtype Turn_List is Turn_Vectors.Vector;
   --  A list of verbatim turns.

   type Transcript_Ptr is access String;
   --  A decoded transcript: caller-owned bytes, null when decoding failed.

   procedure Free is new Ada.Unchecked_Deallocation (String, Transcript_Ptr);
   --  Reclaim a decoded transcript.

   Max_Transcript : constant := Spark_Mcp.Max_Field;
   --  Cap on a decoded transcript's length, which is what makes line indexing
   --  here overflow-free.

   procedure Decode_Base64
     (Encoded : String;
      Decoded : out Transcript_Ptr;
      Ok      : out Boolean)
     with Post => (if not Ok then Decoded = null)
                  and then
                    (if Ok
                     then Decoded /= null
                          and then Decoded.all'First = 1
                          and then Decoded.all'Length <= Max_Transcript);
   --  Decode standard base64, strictly: no stray characters, no missing
   --  padding, and the decoded bytes must be well-formed UTF-8.
   --  @param Encoded The base64-encoded input text.
   --  @param Decoded The decoded bytes (caller-owned); null on failure.
   --  @param Ok True on success; False -- with Decoded null -- when Encoded is
   --   not well-formed base64, when the bytes are not valid UTF-8, or when the
   --   decoded length would exceed Max_Transcript. Length 0 decodes to a
   --   0-length string (Ok, non-null).

   function Extract_Turns (Transcript : String) return Turn_List
     with Pre => Transcript'First = 1 and then Transcript'Last < Natural'Last;
   --  One entry per surviving user/assistant message, in transcript order, each
   --  prefixed "[user] " or "[assistant] " and joining its text parts with a
   --  blank line. Non-JSON lines, non-conversation types and thinking-only or
   --  tool-only messages all drop out, so every returned turn is non-empty.
   --  @param Transcript The full decoded transcript text (1-based).
   --  @return The list of verbatim conversation turns.

   function Extract_Recap (Transcript : String) return String
     with Pre => Transcript'First = 1 and then Transcript'Last < Natural'Last;
   --  The stripped content of the last away_summary line
   --  ({"type":"system","subtype":"away_summary","content":"..."}), or "" when
   --  the transcript has none.
   --  @param Transcript The full decoded transcript text (1-based).
   --  @return The recap text, or "" when the transcript has no away_summary.

end Memcp.Extractor;
