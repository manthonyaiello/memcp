# 0005 — Ownership anchored on the native handle

Status: **Implemented** in `sqlite_vec_spark` and `candle_spark`. Refs #5, #32,
#35.

Every native resource this project holds — a SQLite connection, a prepared
statement, a loaded embedding model — is owned by an Ada object annotated
`Needs_Reclamation`, and the obligation rests on the **raw C pointer itself**,
modelled as a SPARK ownership type in the binding's private part. GNATprove then
proves at every call site that a connection is `Close`d, a statement
`Finalize`d and a model `Unload`ed before it is dropped or overwritten. This
joins the same annotation on `Memcp.Json.Doc`.

## The handle pattern, and where it comes from

Each binding declares a nested `Handles` package: a private type carrying
`Needs_Reclamation`, a deferred `Reclaimed_Value` constant, `Predefined_Equality`
narrowed to `Only_Null` / `Null_Value`, and a ghost `Is_Null` whose
postcondition ties the two together.

That shape is **lifted from `SPARK.C.Strings.chars_ptr` in the shipped SPARK
library**, which models exactly this situation, an owned C pointer; the SPARK
User's Guide uses the same shape for `Text_IO.File_Descriptor`. Any further C or
Rust binding in this repo should copy it rather than invent a variant.

Three local choices go with it:

- **One handle type per C type.** `sqlite3*` and `sqlite3_stmt*` are distinct
  Ada types, so the C seam cannot hand a connection to a statement's release
  operation.
- **The handle types are not limited**, because release assigns the reclaimed
  value. Ada-level copying is blocked one level up, on the visible `limited`
  `Database` / `Statement` / `Embedder`.
- **The private part is hidden** (`pragma Annotate (GNATprove, Hide_Info,
  "Private_Part")`) rather than `SPARK_Mode (Off)`, which is what keeps the
  wrapper bodies inside SPARK instead of ejecting the whole proven binding.

## The ownership token is gone

Reclamation was originally anchored on a token — `type Ownership_Token is access
Boolean` — carried beside the raw address purely to give SPARK an Ada access to
track. It cost a heap word per handle, and it required the token's lifetime to
shadow the C resource's exactly: allocate on acquire, free on release, an
invariant no tool checked and nothing but review enforced. It also proved the
wrong thing — that the *token* was reclaimed, not that the pointer was released.

Anchoring on the pointer removes both the shadow allocation and the lockstep
invariant. What remains is a single assumption about foreign code: the
postconditions on the release imports (`Bridge.Close`, `Bridge.Finalize`,
`C_Free`) that the handle is left at the reclaimed value.

## Release convention for native handles

Every release entry point on the foreign side takes a **pointer to the caller's
pointer** — `sqlite3**`, `sqlite3_stmt**`, `*mut *mut c_void` — and nulls it.
This is why those are shims rather than direct imports of
`sqlite3_close_v2` / `sqlite3_finalize`: an `in out` handle must reach C as a
pointer-to-pointer for C to be able to null it.

The point is that the assumption above becomes **executable**. The release
wrapper's `Post` is a run-time check under `-gnata`, which the test builds use,
so the one thing the proof takes on trust is the one thing the tests verify.
Idempotence then falls out, since `close_v2`, `finalize` and
`candle_embed_free` all accept NULL.

## Acquire into the component; release unconditionally

The acquiring wrappers (`Open`, `Prepare`, `Load`) pass the record's handle
component **directly** as the foreign `out` parameter. They do not acquire into a
local and copy on success: inside SPARK that copy is a move, which leaves the
local unreadable for the rest of the wrapper.

A handle that comes back unusable is released through that same component,
**unconditionally on every failure path**. `sqlite3_open_v2` can hand back a
connection that still needs closing even when it reports failure, and SPARK
cannot know which failures leave a resource behind — so releasing always is both
honest and cheaper to prove. The release tolerates an already-null pointer, so
this costs nothing.

## Where it lives

- `crates/sqlite_vec_spark/src/sqlite_vec_spark.ads` — private part: `Handles`,
  `Database`, `Statement`, the `Is_Reclaimed` predicates.
- `crates/sqlite_vec_spark/src/sqlite_vec_spark-bridge.ads` — the release
  postconditions that are the crate's trust boundary.
- `crates/sqlite_vec_spark/csrc/shim.c` — `memcp_sqlite_close`,
  `memcp_sqlite_finalize`.
- `crates/candle_spark/src/candle_spark.ads` / `.adb` (`C_Free`) and
  `crates/candle_spark/candle_ffi/src/lib.rs` (`candle_embed_free`) — the same
  pattern for `Embedder`.
