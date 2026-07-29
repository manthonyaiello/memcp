with Ada.Environment_Variables;

--  Memcp.Env body: two forwarders to Ada.Environment_Variables. Out of
--  SPARK_Mode because that unit carries no contracts, so the spec's
--  Input => Environment is trusted here and correct by inspection.
package body Memcp.Env with SPARK_Mode => Off is

   function Exists (Name : String) return Boolean is
     (Ada.Environment_Variables.Exists (Name));

   function Value (Name : String) return String is
     (Ada.Environment_Variables.Value (Name));

end Memcp.Env;
