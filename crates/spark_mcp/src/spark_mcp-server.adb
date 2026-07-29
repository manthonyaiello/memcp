--  Routing for the MCP methods (initialize, tools/list, tools/call, ping) and
--  the JSON-RPC 2.0 framing around each result. Everything is built as text,
--  escaping through Spark_Mcp.Writer.Quoted, so no JSON library is reached from
--  here.

with Ada.Strings.Fixed;

with Spark_Mcp.Writer;

package body Spark_Mcp.Server with SPARK_Mode => On is

   use Spark_Mcp.Requests;
   use type Spark_Mcp.Tools.Result_Ptr;  --  "=" against null

   -----------------------------------------------------------------------------
   --  Response framing (JSON-RPC 2.0 envelope, built as text)
   -----------------------------------------------------------------------------

   function Code_Image (Code : Error_Code) return String is
     (Ada.Strings.Fixed.Trim (Error_Code'Image (Code), Ada.Strings.Both));
   --  Code as a JSON number: 'Image without its leading space.

   function Result_Response (Id : String; Result : String) return String is
     ("{""jsonrpc"":""2.0"",""id"":" & Id & ",""result"":" & Result & "}")
   with
     --  Result gets whatever headroom the framing and the echoed id leave; the
     --  largest one, a tool payload wrapped by Tool_Call_Result, stays well
     --  within it.
     Pre => Id'Length <= Max_Field
            and then Result'Length <= Natural'Last - Max_Field - 64;
   --  A JSON-RPC result response; Id is a verbatim JSON id token.

   function Error_Response
     (Id : String; Code : Error_Code; Message : String) return String
   is
     ("{""jsonrpc"":""2.0"",""id"":" & Id
      & ",""error"":{""code"":" & Code_Image (Code)
      & ",""message"":" & Writer.Quoted (Message) & "}}")
   with
     --  The slack over Max_Field is room for Respond's "Unknown tool: " and
     --  "Method not found: " prefixes; the framed result stays in range even
     --  after 6x escaping.
     Pre => Id'Length <= Max_Field
            and then Message'Length <= Max_Field + 64;
   --  A JSON-RPC error response; Id is a verbatim JSON id token.

   -----------------------------------------------------------------------------
   --  Per-method result payloads
   -----------------------------------------------------------------------------

   function Initialize_Result return String is
     ("{""protocolVersion"":" & Writer.Quoted (MCP_Protocol_Version)
      & ",""capabilities"":{""tools"":{}}"
      & ",""serverInfo"":{""name"":" & Writer.Quoted (Server_Name)
      & ",""version"":" & Writer.Quoted (Server_Version) & "}"
      & ",""instructions"":" & Writer.Quoted (Instructions) & "}");
   --  The `result` object for `initialize`.

   function Item_Len_Bound (T : Tool_Id) return Natural is
     (43 + 6 * Name (T)'Length + 6 * Description (T)'Length
      + Input_Schema (T)'Length)
   with Ghost;
   --  Length bound on one tools/list item: 39 chars of framing, Writer.Quoted's
   --  worst case (6x + 2) on the name and description, and the schema verbatim.

   function Add_Sat (A, B : Natural) return Natural is
     (if A > Natural'Last - B then Natural'Last else A + B)
   with Ghost;
   --  Saturating sum, so the ghost accumulation cannot overflow over an
   --  arbitrarily large tool set. A real catalog never saturates.

   function Items_Len_Bound (T : Tool_Id) return Natural is
     (if T = Tool_Id'Last then Item_Len_Bound (T)
      else Add_Sat (Add_Sat (Item_Len_Bound (T), 1),
                    Items_Len_Bound (Tool_Id'Succ (T))))
   with Ghost, Subprogram_Variant => (Increases => Tool_Id'Pos (T));
   --  Length bound on the items from T to Tool_Id'Last, one comma per gap.

   function Tools_List_Result return String
   with Post =>
     Tools_List_Result'Result'Length <= 12 + Items_Len_Bound (Tool_Id'First)
   is
      --  The `result` object for `tools/list`: {name, description, inputSchema}
      --  for every tool in Tool_Id, the schema text embedded verbatim.

      function Item (T : Tool_Id) return String is
        ("{""name"":" & Writer.Quoted (Name (T))
         & ",""description"":" & Writer.Quoted (Description (T))
         & ",""inputSchema"":" & Input_Schema (T) & "}")
      with Post => Item'Result'Length <= Item_Len_Bound (T);
      --  One tool's {name, description, inputSchema} object.

      function Items_From (T : Tool_Id) return String is
        (if T = Tool_Id'Last then Item (T)
         else Item (T) & "," & Items_From (Tool_Id'Succ (T)))
      with
        Subprogram_Variant => (Increases => Tool_Id'Pos (T)),
        Post => Items_From'Result'Length <= Items_Len_Bound (T);
      --  The comma-separated items from T to Tool_Id'Last. Recursing over the
      --  finite enumeration builds the array with no mutable accumulator, so no
      --  bounded or controlled string type is needed.
   begin
      return "{""tools"":[" & Items_From (Tool_Id'First) & "]}";
   end Tools_List_Result;

   function Tool_Call_Result
     (Content : String; Is_Error : Boolean := False) return String is
     ("{""content"":[{""type"":""text"",""text"":" & Writer.Quoted (Content)
      & "}],""isError"":" & (if Is_Error then "true" else "false") & "}")
   with Pre => Content'Length <= Max_Field;
   --  The `result` object for a tools/call, carrying Content as a single MCP
   --  text-content block.

   -------------
   -- Respond --
   -------------

   procedure Respond
     (Method          : String;
      Is_Notification : Boolean;
      Id              : String;
      Response        : out Response_Ptr;
      Tool_Name       : String := "";
      Arguments       : String := "{}") is
   begin
      --  A notification is owed no response, whatever its method.
      if Is_Notification then
         Response := null;
         return;
      end if;

      if Method = "initialize" then
         Response := new String'(Result_Response (Id, Initialize_Result));

      elsif Method = "ping" then
         Response := new String'(Result_Response (Id, "{}"));

      elsif Method = "tools/list" then
         Response := new String'(Result_Response (Id, Tools_List_Result));

      elsif Method = "tools/call" then
         declare
            Found : Boolean := False;
            Which : Tool_Id := Tool_Id'First;
         begin
            for T in Tool_Id loop
               if Name (T) = Tool_Name then
                  Found := True;
                  Which := T;
                  exit;
               end if;
            end loop;

            if not Found then
               Response := new String'
                 (Error_Response (Id, Invalid_Params, "Unknown tool: " & Tool_Name));
               return;
            end if;

            declare
               R : Tools.Result_Ptr;
            begin
               Invoke (Which, Arguments, R);
               if R = null then
                  --  A conforming Invoke never returns null; report an internal
                  --  error rather than dereference.
                  Response := new String'
                    (Error_Response
                       (Id, Internal_Error, "tool produced no result"));
               elsif R.Ok then
                  Response := new String'
                    (Result_Response (Id, Tool_Call_Result (R.Content)));
               else
                  --  Per MCP a tool-execution failure reaches the model as an
                  --  isError result, not a JSON-RPC error -- those are for the
                  --  protocol faults caught before Invoke. The message becomes
                  --  the content text; R.Code is unused here.
                  Response := new String'
                    (Result_Response
                       (Id, Tool_Call_Result (R.Message, Is_Error => True)));
               end if;
               Tools.Free (R);  --  unconditional: Free (null) is a no-op
            end;
         end;

      else
         Response := new String'
           (Error_Response (Id, Method_Not_Found, "Method not found: " & Method));
      end if;
   end Respond;

   --------------
   -- Dispatch --
   --------------

   procedure Dispatch (Request : String; Response : out Response_Ptr) is
      Env : constant Envelope := Parse_Envelope (Request);
      --  The decoded request; a non-Parsed Kind is framed as an error below.
   begin
      case Env.Kind is
         when Parsed =>
            Respond
              (Method          => Env.Method,
               Is_Notification => Env.Is_Notification,
               Id              => Env.Id,
               Response        => Response,
               Tool_Name       => Env.Tool_Name,
               Arguments       => Env.Arguments);
         --  The id is undetermined on every error Kind, which JSON-RPC frames
         --  as a null id.
         when Bad_Json =>
            Response := new String'
              (Error_Response ("null", Parse_Error, "Parse error"));
         when Bad_Request =>
            Response := new String'
              (Error_Response ("null", Invalid_Request, "Invalid Request"));
         when Unimplemented =>
            Response := new String'
              (Error_Response
                 ("null", Internal_Error,
                  "request envelope parsing not yet wired (pending json crate)"));
      end case;
   end Dispatch;

end Spark_Mcp.Server;
