--  Vocabulary of the generic tool seam.
--
--  A tool invocation produces exactly one of:
--    * a success result -- the tool's payload, already serialized as JSON text
--      (the outbound path is text; see Spark_Mcp.Writer), OR
--    * a failure -- a JSON-RPC error code plus a human-readable message.
--
--  Content/Message are held as fixed String components sized by a Len
--  discriminant -- no controlled type (Unbounded_String) and no arbitrary
--  cap (bounded string), so the seam stays exact and SPARK-friendly: a value
--  is built fully-initialized by the constructors below and read directly (no
--  copy-out, no finalization). The type is therefore indefinite -- always
--  constructed complete, never declared blank and filled in later.
--
--  Because Invocation_Result is indefinite AND Invoke is now a procedure (it
--  mutates the application state a tool owns; see Spark_Mcp.Server), the result
--  cannot travel through a plain out parameter -- so Invoke hands out a
--  Result_Ptr: an exactly-sized ownership allocation the caller (Respond) reads
--  once and Frees. This mirrors Spark_Mcp.Response_Ptr one level up.

with Ada.Unchecked_Deallocation;

package Spark_Mcp.Tools with SPARK_Mode => On is

   type Invocation_Result (Ok : Boolean; Len : Natural) is record
      case Ok is
         when True =>
            Content : String (1 .. Len);
         when False =>
            Code    : Error_Code;
            Message : String (1 .. Len);
      end case;
   end record
   with Dynamic_Predicate => Invocation_Result.Len <= Max_Field;
   --  One tool invocation's outcome: a success payload or a failure. Content and
   --  Message are fixed Strings sized by the Len discriminant -- no controlled
   --  type (Unbounded_String) and no arbitrary cap (bounded string) -- so the
   --  seam stays exact and SPARK-friendly; the type is therefore indefinite,
   --  always constructed complete by the constructors below and read directly.
   --  Len is bounded by Max_Field so that Spark_Mcp.Server can wrap a result
   --  into a JSON-RPC response without overflowing a String index -- every
   --  consumer may assume Len <= Max_Field (see the Max_Field rationale in
   --  Spark_Mcp); the constructors below establish it.
   --  @field Ok True selects the success variant; False selects the failure one.
   --  @field Len Length of the variant's String component; bounded by Max_Field.
   --  @field Content JSON text of the tool's result payload (an object or array).
   --  @field Code JSON-RPC error code for the failure variant.
   --  @field Message Human-readable failure message for the failure variant.

   function Success (Content_Json : String) return Invocation_Result is
     ((Ok => True, Len => Content_Json'Length, Content => Content_Json))
   with Pre => Content_Json'Length <= Max_Field;
   --  Convenience constructor for a success result. Len is derived from the
   --  argument, so callers never mention the discriminant; the precondition
   --  upholds the type's Len <= Max_Field predicate.
   --  @param Content_Json JSON text of the tool's result payload.
   --  @return A success Invocation_Result wrapping Content_Json.

   function Failure
     (Code : Error_Code; Message : String) return Invocation_Result is
     ((Ok      => False,
       Len     => Message'Length,
       Code    => Code,
       Message => Message))
   with Pre => Message'Length <= Max_Field;
   --  Convenience constructor for a failure result. Len is derived from Message,
   --  so callers never mention the discriminant; the precondition upholds the
   --  type's Len <= Max_Field predicate.
   --  @param Code The JSON-RPC error code to report.
   --  @param Message Human-readable description of the failure.
   --  @return A failure Invocation_Result wrapping Code and Message.

   type Result_Ptr is access Invocation_Result;
   --  Ownership pointer to a result built by one of the constructors above: the
   --  out-parameter handoff for the (procedure) Invoke seam. A tool does
   --  `Result := new Invocation_Result'(Success (...))` (or Failure); Respond
   --  reads it once and Frees it. Never null on return from a conforming Invoke
   --  (Respond treats a null as an internal error). Mirrors Spark_Mcp.Response_Ptr.

   procedure Free is new Ada.Unchecked_Deallocation
     (Invocation_Result, Result_Ptr);
   --  Reclaim a Result_Ptr allocation; Respond calls this once it has read the
   --  result payload. Sets the pointer to null.

end Spark_Mcp.Tools;
