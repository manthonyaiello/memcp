--  Outbound JSON text construction.
--
--  json-ada is parse-oriented: it reads value trees and re-serializes them, but
--  has no first-class API to *construct* fresh values. Every response this
--  server emits is freshly built, so the outbound path is a small text writer
--  rather than a value tree (see the "asymmetric JSON seam" decision in
--  README.md). This package is that writer's foundation: RFC 8259 string
--  escaping. Everything else (the JSON-RPC / MCP envelopes) is a handful of
--  concatenations in Spark_Mcp.Server built on top of Quoted.
--
--  This unit is pure text -- no dependency on the json crate -- and is written
--  in SPARK so the one piece of genuinely fiddly logic (escaping) can be proved
--  free of run-time errors.

package Spark_Mcp.Writer with SPARK_Mode => On is

   Max_Expansion : constant := 6;
   --  A Character maps to at most this many characters when escaped: a control
   --  character with no short form becomes "\u00XX" (6 characters).

   function Escape (S : String) return String
   with
     Pre  => S'Length <= Natural'Last / Max_Expansion,
     Post => Escape'Result'First = 1
             and then Escape'Result'Length <= Max_Expansion * S'Length;
   --  Escape S into the *content* of a JSON string: the characters as they
   --  appear between the surrounding quotes of a JSON string literal, with ",
   --  \, and the control characters (RFC 8259) escaped. Bytes >= 16#20# --
   --  including UTF-8 continuation bytes -- pass through unchanged, which is
   --  valid JSON.
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

end Spark_Mcp.Writer;
