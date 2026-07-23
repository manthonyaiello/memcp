--  A thin, honest wrapper over Ada.Environment_Variables.
--
--  The language-defined Ada.Environment_Variables carries no SPARK Global
--  contracts, so a direct call leaves GNATprove assuming it touches no global
--  state (the [assumed-global-null] warning). memcp reads the environment as
--  configuration input, so we model it as an Abstract_State that Exists/Value
--  depend on: the Input contract states, honestly, that these are not pure
--  functions but a read of hidden external configuration.
--
--  The state is plain rather than External on purpose. External state defaults
--  to effective reads, which this SPARK profile forbids a nonvolatile function
--  from reading -- and Exists/Value must stay functions so main's own Env
--  function can call them. Modelling the environment as configuration read once
--  at startup (rather than a volatile channel with async writers) is both
--  accurate for how memcp uses it and what keeps the wrapper a clean function
--  pair.
--
--  Like the C/Rust binding crates (Sqlite_Vec_Spark.DBMS, Spark_Mcp.Http.
--  Network), this is a SPARK-On spec stating the effect over a trusted body,
--  because the underlying facility has no SPARK contracts. Ada.Text_IO, by
--  contrast, *is* SPARK-annotated in this run-time, which is why Memcp.Log can
--  stay fully in SPARK without a trusted body -- the choices differ only
--  because the run-time contracts do.
package Memcp.Env
  with SPARK_Mode    => On,
       Abstract_State => Environment,
       Initializes    => Environment
is

   function Exists (Name : String) return Boolean
     with Global => (Input => Environment);
   --  True when environment variable Name is set.

   function Value (Name : String) return String
     with Global => (Input => Environment);
   --  The value of environment variable Name (Name must Exist).

end Memcp.Env;
