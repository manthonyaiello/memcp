--  Spark_Mcp.Writer: the outbound JSON path's foundation -- RFC 8259 string
--  escaping and quoting, on top of which a response is a few concatenations.
--  Pure text, with no dependency on any JSON library.

package Spark_Mcp.Writer with SPARK_Mode => On is

   Max_Expansion : constant := 6;
   --  The most characters an escaped Character can occupy: a control character
   --  with no short form becomes "\u00XX".

   function Escape (S : String) return String
   with
     Pre  => S'Length <= Natural'Last / Max_Expansion,
     Post => Escape'Result'First = 1
             and then Escape'Result'Length <= Max_Expansion * S'Length;
   --  Escape S into the content of a JSON string -- what sits between the
   --  surrounding quotes -- escaping ", \ and the control characters. Bytes
   --  >= 16#20#, UTF-8 continuation bytes included, pass through unchanged.
   --  @param S The raw text to escape.
   --  @return The escaped content, ready to sit between JSON string quotes.

   function Quoted (S : String) return String
   with
     Pre  => S'Length <= Natural'Last / Max_Expansion - 2,
     Post => Quoted'Result'First = 1
             and then Quoted'Result'Length = Escape (S)'Length + 2;
   --  A complete JSON string literal: Escape (S) wrapped in double quotes.
   --  @param S The raw text to render as a JSON string literal.
   --  @return The escaped text enclosed in double quotes.

   function Concat (Left, Right : String) return String
   with
     Pre  => Right'Length < Natural'Last - Left'Length,
     Post => Concat'Result'First = 1
             and then Concat'Result'Length = Left'Length + Right'Length
             and then Concat'Result (1 .. Left'Length) = Left
             and then Concat'Result (Left'Length + 1 .. Concat'Result'Last)
                      = Right;
   --  Left & Right, built where the result lives. The predefined "&" on
   --  operands of unbounded length builds its result as a temporary of that
   --  length in the caller's frame.
   --  @param Left The leading text.
   --  @param Right The trailing text.
   --  @return Left followed by Right, indexed from 1.

end Spark_Mcp.Writer;
