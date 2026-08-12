--  Memcp.Envelope body: parse the request text with the json crate, then
--  project the resulting document onto Spark_Mcp.Requests.Envelope.

with JSON.Types;
with JSON.Parsers;
with JSON.Streams;

package body Memcp.Envelope with SPARK_Mode => On is

   --  Shorthand for the neutral request types this unit returns.
   package Req renames Spark_Mcp.Requests;

   Max_Field : constant := Spark_Mcp.Max_Field;
   --  Length cap on each field of an Envelope.

   --  A JSON value model wide enough for request ids and arbitrary tool
   --  arguments. The numeric types only bound what the tokenizer accepts; the
   --  envelope reads strings and re-serialises subtrees, so their exact range
   --  is immaterial.
   package Types is new JSON.Types
     (Integer_Type => Long_Long_Integer, Float_Type => Long_Float);

   --  The parser, with generous nesting depth so a valid request is never
   --  rejected as a parse error for nesting depth alone.
   package Parsers is new JSON.Parsers
     (Types => Types, Default_Maximum_Depth => 512);

   use type Types.Value_Kind;
   use type Types.JSON_Value_Access;

   Bad_Json : constant Req.Envelope :=
     (M_Len   => 0, Id_Len  => 0, TN_Len => 0, Arg_Len => 0,
      CN_Len  => 0, CV_Len  => 0,
      Kind    => Req.Bad_Json, Is_Notification => False,
      Method  => "", Id => "", Tool_Name => "", Arguments => "",
      Client_Name => "", Client_Version => "");
   --  The envelope for text that is not valid JSON: every length zero, so the
   --  error response is framed from Kind alone.

   Bad_Req  : constant Req.Envelope :=
     (M_Len   => 0, Id_Len  => 0, TN_Len => 0, Arg_Len => 0,
      CN_Len  => 0, CV_Len  => 0,
      Kind    => Req.Bad_Request, Is_Notification => False,
      Method  => "", Id => "", Tool_Name => "", Arguments => "",
      Client_Name => "", Client_Version => "");
   --  The envelope for valid JSON that is not a JSON-RPC 2.0 request.

   ------------------
   -- To_Json_Text --
   ------------------

   function To_Json_Text
     (Value : not null access constant Types.JSON_Value) return String;
   --  Re-serialise a parsed value to its JSON text. A value whose text would
   --  overflow the buffer -- impossible for a transport-capped request --
   --  degrades to "".

   function To_Json_Text
     (Value : not null access constant Types.JSON_Value) return String
   is
      Buf : JSON.Streams.String_Buffer;
      --  Scratch buffer for the text; Destroy reclaims it on both the normal
      --  and the overflow path.
   begin
      Types.Image (Value, Buf);
      declare
         Result : constant String := JSON.Streams.To_String (Buf);
      begin
         JSON.Streams.Destroy (Buf);
         return Result;
      end;
   exception
      when JSON.Streams.Buffer_Overflow_Error =>
         JSON.Streams.Destroy (Buf);
         return "";
   end To_Json_Text;

   ----------------
   -- Obj_Member --
   ----------------

   function Obj_Member
     (Obj : access constant Types.JSON_Value; Key : String)
      return access constant Types.JSON_Value;
   --  The member Key of Obj, or null when Obj is null, is not an object, or
   --  has no such member. Statement form rather than an expression function:
   --  the observer is rooted at Obj, and a conditional expression may not
   --  observe. Null-safe, so nested members can be fetched unconditionally.

   function Obj_Member
     (Obj : access constant Types.JSON_Value; Key : String)
      return access constant Types.JSON_Value
   is
   begin
      if Obj = null or else Types.Kind (Obj) /= Types.Object_Kind then
         return null;
      end if;
      return Types.Get (Obj, Key);
   end Obj_Member;

   ------------
   -- Decode --
   ------------

   function Decode
     (Doc : not null access constant Types.JSON_Value) return Req.Envelope;
   --  Validate an already-parsed document and extract its fields. Doc is
   --  non-null by Parsers.Parse's postcondition. Any field that would exceed
   --  Max_Field -- never, for a transport-capped request -- degrades the
   --  whole request to Bad_Request.

   function Decode
     (Doc : not null access constant Types.JSON_Value) return Req.Envelope
   is
   begin
      if Types.Kind (Doc) /= Types.Object_Kind then
         return Bad_Req;
      end if;

      --  "jsonrpc" must be exactly the string "2.0".
      declare
         JV : constant access constant Types.JSON_Value :=
           Types.Get (Doc, "jsonrpc");
      begin
         if JV = null
           or else Types.Kind (JV) /= Types.String_Kind
           or else Types.Value (JV) /= "2.0"
         then
            return Bad_Req;
         end if;
      end;

      --  "method" must be a string.
      declare
         MV : constant access constant Types.JSON_Value :=
           Types.Get (Doc, "method");
      begin
         if MV = null or else Types.Kind (MV) /= Types.String_Kind then
            return Bad_Req;
         end if;

         declare
            Method : constant String := Types.Value (MV);

            IV       : constant access constant Types.JSON_Value :=
              Types.Get (Doc, "id");
            --  The "id" member, or null when the request carries none.

            Is_Notif : constant Boolean := (IV = null);
            --  A request without "id" is a notification.

            Id       : constant String :=
              (if Is_Notif then "" else To_Json_Text (IV));
            --  The id as its verbatim JSON token, to be echoed in the response.

            Is_Call   : constant Boolean := (Method = "tools/call");
            --  Whether this is the one method that carries params.name and
            --  params.arguments.

            Is_Init   : constant Boolean := (Method = "initialize");
            --  Whether this is the one method that carries params.clientInfo.

            PV        : constant access constant Types.JSON_Value :=
              Obj_Member (Doc, "params");
            --  The "params" member, or null.

            NV        : constant access constant Types.JSON_Value :=
              Obj_Member (PV, "name");
            --  params.name, or null.

            AV        : constant access constant Types.JSON_Value :=
              Obj_Member (PV, "arguments");
            --  params.arguments, or null.

            CIV       : constant access constant Types.JSON_Value :=
              Obj_Member (PV, "clientInfo");
            --  params.clientInfo, or null.

            CNV       : constant access constant Types.JSON_Value :=
              Obj_Member (CIV, "name");
            --  params.clientInfo.name, or null.

            CVV       : constant access constant Types.JSON_Value :=
              Obj_Member (CIV, "version");
            --  params.clientInfo.version, or null. Every member is fetched
            --  unconditionally, with the Is_Call and Is_Init gates applied to
            --  the values below, so no observe sits inside a conditional
            --  expression.

            Tool_Name : constant String :=
              (if Is_Call and then NV /= null
                 and then Types.Kind (NV) = Types.String_Kind
               then Types.Value (NV) else "");
            --  The tool to invoke, or "" for any other method.

            Args      : constant String :=
              (if Is_Call and then AV /= null then To_Json_Text (AV) else "{}");
            --  The tool arguments as raw JSON text, "{}" when absent.

            CName     : constant String :=
              (if Is_Init and then CNV /= null
                 and then Types.Kind (CNV) = Types.String_Kind
               then Types.Value (CNV) else "");
            --  The client's name, or "" for any other method.

            CVersion  : constant String :=
              (if Is_Init and then CVV /= null
                 and then Types.Kind (CVV) = Types.String_Kind
               then Types.Value (CVV) else "");
            --  The client's version, or "" for any other method. A non-string
            --  version is dropped rather than rejected: clientInfo is
            --  informational, and refusing the handshake over it would break a
            --  client the server can otherwise serve.
         begin
            if Method'Length > Max_Field or else Id'Length > Max_Field
              or else Tool_Name'Length > Max_Field
              or else Args'Length > Max_Field
              or else CName'Length > Max_Field
              or else CVersion'Length > Max_Field
            then
               return Bad_Req;
            end if;

            return
              (M_Len     => Method'Length,     Id_Len  => Id'Length,
               TN_Len    => Tool_Name'Length,  Arg_Len => Args'Length,
               CN_Len    => CName'Length,      CV_Len  => CVersion'Length,
               Kind      => Req.Parsed,        Is_Notification => Is_Notif,
               Method    => Method,            Id => Id,
               Tool_Name => Tool_Name,         Arguments => Args,
               Client_Name    => CName,
               Client_Version => CVersion);
         end;
      end;
   end Decode;

   --------------------
   -- Parse_Envelope --
   --------------------

   function Parse_Envelope
     (Request : String) return Req.Envelope is
   begin
      --  Parsers.Create requires a length below Positive'Last; Request'Length,
      --  a Natural, can only ever equal Natural'Last, never exceed it.
      if Request'Length = Natural'Last then
         return Bad_Json;
      end if;

      declare
         P   : Parsers.Parser;
         --  The parser, destroyed on every path below.

         Doc : aliased Types.JSON_Value_Access;
         --  The parsed document, freed on every path below.
      begin
         Parsers.Create (P, Request);

         begin
            Parsers.Parse (P, Doc);
         exception
            --  Malformed JSON, or a number outside the tokenizer's range.
            when Parsers.Parse_Error =>
               Parsers.Destroy (P);
               Types.Free (Doc);  --  null on the error path (Parse leaves it so)
               return Bad_Json;
         end;

         --  Doc /= null here (Parse's postcondition).
         return Env : constant Req.Envelope := Decode (Doc) do
            Parsers.Destroy (P);
            Types.Free (Doc);
         end return;
      end;
   end Parse_Envelope;

end Memcp.Envelope;
