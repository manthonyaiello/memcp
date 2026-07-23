--  Ports extractor.py: base64-decode an uploaded transcript and split a Claude
--  Code `.jsonl` into the verbatim conversation turns memcp embeds, plus the
--  last `※ recap` line. It parses each line with the json library directly
--  (contained here, exactly as Memcp.Envelope does).
--
--  SPARK_Mode On. The neutral value carriers are SPARK-friendly: a decoded
--  transcript is an owning access-to-String (Transcript_Ptr, freed by the
--  caller), and the turns are a SPARKlib vector of an indefinite String record
--  -- no controlled Unbounded_String, no standard container. The parser
--  lifecycle (Create/Parse/Destroy) and Free are fully proved leak-free and
--  terminating: json now carries ownership + Always_Terminates contracts on its
--  public API, so no check here is left failing or justified.

with Ada.Unchecked_Deallocation;

with SPARK.Containers.Formal.Unbounded_Vectors;

with Spark_Mcp;

package Memcp.Extractor with SPARK_Mode => On is

   type Turn (Len : Natural) is record
      Text : String (1 .. Len);
   end record;
   --  One verbatim turn. Indefinite: its text is sized by Len, so a list of
   --  them lives in a SPARKlib vector without any owning element.
   --  @field Len Length of the turn's text; discriminant that sizes Text.
   --  @field Text The verbatim turn text.

   package Turn_Vectors is new SPARK.Containers.Formal.Unbounded_Vectors
     (Index_Type => Positive, Element_Type => Turn);
   --  SPARKlib unbounded vector instance holding Turn records in transcript
   --  order.
   subtype Turn_List is Turn_Vectors.Vector;
   --  A list of verbatim turns, as returned by Extract_Turns.

   type Transcript_Ptr is access String;
   --  A decoded transcript: caller-owned bytes. null iff Decode_Base64 failed.
   procedure Free is new Ada.Unchecked_Deallocation (String, Transcript_Ptr);
   --  Reclaims a Transcript_Ptr allocated by Decode_Base64.

   Max_Transcript : constant := Spark_Mcp.Max_Field;
   --  Cap on a decoded transcript length (= the field budget), so line indexing
   --  in the extractors is provably overflow-free.

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
   --  Decode standard, strict base64 (server.py uses validate=True) into its
   --  bytes. UTF-8 validity is not separately checked: every consumer treats
   --  the bytes opaquely.
   --  @param Encoded The base64-encoded input text.
   --  @param Decoded The decoded bytes (caller-owned); null on failure.
   --  @param Ok True on success; False -- with Decoded null -- when the input
   --   is not well-formed base64 (upload_session then reports Invalid_Params,
   --   matching server.py's ValueError) or when the decoded length would exceed
   --   the field budget. Length 0 decodes to a 0-length string (Ok, non-null).

   function Extract_Turns (Transcript : String) return Turn_List
     with Pre => Transcript'First = 1 and then Transcript'Last < Natural'Last;
   --  extractor.py extract_turns: one entry per surviving user/assistant
   --  message, in transcript order, each prefixed "[user] " / "[assistant] "
   --  and joining its text parts with a blank line. Non-JSON lines,
   --  non-conversation types, thinking-only / tool-only messages all drop out,
   --  so every returned turn is non-empty.
   --  @param Transcript The full decoded transcript text (1-based).
   --  @return The list of verbatim conversation turns.

   function Extract_Recap (Transcript : String) return String
     with Pre => Transcript'First = 1 and then Transcript'Last < Natural'Last;
   --  extractor.py extract_recap: the text of the last away_summary line
   --  ({"type":"system","subtype":"away_summary","content":"..."}), stripped,
   --  or "" when the transcript contains none.
   --  @param Transcript The full decoded transcript text (1-based).
   --  @return The recap text, or "" when the transcript has no away_summary.

end Memcp.Extractor;
