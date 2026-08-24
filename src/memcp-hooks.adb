--  Memcp.Hooks body: recognise a hook by its clientInfo.name and compare the
--  release it reports against the one this server shipped with.

package body Memcp.Hooks with SPARK_Mode => On is

   Hook_Prefix : constant String := "memcp-";
   --  What every memcp hook's clientInfo.name starts with
   --  ("memcp-session-start", "memcp-session-end"). Matching the prefix rather
   --  than the two names means a third hook needs no change here, and it is what
   --  keeps every other MCP client -- Claude Code's own, a bare curl -- out of
   --  the comparison, which would otherwise report each one as a stale hook.

   function Is_Hook (Client_Name : String) return Boolean is
     (Client_Name'Length >= Hook_Prefix'Length
      and then Client_Name (Client_Name'First
                            .. Client_Name'First + (Hook_Prefix'Length - 1))
               = Hook_Prefix);
   --  Whether Client_Name names one of memcp's own hooks.

   function Release (Version : String) return String
   with Post => Release'Result'Length <= Version'Length;
   --  Version up to its first '+', which is where a hook appends its digest as
   --  semver build metadata. The whole string when there is none.

   function Release (Version : String) return String is
   begin
      for I in Version'Range loop
         if Version (I) = '+' then
            return Version (Version'First .. I - 1);
         end if;
      end loop;
      return Version;
   end Release;

   ----------------
   -- Is_Current --
   ----------------

   function Is_Current (Reported_Version : String) return Boolean is
     (Release (Reported_Version) = Hook_Version);

   -----------------
   -- Client_Meta --
   -----------------

   function Client_Meta (Client_Name, Client_Version : String) return String is
   begin
      if Is_Hook (Client_Name)
        and then not Is_Current (Client_Version)
      then
         return Stale_Meta;
      end if;
      return "";
   end Client_Meta;

end Memcp.Hooks;
