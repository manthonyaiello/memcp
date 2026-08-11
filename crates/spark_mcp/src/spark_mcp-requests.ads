--  Vocabulary of the inbound JSON-RPC 2.0 envelope seam: the neutral record a
--  Parse_Envelope function decodes request text into, and the default parser
--  that decodes nothing. Non-generic, because Spark_Mcp.Server's formal returns
--  the type and so must be able to name it before instantiation.

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
      Arg_Len : Natural;   --  length of Arguments
      CN_Len  : Natural;   --  length of Client_Name
      CV_Len  : Natural)   --  length of Client_Version
   is record
      Kind            : Parse_Result_Kind := Unimplemented;
      --  How decoding turned out; the fields below are meaningful only when
      --  Parsed.

      Is_Notification : Boolean           := False;
      --  True when the request carried no "id": no response is owed.

      Method          : String (1 .. M_Len);
      --  The JSON-RPC "method".

      Id              : String (1 .. Id_Len);
      --  The request's "id" as its verbatim JSON token ("42", "null", or a
      --  quoted string like """abc"""), echoed into the response. Ignored when
      --  Is_Notification.

      Tool_Name       : String (1 .. TN_Len);
      --  For method "tools/call": params.name ("" otherwise).

      Arguments       : String (1 .. Arg_Len);
      --  For method "tools/call": params.arguments as raw JSON text ("{}" when
      --  absent, supplied by the parser); handed opaquely to the tool's Invoke.

      Client_Name     : String (1 .. CN_Len);
      --  For method "initialize": params.clientInfo.name ("" otherwise, and ""
      --  when the client sent none).

      Client_Version  : String (1 .. CV_Len);
      --  For method "initialize": params.clientInfo.version, verbatim ("" when
      --  the client sent none). Uninterpreted here: what a version string means
      --  is the application's business, reached through Server's Client_Meta.
   end record
   with Dynamic_Predicate =>
     --  A conforming Parse_Envelope must stay within the bound. The all-zero
     --  lengths of No_Parser and of every non-Parsed Kind trivially do.
     M_Len <= Max_Field and then Id_Len <= Max_Field
     and then TN_Len <= Max_Field and then Arg_Len <= Max_Field
     and then CN_Len <= Max_Field and then CV_Len <= Max_Field;
   --  A decoded JSON-RPC 2.0 request. A non-Parsed envelope carries every
   --  *_Len => 0, since the error is framed from Kind alone.

   function No_Parser (Request : String) return Envelope;
   --  The default Parse_Envelope: reports Unimplemented, which renders as an
   --  honest Internal_Error rather than a silently-wrong result, so the crate
   --  can be built, proved and tested with no JSON library at all.
   --  @param Request The raw request text (ignored; no decoding is attempted).
   --  @return An Envelope with Kind => Unimplemented and every *_Len => 0.

end Spark_Mcp.Requests;
