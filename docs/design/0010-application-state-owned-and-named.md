# 0010 — Application state: owned in an object, effects named at the seams

Status: **Implemented** in `Memcp.Resources`, `Memcp.Env` and `src/main.adb`.
Refs #20.

The server holds two long-lived resources — an open store and a loaded embedding
model — and touches two subsystems it does not own, SQLite and the process
environment. This note records where that state lives, why it is not package
state, and why every effect on it is spelled out at each seam it crosses instead
of being hidden behind one. 0005 covers how an individual native handle is owned;
this is the layer above.

## The owned resources are a data object

SPARK's leak and ownership analysis tracks reclamation through the flow of a
**data object**. Package state gets no such treatment: with no whole-program
analysis, every subprogram must conservatively assume the worst about package
state at entry. So the store and the embedder are components of one `Resources`
record, and the lifecycle becomes provable:

- `Open`'s `Pre => Is_Reclaimed (R)` licenses overwriting both owned handles with
  no pre-reclaim dance and no "statement has no effect" suppression. It is also
  what lets `Candle_Spark.Load` keep its natural `out` mode with no caller-side
  `Unload` first.
- `Close`'s `Post => Is_Reclaimed (R)` discharges the drop at end of scope, and
  `Close` is idempotent so it can sit on every exit path — including after a
  `Store_Failed` open.

A singleton could prove neither. `Open` is also the one operation in the unit
with a precondition at all: every other operation guards `Is_Open` internally
and degrades to `Db_Error` with an empty result. `Open` takes its `DB_Path`
precondition rather than an internal guard precisely because an internal guard
would give it a path on which the store is never opened.

## Ownership carried by components, not by a handle

`Memcp.Store.Store` and `Memcp.Resources.Resources` are both annotated
`Needs_Reclamation` although neither holds a raw address of its own: their
`Is_Reclaimed` is a conjunction over their owning components (for `Store`, the
`Sqlite_Vec_Spark.Database` plus the remembered path allocation). Promoting the
*partial* view to an ownership type is the whole point — that is what makes the
obligation visible to holders (`main`, the test drivers) and gets GNATprove to
check the lifecycle at every call, without any holder seeing the representation.

Neither full view carries status flags. Open, loaded and reclaimed are each read
straight off a handle, because a Boolean beside a handle can drift out of step
with it — which is the bug class the earlier singleton had.

## `main` keeps it a tracked local and reaches it up-level

`R` is a local of `Main`: opened at the top of the body, `Close`d on the single
exit. The tool seam reaches it through `Invoke_Tool`, a procedure nested inside
`Connect_To_Server` that closes over `R` and forwards to `Memcp.Tools.Invoke (R,
Id, Arguments, Result)`.

That closure is why `Memcp.Tools.Invoke` deliberately does *not* match the
generic formal it serves: the formal's profile (`Id`, `Arguments`, `Result`) has
nowhere to pass a `Resources`, and threading it through the core would give the
core a notion of application state. Tidying either end — making the signatures
match, or hoisting `R` into package state — destroys the ownership proof. The
corollary is what keeps the core reusable: neither `Spark_Mcp.Server` nor
`Spark_Mcp.Http` knows that application state exists.

## Effects stay named all the way up

Every store operation, **reads included**, carries `In_Out` on
`Sqlite_Vec_Spark.DBMS`: stepping a cursor mutates connection state, and the
binding models the SQLite subsystem across the FFI as external state. The
`Resources` object itself is only observed (an `in` parameter) — opening fixes
the handles, and running any query mutates `DBMS`, not them. The write paths
additionally carry `Ada.Text_IO.File_System`, because they may log.

Those effects propagate: through `Memcp.Tools.Invoke`, the generic `Invoke`
formal, `Spark_Mcp.Server.Dispatch` and `Spark_Mcp.Http.Serve`, each re-analysed
at memcp's instantiation. That is the visibility argument of 0007 paid off at
the application end, and it has a practical edge: adding a log line to a store
operation changes its `Global`, and every `Global` above it.

## The environment is state too

`Ada.Environment_Variables` carries no SPARK contracts, so calling it directly
leaves GNATprove assuming the call touches no global state at all (the
`assumed-global-null` warning) — an unsound assumption about a genuine
configuration read. `Memcp.Env` therefore models the environment as an
`Abstract_State` that `Exists` and `Value` take as `Input`, over a trusted
`SPARK_Mode => Off` body: the same posture the binding crates take toward C and
Rust, for the same reason.

It is **plain** state, not `External`, and the modelling is what licenses that:
memcp reads the environment as configuration once at startup, not as a channel
with asynchronous writers. `External` state left to its default properties models
a read as having an effect, which an ordinary function may not have — so keeping
it external would mean pinning those properties (as `Sqlite_Vec_Spark.DBMS` does
with `Effective_Reads => False`) purely so `Exists` and `Value` can stay
functions, which they must be for `main`'s own `Env` function to call them.

`Memcp.Log` is the counterexample that shows the asymmetry is the run-time's,
not ours: `Ada.Text_IO` *is* SPARK-annotated here, with its own
`Abstract_State => File_System`, so logging needs no trusted body — its effect
is a proved `In_Out` on that state. Two structurally similar side-effecting
wrappers in the same directory are shaped differently only because one
underlying run-time unit carries contracts and the other does not.

## Where it lives

- `src/memcp-resources.ads` — the `Resources` ownership type, `Open`'s
  `Is_Reclaimed` precondition, and the `Global`s every operation carries.
- `src/main.adb` — `R` as a tracked local; `Invoke_Tool` as the closing-over
  adapter; the instantiations of `Spark_Mcp.Server` and `Spark_Mcp.Http.Serve`.
- `src/memcp-tools.ads`, `Invoke` — the four-parameter profile the adapter feeds.
- `src/memcp-env.ads` / `.adb` — the modelled environment and its trusted body.
- `src/memcp-log.ads` — the proved counterpart, on `Ada.Text_IO.File_System`.
- `crates/sqlite_vec_spark/src/sqlite_vec_spark.ads` — `DBMS` and its external
  properties.
