# 0009 — The store's schema, its query shapes, and what the proof rests on

Status: **Implemented** in `Memcp.Store`.

One SQLite file holds everything: six ordinary tables and two `vec0` virtual
tables. The relational half is unremarkable. What has to be re-derived otherwise
is why the vector half is joined the way it is, why a semantic search is two
queries plus an Ada filter rather than one statement, and why every record type
this package hands back has the shape it does.

## Two `vec0` tables, joined by nothing

`summary_vec` and `chunk_vec` each hold a single column, `embedding
float[384]`, and are keyed by the rowid of the `summaries` / `chunks` row they
belong to. There is no join column and no duplicated metadata — which means
every write path must keep the two sides in step by hand:

- an insert into `summaries` is followed by an insert into `summary_vec (rowid,
  embedding)`, and a session-scoped replace does `DELETE` then `INSERT` on the
  vec row while preserving the summary's id;
- a delete must remove the vec row explicitly. No foreign key reaches a virtual
  table, so `Forget_Summary` deletes from `summary_vec` itself even though the
  diary line goes by `ON DELETE CASCADE`.

The dimension 384 appears in three places: `Embedding_Dim`,
`Candle_Spark.Dimension`, and the `float[384]` literal inside the DDL string.
A `pragma Compile_Time_Error` ties the first two together. The DDL literal is
checked by nothing — changing the dimension means editing it by hand, and the
symptom of forgetting is a runtime `vec0` bind failure, not a compile error.

## Search is KNN first, filter second, in Ada

`vec0` applies its `LIMIT` *before* any metadata predicate, so folding the
project / session / date filters into the candidate query would silently drop
hits. Both searches therefore run:

1. `SELECT rowid, distance FROM <x>_vec WHERE embedding MATCH ? ORDER BY
   distance LIMIT ?`, with the limit **over-fetched 5x when any filter is
   present** and the plain clamped limit otherwise;
2. one prepared metadata fetch, `Reset` and rebound per candidate rather than
   re-prepared;
3. the filters evaluated in Ada — `Contains` over the name list, and the
   `[Since, Until]` window as a lexical comparison on `created_at`.

The consequence is that recall is bounded by that factor: a query whose filters
exclude more than four fifths of the nearest `Limit * 5` returns short. The fix
is the factor, or a filtered `vec0` query, never removing the clamp — the clamp
is what bounds the candidate scan (see 0011 on `Max_Search_Limit`).

The lexical date comparison is the reason `created_at` is text in a fixed,
sortable shape rather than a SQLite time value; 0012 records why that shape is
frozen.

## The meta row is asserted, never migrated

`Open` applies the whole schema — every statement is `IF NOT EXISTS`, so
re-applying is a no-op — then asserts the `meta` row's `Schema_Version` and
`Embedding_Model`. A disagreement is `Meta_Mismatch`: the open is refused, nothing
is rewritten. A database written against different weights is a configuration
error, not a migration to attempt.

## Return shapes: one rule per column class

Every record and out-parameter in the spec follows from four choices:

- **List-valued queries return SPARKlib `Unbounded_Vector`s of an indefinite
  record** whose `Len` discriminants size its `String` fields, taken directly as
  the formal vector's `Element_Type (<>)`: no ownership list, no JSON in the
  store.
- **Exactly one read returns an owning pointer.** `Fetch_Summary` hands back
  `Summary_Ptr` (null = no such row) because a value-returning SPARK function
  may not have the side effect of stepping a cursor; every other read is a
  procedure with an `out` vector.
- **Nullable columns are a `Has_*` Boolean plus a zero-length string**, with
  `Sqlite_Vec_Spark.Column_Is_Null` as the discriminator, so SQL `NULL` and
  `''` stay distinguishable through the whole stack.
- **Indefiniteness stops at string lengths.** No element type may have an
  indefinite component, which is why the hit records flatten their base record's
  fields instead of nesting it and why `Chunk_Input` carries a definite
  `Candle_Spark.Embedding` directly — bundling body with vector, so a
  chunks/embeddings length mismatch is structurally impossible.

## What the body's proof leans on

- **Every vector scan is `for I in First_Index (V) .. Last_Index (V)`**
  (`Insert_Chunks`, `Contains`, the project binder, and the serializers in
  `Memcp.Tools`). It makes `Element`'s index precondition trivial and needs no
  index arithmetic. Rewriting one with cursors or offsets reintroduces
  precondition checks that then have to be re-proved.
- **`To_Blob` is instantiated on a local subtype.** GNATprove confirms an
  unchecked conversion size-exact and suitable only when the source type's
  representation is anchored in the unit being analysed: the identical instance
  taken directly on the `with`ed `Candle_Spark.Embedding` is reported "size not
  confirmed / unsuitable source", and this holds regardless of `-u` / `-U`
  analysis scope. `subtype Store_Embedding` exists only to be that anchor.
  It is a workaround, not an idiom — the source carries a `TODO(embed-blob)`.
- **Three non-SPARK islands, each one small helper.** `Dedup_Hash`
  (`GNAT.SHA256`), `Now_Iso` (`Ada.Calendar`) and `Write_Session_File`
  (`Stream_IO` + `Ada.Directories`) are `SPARK_Mode => Off` bodies under
  SPARK-mode declarations carrying `Global => null` as the boundary claim —
  the same quarantine the binding crates apply to their FFI bodies. Anything
  else that cannot be proved belongs here, in that form. `Write_Session_File`
  earns its place twice over: the path it builds is an unbounded concatenation,
  and assembling it inside the `Off` helper keeps that obligation out of the
  proved caller.

## Where it lives

- `src/memcp-store.ads` — the record types, the two caps, the `Store` ownership
  type and the operation contracts.
- `src/memcp-store.adb`, `Schema_SQL` / `Vec_Summary_SQL` / `Vec_Chunk_SQL` —
  the DDL, including the unchecked `float[384]`.
- `src/memcp-store.adb`, `Search_Summaries` / `Search_Chunks` — the KNN +
  over-fetch + Ada-filter shape.
- `src/memcp-store.adb`, `Store_Embedding` / `To_Blob` — the unchecked-conversion
  anchor; `Dedup_Hash`, `Now_Iso`, `Write_Session_File` — the three `Off`
  helpers.
- `crates/sqlite_vec_spark/src/sqlite_vec_spark.ads` — `Column_Is_Null` and the
  primitives every query above is built from.
