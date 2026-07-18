# 0005 — Applying SPARK `Needs_Reclamation` to the resource-owning handles

Status: **Scoping / design** (not implemented). Refs #5.

## Problem statement

SPARK offers an ownership annotation, `Needs_Reclamation`, for private types
whose values own a resource that must be explicitly released. GNATprove then
emits a *resource-leak* check wherever such an object goes out of scope or is
overwritten, forcing every path to release it first — the same discipline it
already enforces for named access types, extended to resources that are *not*
Ada pointers (file descriptors, C handles, and the like).

Issue #5 asks whether this applies to "the SQL binding" (and elsewhere) and is
worth doing. This document inventories the candidate types, states precisely
what the annotation requires, reports the result of a throwaway spike that
applied it to `Sqlite_Vec_Spark`, and gives a recommendation.

The short version: **the annotation is already in production use in this repo**
(`Memcp_Json.Doc`), so the mechanics are understood. Extending it to the C-handle
types (`Database`, `Statement`, `Embedder`) is *mechanically possible but not
free*: because those handles are represented as a bare `System.Address`, the
only valid way to annotate them forces their whole wrapper body out of
`SPARK_Mode`, trading the crate's "proven wrappers" property for machine-checked
release at every call site. That trade is defensible but is a genuine trade, not
a pure win — see the recommendation.

## What `Needs_Reclamation` requires

Learned from the SPARK reference, the in-repo precedent (`src/memcp_json.ads`),
and an empirical spike (below). To annotate a private type `T`:

1. **Mark the type.** On the type declaration:
   `with Annotate => (GNATprove, Ownership, "Needs_Reclamation")`.

2. **Supply a reclamation predicate.** A `Ghost` function of one parameter of
   type `T` returning `Boolean`, annotated with either
   `(GNATprove, Ownership, "Is_Reclaimed")` (True when the object holds no
   resource) or `(GNATprove, Ownership, "Needs_Reclamation")` (the dual). Its
   first parameter's type must itself carry the ownership annotation.

3. **Constrain the private part.** The private part of the enclosing package
   must be either `pragma SPARK_Mode (Off)` **or** carry
   `pragma Annotate (GNATprove, Hide_Info, "Private_Part")`. This is a hard rule
   — the spike failed to compile until one was present.

4. **If you choose `Hide_Info`, the full view must itself be "subject to
   ownership"** — i.e. it must contain an access (or another reclamation) type.
   A full view that is a bare `System.Address` is **rejected** with
   *"full view of type annotated with an Ownership annotation shall be subject to
   ownership."* This is the decisive constraint for the C-handle types (see
   below).

Once annotated, GNATprove:

- emits a **resource-leak check** at every scope exit / overwrite of a `T`
  object, discharged only when the reclamation predicate holds there;
- treats `T` as an owning type for move/aliasing (moot for `limited` types,
  which already forbid copy);
