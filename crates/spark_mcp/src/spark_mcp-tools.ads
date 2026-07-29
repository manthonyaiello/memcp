--  Vocabulary of the generic tool seam: one invocation's outcome -- a JSON
--  payload or a JSON-RPC error -- its two constructors, and the ownership
--  pointer a tool hands it out through.

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
   --  One tool invocation's outcome: a success payload or a failure. Indefinite,
   --  so a value is always constructed complete -- use the constructors below,
   --  which also establish the Max_Field bound every consumer may assume.
   --  @field Ok True selects the success variant; False selects the failure one.
   --  @field Len Length of the variant's String component; bounded by Max_Field.
   --  @field Content JSON text of the tool's result payload (an object or array).
   --  @field Code JSON-RPC error code for the failure variant.
   --  @field Message Human-readable failure message for the failure variant.

   function Success (Content_Json : String) return Invocation_Result is
     ((Ok => True, Len => Content_Json'Length, Content => Content_Json))
   with Pre => Content_Json'Length <= Max_Field;
   --  Build a success result, deriving Len from the argument so callers never
   --  mention the discriminant.
   --  @param Content_Json JSON text of the tool's result payload.
   --  @return A success Invocation_Result wrapping Content_Json.

   function Failure
     (Code : Error_Code; Message : String) return Invocation_Result is
     ((Ok      => False,
       Len     => Message'Length,
       Code    => Code,
       Message => Message))
   with Pre => Message'Length <= Max_Field;
   --  Build a failure result, deriving Len from Message so callers never mention
   --  the discriminant.
   --  @param Code The JSON-RPC error code to report.
   --  @param Message Human-readable description of the failure.
   --  @return A failure Invocation_Result wrapping Code and Message.

   type Result_Ptr is access Invocation_Result;
   --  How an invocation's outcome is handed out, the type being indefinite:
   --  `Result := new Invocation_Result'(Success (...))`. Read once, then Freed.
   --  A null is treated as an internal error, so a conforming tool never
   --  returns one.

   procedure Free is new Ada.Unchecked_Deallocation
     (Invocation_Result, Result_Ptr);
   --  Reclaim a Result_Ptr allocation, leaving the pointer null.

end Spark_Mcp.Tools;
