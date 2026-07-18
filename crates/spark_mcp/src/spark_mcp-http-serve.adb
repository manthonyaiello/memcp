--  Proven body: pull each request over the Bridge, call On_Request directly
--  (an ordinary SPARK call -- its effects are analyzed per instantiation),
--  push the response back. Both buffers are exactly-sized ownership
--  allocations -- Read_Body's is freed once the handler has consumed it, the
--  handler's once it has been sent -- and gnatprove discharges every
--  leak/use-after-free obligation, including on the raise paths.

with Spark_Mcp.Http.Bridge;

procedure Spark_Mcp.Http.Serve (Port : Port_Number)
  with SPARK_Mode => On
is
   Server : Bridge.Server_Handle;
begin
   Bridge.Open (Port, Server);
   if not Bridge.Is_Open (Server) then
      raise Transport_Error with "could not bind 127.0.0.1:" & Port'Image;
   end if;

   loop
      declare
         Req      : Bridge.Request_Handle;
         Request  : Message_Ptr;
         Response : Message_Ptr;
      begin
         Bridge.Next (Server, Req);
         if not Bridge.Is_Live (Req) then
            raise Transport_Error with "accept loop terminated";
         end if;

         Bridge.Read_Body (Req, Request);
         On_Request (Request.all, Response);
         Free (Request);

         if Response = null then
            Bridge.Respond (Req, "");
         else
            Bridge.Respond (Req, Response.all);
            Free (Response);
         end if;
         pragma Assert (not Bridge.Is_Live (Req));
      end;
   end loop;
end Spark_Mcp.Http.Serve;
