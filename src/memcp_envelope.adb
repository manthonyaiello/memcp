with JSON.Types;
with JSON.Parsers;
with JSON.Streams;

package body Memcp_Envelope with SPARK_Mode => On is

   --  Ownership-reclamation discards (see Memcp_Json for the rationale): Free /
   --  Destroy null their argument as they reclaim it, and a Parse whose tree is
   --  discarded keeps only its Status. The reclaimed handles are not read after.
   pragma Warnings
     (GNATprove, Off, "statement has no effect",
      Reason => "reclaiming owned memory has no SPARK-modelled effect");
   pragma Warnings
     (GNATprove, Off, "*is set by ""Free"" but not used after the call",
      Reason => "Free nulls its argument as it reclaims it; not read after");
   pragma Warnings
     (GNATprove, Off, "*is set by ""Destroy"" but not used after the call",
      Reason => "Destroy nulls the parser/buffer as it reclaims it; unread");
   pragma Warnings
     (GNATprove, Off, "*is set by ""Parse"" but not used after the call",
      Reason => "the parser is destroyed after Parse; its post-state is unread");

   package Req renames Spark_Mcp.Requests;

   Max_Field : constant := Spark_Mcp.Max_Field;

   --  A JSON value model wide enough for request ids and arbitrary tool
   --  arguments. The numeric types only bound what the tokenizer accepts; the
   --  envelope reads strings and re-serialises subtrees, so their exact range
   --  is immaterial.
   package Types is new JSON.Types
     (Integer_Type => Long_Long_Integer, Float_Type => Long_Float);

   --  Tool arguments can nest; allow generous depth so a valid request is never
   --  rejected as a parse error for nesting depth alone.
   package Parsers is new JSON.Parsers
     (Types => Types, Default_Maximum_Depth => 512);

   use type Types.Value_Kind;
   use type Types.JSON_Value_Access;

   --  The all-error envelope: every length zero, so Dispatch frames the error
   --  from Kind alone. Trivially within the Max_Field predicate. (SPARK forbids
   --  the box notation "others => <>", so every field is written explicitly.)
   Bad_Json : constant Req.Envelope :=
     (M_Len   => 0, Id_Len  => 0, TN_Len => 0, Arg_Len => 0,
      Kind    => Req.Bad_Json, Is_Notification => False,
      Method  => "", Id => "", Tool_Name => "", Arguments => "");
   Bad_Req  : constant Req.Envelope :=
     (M_Len   => 0, Id_Len  => 0, TN_Len => 0, Arg_Len => 0,
      Kind    => Req.Bad_Request, Is_Notification => False,
      Method  => "", Id => "", Tool_Name => "", Arguments => "");

   ------------------
   -- To_Json_Text --
   ------------------

   --  Re-serialise a parsed value to its JSON text. Used for the "id" (echoed
   --  verbatim) and for params.arguments (crosses the seam as raw JSON text).
   --  A pathological value whose text would overflow the buffer (> Positive'Last
   --  -- impossible for a transport-capped request) degrades to "".
   function To_Json_Text
     (Value : not null access constant Types.JSON_Value) return String
   is
      --  JSON.Streams.Destroy reclaims Buf on both the normal and overflow
      --  paths; json now annotates String_Buffer ownership (Post => not
      --  Has_Storage) + Always_Terminates, so leak-freedom proves cleanly.
      Buf : JSON.Streams.String_Buffer;
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

   --  The member Key of Obj, or null when Obj is null / not an object / has no
   --  such member. The observer is rooted at the access parameter Obj (json's
   --  idiom) and returned in statement form -- a conditional *expression*
   --  observe would violate SPARK RM 3.10(4). This lets Decode fetch nested
   --  members unconditionally and move every branch to the value level.
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

   --  Validate and extract fields from an already-parsed document. Assumes
   --  Doc /= null (Parsers.Parse guarantees it). The Envelope is indefinite
   --  (its String components are sized by discriminants), so it is built in one
   --  aggregate at each exit. Any field that would exceed Max_Field (never, for
   --  a transport-capped request) degrades the whole request to Bad_Request.
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

            --  A request without "id" is a notification; otherwise capture the
            --  id as its verbatim JSON token so Dispatch can echo it.
            IV       : constant access constant Types.JSON_Value :=
              Types.Get (Doc, "id");
            Is_Notif : constant Boolean := (IV = null);
            Id       : constant String :=
              (if Is_Notif then "" else To_Json_Text (IV));

            --  tools/call carries params.name (string) and params.arguments
            --  (raw JSON text). The observers are fetched unconditionally
            --  (Obj_Member is null-safe); the Is_Call gate lives on the values,
            --  so no observe is wrapped in a conditional expression.
            Is_Call   : constant Boolean := (Method = "tools/call");
            PV        : constant access constant Types.JSON_Value :=
              Obj_Member (Doc, "params");
            NV        : constant access constant Types.JSON_Value :=
              Obj_Member (PV, "name");
            AV        : constant access constant Types.JSON_Value :=
              Obj_Member (PV, "arguments");

            Tool_Name : constant String :=
              (if Is_Call and then NV /= null
                 and then Types.Kind (NV) = Types.String_Kind
               then Types.Value (NV) else "");
            Args      : constant String :=
              (if Is_Call and then AV /= null then To_Json_Text (AV) else "{}");
         begin
            if Method'Length > Max_Field or else Id'Length > Max_Field
              or else Tool_Name'Length > Max_Field
              or else Args'Length > Max_Field
            then
               return Bad_Req;
            end if;

            return
              (M_Len     => Method'Length,     Id_Len  => Id'Length,
               TN_Len    => Tool_Name'Length,  Arg_Len => Args'Length,
               Kind      => Req.Parsed,        Is_Notification => Is_Notif,
               Method    => Method,            Id => Id,
               Tool_Name => Tool_Name,         Arguments => Args);
         end;
      end;
   end Decode;

   --------------------
   -- Parse_Envelope --
   --------------------

   function Parse_Envelope
     (Request : String) return Req.Envelope is
   begin
      --  Parsers.Create requires a length below Positive'Last (Request'Length,
      --  a Natural, can only ever equal it, never exceed it).
      if Request'Length = Natural'Last then
         return Bad_Json;
      end if;

      declare
         --  P and Doc are released on every path (Destroy/Free below). json now
         --  annotates Parser ownership + Always_Terminates on Parse/Destroy/Free,
         --  so both leak-freedom and termination discharge -- no justification.
         P   : Parsers.Parser;
         Doc : aliased Types.JSON_Value_Access;
      begin
         Parsers.Create (P, Request);

         begin
            Parsers.Parse (P, Doc);
         exception
            --  Parse_Error (malformed JSON or a number out of range) maps to
            --  JSON-RPC Parse_Error at the envelope.
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

end Memcp_Envelope;
