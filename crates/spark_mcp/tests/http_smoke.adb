--  Standalone smoke driver for the tiny_http binding, and the crate's PROOF
--  HARNESS: gnatprove analyzes generics per instance, so this SPARK_Mode=>On
--  instantiation is what makes Serve's body (and its Exceptional_Cases)
--  actually get proved. Run: gnatprove -P http_smoke.gpr
--
--  Exercises exactly this crate (no json/sqlite/candle): the pull loop over
--  the Rust FFI and the procedure-seam handler.
--
--    * body starting "notify" -> Last < Response'First -> Rust answers 204
--    * anything else          -> 200 with a small JSON body echoing the length

with Spark_Mcp.Http;
with Spark_Mcp.Http.Serve;

procedure Http_Smoke
  with SPARK_Mode        => On,
       Exceptional_Cases => (Spark_Mcp.Http.Transport_Error => True)
is

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

begin
   Run (Port => 8787);
end Http_Smoke;
