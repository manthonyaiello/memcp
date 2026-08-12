--  What the server knows about the hooks it shipped with, and the one thing it
--  says back to a hook that reports a different version.
--
--  The hooks and this unit ship from one repository, so a surface is current iff
--  the two version strings are equal; nothing here orders releases. Only the
--  release part is compared -- the digest a hook appends as build metadata is
--  its own claim about its own files, checked on the surface against what its
--  installer recorded, and means nothing here.

package Memcp.Hooks with SPARK_Mode => On is

   Hook_Version : constant String := "0.4.0";
   --  The hook release this server shipped with. Must equal
   --  MEMCP_HOOK_VERSION in scripts/hooks/hook_common.sh, which
   --  scripts/check-hook-version.sh gates.

   Stale_Meta : constant String :=
     "{""memcp/hookStatus"":{""stale"":true,""expected"":"""
     & Hook_Version & """}}";
   --  The `_meta` object a stale hook is answered with. Its presence is the
   --  whole signal: a current hook, a client that is not a hook, and a server
   --  too old to know about any of this all answer without it, so the hook
   --  treats absence as "nothing to report" rather than as "current".

   function Client_Meta (Client_Name, Client_Version : String) return String
   with Post => Client_Meta'Result'Length <= Stale_Meta'Length;
   --  Stale_Meta when Client_Name names a memcp hook whose reported release
   --  differs from Hook_Version, otherwise "". Shaped to be the Client_Meta
   --  actual of a Spark_Mcp.Server instantiation.
   --  @param Client_Name params.clientInfo.name as the client reported it.
   --  @param Client_Version params.clientInfo.version as the client reported
   --    it, release and optional `+digest` build metadata.
   --  @return Stale_Meta, or "" when there is nothing to report.

end Memcp.Hooks;
