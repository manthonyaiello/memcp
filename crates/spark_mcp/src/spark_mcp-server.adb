--  JSON-RPC 2.0 + MCP routing and response construction.
--
--  This body is entirely json-free: responses are built as text (via
--  Spark_Mcp.Writer.Quoted for escaping). Turning the request text into
--  {method, id, tool name, arguments} is the one step that needs a JSON parser,
--  and it is NOT done here -- it is the Parse_Envelope generic formal, supplied
--  by the application. Dispatch below simply calls that formal and maps its
--  Envelope result (see Spark_Mcp.Requests) onto Respond or an error response.

with Ada.Strings.Fixed;

with Spark_Mcp.Writer;

package body Spark_Mcp.Server with SPARK_Mode => On is

   use Spark_Mcp.Requests;
   use type Spark_Mcp.Tools.Result_Ptr;  --  "=" against null in Respond

   -----------------------------------------------------------------------------
   --  Response framing (JSON-RPC 2.0 envelope, built as text)
   -----------------------------------------------------------------------------

   --  Error_Code'Image without Ada's leading space on non-negative values.
   function Code_Image (Code : Error_Code) return String is
     (Ada.Strings.Fixed.Trim (Error_Code'Image (Code), Ada.Strings.Both));

   --  A JSON-RPC result response. Id is a verbatim JSON id token. Id is
   --  bounded by Max_Field and Result by the complementary headroom (a tool
   --  payload wrapped by Tool_Call_Result -- the largest Result -- stays well
   --  within it), so the concatenation cannot overflow a String index.
   function Result_Response (Id : String; Result : String) return String is
     ("{""jsonrpc"":""2.0"",""id"":" & Id & ",""result"":" & Result & "}")
   with
     Pre => Id'Length <= Max_Field
            and then Result'Length <= Natural'Last - Max_Field - 64;

   --  A JSON-RPC error response. Message is allowed a little slack over
   --  Max_Field so Respond can prefix "Unknown tool: " / "Method not found: ";
   --  even after 6x escaping via Quoted the framed result stays in range.
   function Error_Response
     (Id : String; Code : Error_Code; Message : String) return String
   is
     ("{""jsonrpc"":""2.0"",""id"":" & Id
      & ",""error"":{""code"":" & Code_Image (Code)
      & ",""message"":" & Writer.Quoted (Message) & "}}")
   with
     Pre => Id'Length <= Max_Field
            and then Message'Length <= Max_Field + 64;

   -----------------------------------------------------------------------------
   --  Per-method result payloads
   -----------------------------------------------------------------------------

   --  The `result` object for `initialize`.
   function Initialize_Result return String is
     ("{""protocolVersion"":" & Writer.Quoted (MCP_Protocol_Version)
      & ",""capabilities"":{""tools"":{}}"
      & ",""serverInfo"":{""name"":" & Writer.Quoted (Server_Name)
      & ",""version"":" & Writer.Quoted (Server_Version) & "}"
      & ",""instructions"":" & Writer.Quoted (Instructions) & "}");

   --  Ghost length bounds for the tools/list catalog (used by Tools_List_Result
   --  and its recursive builder below). Item_Len_Bound bounds one item: the
   --  fixed framing (39 chars) plus Writer.Quoted's worst case (6x + 2) on the
   --  name and description, plus the schema embedded verbatim. Items_Len_Bound
   --  sums that over the tools from T to Tool_Id'Last, one comma per gap.
   function Item_Len_Bound (T : Tool_Id) return Natural is
     (43 + 6 * Name (T)'Length + 6 * Description (T)'Length
      + Input_Schema (T)'Length)
   with Ghost;

   --  Saturating sum, so the ghost accumulation cannot overflow as it runs over
   --  an arbitrarily large tool set. For any real catalog (well within
   --  Max_Field) it never saturates, so the concrete length bound below is
   --  identical to a plain sum -- only the unprovable overflow on the recursive
   --  '+' is removed.
   function Add_Sat (A, B : Natural) return Natural is
     (if A > Natural'Last - B then Natural'Last else A + B)
   with Ghost;

   function Items_Len_Bound (T : Tool_Id) return Natural is
     (if T = Tool_Id'Last then Item_Len_Bound (T)
      else Add_Sat (Add_Sat (Item_Len_Bound (T), 1),
                    Items_Len_Bound (Tool_Id'Succ (T))))
   with Ghost, Subprogram_Variant => (Increases => Tool_Id'Pos (T));

   --  The `result` object for `tools/list`: iterate the whole Tool_Id type,
   --  emitting {name, description, inputSchema} for each. inputSchema is the
   --  application's JSON Schema text, embedded verbatim.
   --
   --  The catalog grows with the tool set, so its length is proved in range by
   --  a pair of ghost bounds carried on the recursive builder: Item_Len_Bound
   --  bounds a single item (via Writer.Quoted's 6x escaping Post), and
   --  Items_Len_Bound sums those over the remaining tools. These have no
   --  hard-coded per-item cap, so the proof holds for any tool set whose whole
   --  catalog fits within Result_Response's precondition -- which GNATprove
   --  checks concretely at each instantiation (see spark_mcp_prove.gpr).
   function Tools_List_Result return String
   with Post =>
     Tools_List_Result'Result'Length <= 12 + Items_Len_Bound (Tool_Id'First)
   is
      --  One tool's {name, description, inputSchema} object.
      function Item (T : Tool_Id) return String is
        ("{""name"":" & Writer.Quoted (Name (T))
         & ",""description"":" & Writer.Quoted (Description (T))
         & ",""inputSchema"":" & Input_Schema (T) & "}")
      with Post => Item'Result'Length <= Item_Len_Bound (T);

      --  The comma-separated items from T to Tool_Id'Last. Recursion over the
      --  (finite) enumeration builds the array cap-free, without a mutable
      --  accumulator -- so the body needs no controlled/bounded string type.
      --  The variant proves termination: Tool_Id'Pos (T) strictly increases
      --  toward Tool_Id'Last, where the recursion stops. The Post bounds the
      --  accumulated length inductively via the ghost Items_Len_Bound.
      function Items_From (T : Tool_Id) return String is
        (if T = Tool_Id'Last then Item (T)
         else Item (T) & "," & Items_From (Tool_Id'Succ (T)))
      with
        Subprogram_Variant => (Increases => Tool_Id'Pos (T)),
        Post => Items_From'Result'Length <= Items_Len_Bound (T);
   begin
      return "{""tools"":[" & Items_From (Tool_Id'First) & "]}";
   end Tools_List_Result;

   --  The `result` object for a successful tools/call. The tool's payload text
   --  is carried as a single MCP text-content block (the JSON is serialized
   --  into the `text` string, matching how a structured return is surfaced).
   function Tool_Call_Result
     (Content : String; Is_Error : Boolean := False) return String is
     ("{""content"":[{""type"":""text"",""text"":" & Writer.Quoted (Content)
      & "}],""isError"":" & (if Is_Error then "true" else "false") & "}")
   with Pre => Content'Length <= Max_Field;

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
                  --  A conforming Invoke never returns null; treat it as an
                  --  internal error rather than dereferencing.
                  Response := new String'
                    (Error_Response
                       (Id, Internal_Error, "tool produced no result"));
               elsif R.Ok then
                  Response := new String'
                    (Result_Response (Id, Tool_Call_Result (R.Content)));
               else
                  --  A tool ran but failed. Per MCP a tool-execution failure is
                  --  surfaced to the model as an isError result -- NOT a
                  --  JSON-RPC error, which is reserved for protocol faults
                  --  handled before Invoke (unknown tool, bad envelope). The
                  --  message becomes the content text; R.Code is unused here.
                  Response := new String'
                    (Result_Response
                       (Id, Tool_Call_Result (R.Message, Is_Error => True)));
               end if;
               Tools.Free (R);  --  owns R on every path (Free (null) is a no-op)
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

   --  Decode the request via the application-supplied Parse_Envelope formal
   --  (see Spark_Mcp.Requests), then route it. Every error Kind is framed here,
   --  with the "id" unknown, so the response echoes a null id per JSON-RPC.
   procedure Dispatch (Request : String; Response : out Response_Ptr) is
      Env : constant Envelope := Parse_Envelope (Request);
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
