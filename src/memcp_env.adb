with Ada.Environment_Variables;

--  Trusted body: Ada.Environment_Variables has no SPARK contracts, so this
--  body is out of SPARK_Mode and the Environment abstract state is the model
--  of the process environment it reads. The spec's Input => Environment
--  contract is what callers see; correctness of the two one-line forwarders is
--  by inspection.
package body Memcp_Env with SPARK_Mode => Off is

   function Exists (Name : String) return Boolean is
     (Ada.Environment_Variables.Exists (Name));

   function Value (Name : String) return String is
     (Ada.Environment_Variables.Value (Name));

end Memcp_Env;
