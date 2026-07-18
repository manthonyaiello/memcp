--  Vocabulary of the inbound JSON-RPC 2.0 envelope seam.
--
--  spark_mcp is json-free: it never parses request text itself. The application
--  supplies a Parse_Envelope function (a generic formal of Spark_Mcp.Server)
--  that decodes request text -- with the application's own JSON library -- into
--  this neutral Envelope record. Spark_Mcp.Server.Dispatch then maps the
--  Envelope to a response and owns ALL JSON-RPC response framing. The split:
--  the application decodes bytes -> fields; spark_mcp owns the MCP method layer
--  and the wire shape of every response (see Spark_Mcp.Server.Respond).
--
--  This type lives here, in a non-generic package, rather than inside
--  Spark_Mcp.Server, because the formal Parse_Envelope returns it: an
--  application must be able to name the type BEFORE instantiating the generic.
--
--  The string fields are fixed String components sized by the *_Len
--  discriminants, matching Spark_Mcp.Tools: no controlled type, no cap, no
--  copy-out. The record is therefore indefinite and built fully-initialized in
--  one aggregate (see Memcp_Envelope.Decode and No_Parser); an error Kind sets
--  every length to 0.

package Spark_Mcp.Requests with SPARK_Mode => On is

   type Parse_Result_Kind is (Parsed, Bad_Json, Bad_Request, Unimplemented);
   --  How decoding a request envelope turned out. Dispatch maps each to a
   --  response (see the parenthesised JSON-RPC outcome).
   --  @enum Parsed A well-formed JSON-RPC 2.0 request; the fields below are
   --    populated and routed by Respond.
   --  @enum Bad_Json The request text was not valid JSON (=> Parse_Error).
   --  @enum Bad_Request Valid JSON but not a valid JSON-RPC 2.0 request -- e.g.
   --    a missing/non-"2.0" "jsonrpc" or a non-string "method"
   --    (=> Invalid_Request).
   --  @enum Unimplemented No parser wired / the parser cannot decode
   --    (=> Internal_Error). A conforming parser never returns this; it is the
   --    honest fallback of Requests.No_Parser below.

   type Envelope
     (M_Len   : Natural;   --  length of Method
      Id_Len  : Natural;   --  length of Id
      TN_Len  : Natural;   --  length of Tool_Name
      Arg_Len : Natural)   --  length of Arguments
   is record
      Kind            : Parse_Result_Kind := Unimplemented;

      --  True when the request carried no "id": no response is owed.
      Is_Notification : Boolean           := False;

      --  The JSON-RPC "method".
      Method          : String (1 .. M_Len);

      --  The request's "id" as its VERBATIM JSON token ("42", "null", or a
      --  quoted string like """abc"""), echoed into the response. Ignored when
      --  Is_Notification.
      Id              : String (1 .. Id_Len);

      --  For method "tools/call": params.name ("" otherwise).
      Tool_Name       : String (1 .. TN_Len);

      --  For method "tools/call": params.arguments as raw JSON text ("{}" when
      --  absent, supplied by the parser); handed opaquely to the tool's Invoke.
      Arguments       : String (1 .. Arg_Len);
   end record
   --  Every field is bounded by Max_Field (see Spark_Mcp) so that Dispatch can
   --  route an Envelope straight into Spark_Mcp.Server.Respond, whose
   --  precondition requires exactly this. A conforming Parse_Envelope must
   --  produce envelopes within the bound; No_Parser (all lengths 0) trivially
   --  does, as does the all-zero shape of every non-Parsed Kind.
   with Dynamic_Predicate =>
     M_Len <= Max_Field and then Id_Len <= Max_Field
     and then TN_Len <= Max_Field and then Arg_Len <= Max_Field;
   --  A decoded JSON-RPC 2.0 request. Only the Parsed case populates the
   --  fields; for every other Kind, Dispatch frames the error from Kind alone
   --  (so a non-Parsed envelope carries every *_Len => 0).

   function No_Parser (Request : String) return Envelope;
   --  The default Parse_Envelope for Spark_Mcp.Server: reports Unimplemented,
   --  which Dispatch renders as an honest Internal_Error ("no parser wired")
   --  rather than a silently-wrong result. It lets the reusable core be built,
   --  proved, and unit-tested with NO JSON library at all (the tests drive
   --  Respond directly); an application that wants a live Dispatch supplies its
   --  own JSON-based parser at instantiation (see memcp's Memcp_Envelope).
   --  @param Request The raw request text (ignored; no decoding is attempted).
   --  @return An Envelope with Kind => Unimplemented and every *_Len => 0.

end Spark_Mcp.Requests;
