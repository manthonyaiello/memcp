# 0005 — `Needs_Reclamation` for the SQLite handles

Status: **Implemented** on branch `design/5-needs-reclamation` (PR #11). Refs #5.
Pending SPARK-team review of whether a cleaner idiom exists (see Note).

## What we did

`Sqlite_Vec_Spark.Database` and `Sqlite_Vec_Spark.Statement` are annotated
`Needs_Reclamation` (`crates/sqlite_vec_spark/src/sqlite_vec_spark.ads`). SPARK
now proves, at every call site, that an open connection is `Close`d and a valid
statement is `Finalize`d before it goes out of scope or is overwritten — the
resource-leak obligation that previously rested on hand-audited discipline in
`Memcp_Store`.

This joins the existing use of the same annotation on `Memcp_Json.Doc`.

## The ownership anchor

A `Needs_Reclamation` type must have a full view that is *subject to ownership*
(SPARK's phrase): it must contain an Ada access. The SQLite handles do not —
each is a bare `System.Address` over a C `sqlite3*` / `sqlite3_stmt*`, which
SPARK does not track as an owned resource. The address alone therefore cannot be
the ownership anchor.

So each handle's full view carries, alongside the address, a small owning
**token** — `type Ownership_Token is access Boolean` — whose lifetime shadows
the C handle's:

- **allocated** (`new Boolean'(True)`) the instant the C `open` / `prepare`
  succeeds — in `Open` and `Prepare`;
- **freed** (`Free_Token`, an `Unchecked_Deallocation`) the instant the C handle
  is released — in `Close` and `Finalize`.

Because the token is a genuine Ada access, the enclosing record is subject to
ownership and the annotation applies. The Boolean payload is irrelevant; only
null vs non-null — reclaimed vs owned — matters. Cost is one heap word per
handle, allocated and freed on the paths that already cross the C boundary.

The liveness and reclamation predicates are keyed on the token, so they stay in
lockstep on one field:

```ada
function Is_Open  (DB : Database)  return Boolean is (DB.Token /= null);
function Is_Valid (S  : Statement) return Boolean is (S.Token  /= null);

function Is_Reclaimed (DB : Database) return Boolean is (DB.Token = null)
  with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
function Is_Reclaimed (S  : Statement) return Boolean is (S.Token  = null)
  with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
```

Annotated API (visible part):

```ada
type Database is limited private
  with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
       Default_Initial_Condition =>
         not Is_Open (Database) and then Is_Reclaimed (Database);

type Statement is limited private
  with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
       Default_Initial_Condition =>
         not Is_Valid (Statement) and then Is_Reclaimed (Statement);
```

## Two rules the API had to satisfy

1. **The private part is hidden, not turned off.** An `Ownership` type requires
   its private part to be `SPARK_Mode (Off)` *or* hidden. We use
   `pragma Annotate (GNATprove, Hide_Info, "Private_Part")` — the
   `Memcp_Json.Doc` device — which keeps the wrapper bodies *in* SPARK.
   `SPARK_Mode (Off)` would have ejected the whole proven binding body.

2. **The releasing operations post `Is_Reclaimed` explicitly.** Under
   `Hide_Info`, clients cannot see that `Is_Reclaimed` is `not Is_Open`, so the
   contracts state it directly (as `Memcp_Json.Close` posts `Is_Closed`):

   ```ada
   procedure Close    (DB : in out Database)  with Post =>
     not Is_Open  (DB) and then Is_Reclaimed (DB);
   procedure Finalize (S  : in out Statement) with Post =>
     not Is_Valid (S)  and then Is_Reclaimed (S);
   procedure Open    (...) with Post =>
     (Is_Open  (DB)   = (Result = Ok)) and then (Is_Reclaimed (DB)   = (Result /= Ok));
   procedure Prepare (...) with Post =>
     (Is_Valid (Stmt) = (Result = Ok)) and then (Is_Reclaimed (Stmt) = (Result /= Ok));
   ```

## Proof

`make build` is clean (no new warnings). `make prove` (GNATprove Silver,
`--level=2`) reports **all checks proved (5451)** — up from 5211, the extra ~240
being the new resource-leak obligations, all discharged. `Memcp_Store` re-proved
with **no contract changes**: `Is_Open` / `Is_Valid` become opaque to clients
under `Hide_Info`, but each has `Global => null` and depends only on its
`in`-mode handle, so GNATprove carries their truth across operations from the
operation postconditions alone.

## Warning suppressions

The ownership annotation does **not** retire `Memcp_Store`'s
`"...is set by ""Finalize"" but not used after the call"` suppression. That is a
flow observation about the ineffective final write — `Finalize` is `in out` and
nulls the handle, and that reclaimed value is never read again — which is
orthogonal to reclamation: the annotation proves the resource *is released*, not
that the final write is read. Removing the suppression keeps the proof green
(5451, zero unproved) but resurfaces the warning across the store, so it stays.
No other suppression here relates to Database/Statement reclamation.

## Note (pending SPARK-team review)

The owning-token indirection exists only to give SPARK an ownership anchor for a
resource that is really a C pointer. It is sound and cheap, but it is a device.
The SPARK team is being consulted on whether a first-class mechanism lets
`Needs_Reclamation` apply to a `System.Address`-backed handle directly, without
a shadow allocation; if so, the token would be removed and the predicates
re-keyed on the handle. The annotated API above would not change.