- expects the releasing operation's `Post` to establish the reclaimed state
  (e.g. `Close`'s `Post => not Is_Open (DB)`), which lets the leak check
  discharge.

### The working precedent already in the tree

`Memcp_Json.Doc` (`src/memcp_json.ads:23-33`, `:131`, `:146-147`) is the
canonical example, proved to Silver today:

```ada
type Doc is limited private
  with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
       Default_Initial_Condition => Is_Closed (Doc);

function Is_Closed (D : Doc) return Boolean
  with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
...
private
   pragma Annotate (GNATprove, Hide_Info, "Private_Part");
   ...
   function Is_Closed (D : Doc) return Boolean is (D.Impl = null);
```

Crucially, `Doc`'s full view is a record containing `Impl : Impl_Access` — an
**access type** — so it satisfies rule 4 and can use the `Hide_Info` route while
keeping its body in SPARK. Every tool `Close`s its `Doc` on every path
(`src/memcp_tools.adb`), and GNATprove enforces it. This is exactly the payoff
#5 is after — but it works *because the resource is an Ada pointer*.

## Candidate inventory

| # | Type | File:line | Full view | Owning today? | `Needs_Reclamation` verdict |
|---|------|-----------|-----------|----------------|------------------------------|
| 1 | `Sqlite_Vec_Spark.Statement` | `crates/sqlite_vec_spark/src/sqlite_vec_spark.ads:109` (view `:343-344`) | `System.Address` | No | **Strong candidate** — highest leak risk; blocked by rule 4 (see below) |
| 2 | `Sqlite_Vec_Spark.Database` | `.../sqlite_vec_spark.ads:103-104` (view `:334-335`) | `System.Address` | No | **Candidate** — same mechanism as Statement; must move together |
| 3 | `Candle_Spark.Embedder` | `crates/candle_spark/src/candle_spark.ads:63` (view `:112-117`) | `System.Address` + `Loaded` | No, and copyable | Weak — single global, low leak risk |
| 4 | `Memcp_Store.Store` | `src/memcp_store.ads:54` (view `:651-653`) | record w/ `Database` + `Path_Access` | **Yes** (via `Path_Access`) | Already leak-checked; would inherit #2 automatically |
| 5 | `Memcp_Json.Doc` | `src/memcp_json.ads:23` | record w/ `Impl_Access` | **Yes — already annotated** | Done; the precedent |
| 6 | `Sqlite_Vec_Spark.Text_Ptr` | `.../sqlite_vec_spark.ads:122-129` | `access String` | Yes (named access) | N/A — already fully leak-checked |
| 7 | `Spark_Mcp.Http.Message_Ptr` | `crates/spark_mcp/src/spark_mcp-http.ads:42-50` | `access String` | Yes (named access) | N/A — already leak-checked |
| 8 | `Memcp_Store.Summary_Ptr`, `Memcp_Extractor.Transcript_Ptr`, `Memcp_Store.Path_Access` | `src/memcp_store.ads:155`, `:644`; `src/memcp_extractor.ads:37` | `access …` | Yes (named access) | N/A — already leak-checked |

Two families fall out immediately:

- **Rows 6-8 need nothing.** They are named access types, so SPARK's built-in
  ownership already forces them freed on every path; `Needs_Reclamation` adds
  nothing. (The request path is already advertised leak-free on this basis —
  README "Security".)
- **Rows 4-5** are records whose owning-ness comes from an access component.
  `Doc` is already annotated. `Store` is *already an owning type today* because
  of `Path_Access` (`src/memcp_store.ads:644`), so `The_Store`, a library-level
  singleton (`src/memcp_resources.adb:9`), is already governed by the leak
  machinery and proves clean — good evidence the library-level-singleton case is
  not a blocker.

The live question is therefore **rows 1-3: the raw C handles.**

## The gap `Needs_Reclamation` would close

Today `Database`, `Statement`, and `Embedder` are opaque `System.Address`
wrappers. `limited` (rows 1-2) prevents a *copy* → *double-free*, but **nothing
makes GNATprove check that they are ever released.** A `Prepare` with no matching
`Finalize` on some future error path would be an *undetected* leak. The store
avoids this by hand — it `Finalize`s every statement on every path
(`src/memcp_store.adb:412-457`, `:544-578`, `:1082-1195`, and throughout) and
even silences the resulting "set by `Finalize` but not used" flow message with a
targeted `pragma Warnings` (`src/memcp_store.adb:22-27`). That manual, comment-
documented discipline is exactly what `Needs_Reclamation` would turn into a
machine-checked obligation — very much in this project's proof-first spirit.

`Statement` is the sharpest case: statements are created and finalized in loops
with many early-exit paths, so the "forgot a `Finalize`" bug is live. `Database`
is lower-frequency (one per store) and `Embedder` lower still (one global,
copyable, `src/candle_spark.ads:29-31` design note).

## Spike result (the decisive finding)

A throwaway spike annotated `Database` and `Statement` in
`sqlite_vec_spark.ads`, added `Is_Reclaimed` ghost predicates
(`not Is_Open` / `not Is_Valid`), and ran `gnatprove` scoped to the unit. It was
reverted; no production code changed. Findings, in order:

1. **`Hide_Info` alone is rejected.** With the private part hidden but the full
   view still a `System.Address` record, GNATprove errors:
   *"full view of type annotated with an Ownership annotation shall be subject to
   ownership"* (rule 4). The `Doc` route does **not** transfer, because a raw C
   pointer is not an Ada access.

2. **The only valid route is `pragma SPARK_Mode (Off)` on the private part.**
   This is the canonical SPARK idiom for C-resource handles (a file-descriptor-
   style type). It hides the full view from SPARK entirely, so rule 4 no longer
   applies.

3. **But that forces the *entire* package body out of SPARK.** With the private
   part `SPARK_Mode (Off)`, the body may no longer be `SPARK_Mode (On)`
   (*"incorrect use of SPARK_Mode"* at `sqlite_vec_spark.adb:20`). Every wrapper
   body reads/writes `.Handle` (~25 sites: `Open`, `Close`, `Prepare`, the
   `Bind_*` family, `Step`, `Reset`, `Finalize`, and the `Column_*` readers), so
   there is no way to keep them individually in SPARK. The whole "the wrappers
   are proven; only the C bodies are trusted" property of the crate
   (`sqlite_vec_spark.ads:17-22`) is lost.

So the trade for the SQL binding is concrete:

- **Gain:** GNATprove enforces, forever and on every path, that every `Database`
  and `Statement` is released before it is dropped — across the store, the
  resources singleton, and any future caller. The manual discipline +
  `pragma Warnings` silencing in the store can go away.
- **Cost:** the ~370-line `sqlite_vec_spark.adb` body leaves SPARK. Lost AoRTE
  proof is thin and boundary-shaped (index casts `Interfaces.C.int (Index)`,
  length guards, and the `Column_Text` allocate-and-copy) — the kind of C-edge
  code the crate already trusts via `Pre`/`Post` — but it is a real reduction of
  proved surface, and the specs' `Post` contracts become *trusted* rather than
  *checked against the body*.
- **Secondary risk:** `Is_Open` / `Is_Valid` change from inlined expression
  functions (`sqlite_vec_spark.ads:351-361`) to opaque functions (their bodies
  move out of SPARK). Store proofs that lean on their *definition* rather than on
  the operations' `Post` contracts may need small contract additions. This is
  the main unknown in the proof-cost estimate.

The `Embedder` (row 3) has the identical `System.Address` obstacle, plus it is
*copyable* (`src/candle_spark.ads:63`); making it owning would forbid the copy
and change its value semantics. Its leak risk is minimal (one global,
`Unload`ed once in `Memcp_Resources.Close`, `src/memcp_resources.adb:57-60`).

## Proof-cost estimate

Assuming the SQL binding is converted via `SPARK_Mode (Off)` private part:

- **`sqlite_vec_spark` (spec):** small, mechanical — 2 type annotations, 2 ghost
  predicates, flip private part to `SPARK_Mode (Off)`, flip body to
  `SPARK_Mode (Off)`. ~1 hour.
- **`memcp_store` (the real work):** re-prove the whole body with `Statement` /
  `Database` now owning. Expected outcome: **most paths already discharge**
  because the code already `Finalize`s everywhere. Residual effort is (a) any
  path the leak check newly flags (a genuine latent bug if so — desirable), and
  (b) re-establishing store proofs that depended on the now-opaque
  `Is_Open`/`Is_Valid` bodies. Estimate **0.5-2 days**, dominated by (b).
- **`memcp_resources`:** `The_Store` is already owning; the new `Database`
  component rides the existing machinery. Watch the `MS.Open (The_Store, …)`
  `out`-parameter overwrite (`src/memcp_resources.adb:32`) — the old value must
  be reclaimed there; it proves today for `Path_Access` so it should extend.
  Low, **~2 hours**.
- **CI / regression:** re-run `make prove` (README reports 5211 checks, 0
  unproved in-project) and confirm no new unproved obligations and the
  expected-failure baseline is unchanged. **~half a day** including iteration.

Total: **roughly 1.5-3 days**, with the schedule risk concentrated in store
re-proof after `Is_Open`/`Is_Valid` become opaque.

## Risks

1. **Loss of proved wrapper surface** in `sqlite_vec_spark` (the core property
   the crate advertises). Reframes the FFI trust boundary outward to the whole
   binding body — arguably acceptable (that code is thin marshalling), but it is
   a visible regression in the proof story and the README/LAYOUT text would need
   updating.
2. **Opaque `Is_Open`/`Is_Valid`** ripple into store proofs (the main effort
   unknown).
3. **`Embedder` copyability** — annotating it is a value-semantics change for
   little leak-safety gain; likely not worth it.
4. **All-or-nothing at the crate level** — `Statement` (the strong case) cannot
   be annotated without taking `Database` and the whole body with it, because
   they share one private part / body `SPARK_Mode`.
5. **Low upside relative to today's guarantees** — the store already releases
   everything by hand and proves to Silver; the annotation converts a *reviewed*
   invariant into a *proved* one, which is valuable but incremental, not a fix
   for a known live defect.

## Recommendation

**Proceed, but narrowly and only if the leak-freedom guarantee is judged worth
the wrapper-proof regression — and treat it as a two-phase, reversible change.**
This is a judgement call for the maintainer; the honest framing is that it is a
*trade*, not a clear win.

- **Phase 0 (done here):** confirm mechanics and cost via the spike. ✔
- **Phase 1 — SQL binding (`Database` + `Statement`).** The best target, as #5
  suspected, *because* it is where the leak risk is real (statements in loops)
  and where the manual discipline + `pragma Warnings` silencing lives. Convert
  via the `SPARK_Mode (Off)` private-part idiom; the real work is re-proving
  `memcp_store`. Gate on `make prove` staying green with 0 new in-project
  unproved checks. If store re-proof balloons (risk 2), the change is cleanly
  revertible.
- **Phase 2 — `Embedder`, only if Phase 1 is smooth.** Lower value; also needs a
  `limited` conversion to be sound. Likely **defer or decline**.
- **No action** for the access-typed pointers (rows 6-8) or `Doc`/`Store`
  (rows 4-5): already covered.

If the maintainer prefers to preserve the "proven wrappers" property of the
binding crate above all, the defensible alternative is **do not proceed**: the
existing `limited` handles + hand-audited `Finalize` discipline + Silver proof of
the store already deliver strong, documented guarantees, and `Needs_Reclamation`
here buys enforcement of an invariant that is currently maintained by review
rather than closing a known defect.

## Appendix — spike commands (reproduce / discard)

Annotate `Database`/`Statement` in `sqlite_vec_spark.ads`, add `Ghost`
`Is_Reclaimed` predicates, set the private part to `pragma SPARK_Mode (Off)`,
then:

```sh
make build   # generate Alire config GPRs (cargo pre-builds + fetch-deps)
alr gnatprove -P memcp.gpr -j0 --level=2 --report=fail -u sqlite_vec_spark.adb
```

Observed errors walk exactly the three findings above. Revert with
`git checkout crates/sqlite_vec_spark/src/sqlite_vec_spark.ads`.
