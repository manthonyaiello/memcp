--  Memcp.Env: reads of the process environment as a function pair.
--  Ada.Environment_Variables carries no SPARK contract of its own, so
--  Environment is this package's model of the environment and the body that
--  reaches it is trusted.
package Memcp.Env
  with SPARK_Mode    => On,
       --  Plain, not External: External state defaults to effective reads,
       --  which this profile forbids a nonvolatile function from performing,
       --  and Exists/Value must stay functions.
       Abstract_State => Environment,
       Initializes    => Environment
is

   function Exists (Name : String) return Boolean
     with Global => (Input => Environment);
   --  True when environment variable Name is set.
   --  @param Name The environment variable to look up.
   --  @return True iff Name is present in the environment.

   function Value (Name : String) return String
     with Global => (Input => Environment);
   --  The value of environment variable Name (Name must Exist).
   --  @param Name The environment variable to read.
   --  @return The variable's value.

end Memcp.Env;
