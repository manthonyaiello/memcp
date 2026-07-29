# 0008 — The one uninitialized allocation

Status: **Implemented** in `Spark_Mcp.Http.Bridge`.

`Read_Body` allocates a `String` of exactly `Body_Length` and hands it straight
to Rust's `mcp_body_read`, which fills every byte. SPARK forbids uninitialized
allocators, so that allocation costs the crate its single `SPARK_Mode => Off`
body: `Alloc_Uninit`, one statement. The alternative is blank-filling a buffer
that is overwritten in full on the next line — every request body written
twice, on the hot path.

## Why the `Global` cannot be spelled any other way

`Global => null` on `Alloc_Uninit` is a **trusted claim**, not a derived fact:
the fresh allocation is wholly owned by `Data`, so the call has no effect a
caller could observe. It is also the only spelling available. Without it,
GNATprove derives a heap-memory effect from the `Off` body — an effect no
explicit `Global` further up the call chain has a name for, so the honest
alternative is unwritable rather than merely verbose.

Soundness rests on scope, not on the aspect. `Read_Body` passes the allocation
to `C_Body_Read` on the very next statement, so no SPARK code can observe an
uninitialized character. Widening `Alloc_Uninit`'s use beyond that adjacency
invalidates the whole arrangement.

## `Relaxed_Initialization` does not replace it — yet

The SPARK-native alternative is `Relaxed_Initialization` on the buffer type.
Evaluated under gnatprove 15.1, it did not work, in two independent ways:

- GNATprove rejects uninitialized allocators of relaxed types (**E0019**),
  which is precisely the thing the escape hatch exists to do;
- cross-unit use of an access-to-`Relaxed_Initialization` type ICEs gnat2why
  ("GNAT BUG DETECTED") even with *initialized* allocators.

It has not been re-probed since the move to FSF GNAT 16.1 / gnatprove 16. Those
two behaviours are what to re-probe; if both are fixed, `Alloc_Uninit`, its
trusted `Global`, and this note all go away together.

## Where it lives

- `crates/spark_mcp/src/spark_mcp-http-bridge.adb` — `Alloc_Uninit` and its
  sole caller `Read_Body`.
- `crates/spark_mcp/rust/src/lib.rs` — `mcp_body_read`, the fill that makes the
  adjacency argument true.
