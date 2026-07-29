--  Smoke driver for the tiny_http binding, and the crate's proof harness: Serve
--  is analyzed per instance, so this SPARK_Mode instantiation is what puts its
--  body and its Exceptional_Cases through `gnatprove -P http_smoke.gpr`.
--
--  Covers this crate alone: the pull loop over the Rust FFI and the
--  procedure-seam handler.

with Spark_Mcp.Http;
with Spark_Mcp.Http.Serve;

procedure Http_Smoke
  with SPARK_Mode        => On,
       Exceptional_Cases => (Spark_Mcp.Http.Transport_Error => True)
is

   procedure Echo
     (Request : String; Response : out Spark_Mcp.Http.Message_Ptr);
   --  Answer a body starting "notify" with a null Response, which Rust turns
   --  into a 204; anything else with a small JSON body echoing the length.

   procedure Echo
     (Request : String; Response : out Spark_Mcp.Http.Message_Ptr) is
   begin
      if Request'Length >= 6
        and then Request (Request'First .. Request'First + 5) = "notify"
      then
         Response := null;  --  notification
      else
         --  'Image keeps its leading space: JSON tolerates it.
         Response := new String'
           ("{""ok"":true,""bytes"":" & Request'Length'Image & "}");
      end if;
   end Echo;

   procedure Run is new Spark_Mcp.Http.Serve (On_Request => Echo);
   --  The blocking accept loop, instantiated over Echo.

begin
   Run (Port => 8787);
end Http_Smoke;
