# 0020 — A SQL error is an exception

Status: **Implemented** in `src/memcp-store.adb` (the checked statement layer
and every operation on it) and `gnat.adc` (the extension gate). Refs #78.

`Memcp.Store` drove SQLite through a status variable: prepare, then a bind
under `if St = Sql.Ok then`, then another, then a step, then a finalize, then a
test of what the status ended up as. Forty-two statements were spelled that way.
The shape put the failure handling between every pair of adjacent steps, so the
sequence a reader wants — *this SQL, these parameters, this outcome* — was the
one thing the code did not show.

It is now a raise. A small layer over the binding crate's primitives turns a
failing status into `Sql_Error`; each operation catches it once; each statement
is released in a `finally` part. The body lost about 250 lines net, and gained
the layer.

## What is a failure and what is an answer

The distinction the layer rests on is that not every non-`Ok` status is a
failure. `Done` from a `SELECT` means the row is not there, which is an answer a
caller asked for. So:

- `Step_Row` returns `Have_Row` and raises only on a status that is neither
  `Row` nor `Done`. Every "is it there?" query goes through it.
- `Step_Done` raises on anything but `Done`, `Row` included: a statement that
  yields no rows yielding one is a failure.
- `Check` raises on anything but `Ok`, and the binds, `Reset`, `Prepare` and
  `Exec` are three lines each on top of it.

The operations that report an absence as `Success` — `Fetch_Summary` on an
unknown id, `Forget_Summary` and `Reindex_Session` on a missing row,
`Add_Column` on an already-migrated database, `Save_Autorecap` declining to
overwrite — say so in the branch that reads `Have_Row`, not in a rescue. Nothing
about that changed; what changed is that it is now visible as the only
non-failure condition in the operation.

## The extension gate

`finally` requires `pragma Extensions_Allowed (All_Extensions)` as a
configuration pragma. Neither `-gnatX` nor `-gnatX0` nor
`Extensions_Allowed (On)` admits it on FSF 16.1.

The pragma opens **every** language extension, not the one being used. That is
the cost, and it is worth naming rather than burying: the tree is not gated
against other extensions arriving in it, only against them arriving unnoticed by
a reader who knows what this pragma was added for. The compensating fact is that
the whole tree builds clean under it with `-gnatwe` on, and proves unchanged.

## Frames nest by ownership

A `finally` part runs while an exception propagates; an enclosing handler runs
after it. That ordering is what makes frame nesting a correctness rule rather
than a layout preference:

- A **statement** owns the innermost frame and is released in its `finally`.
- A **transaction** owns the frame outside that, and its handler rolls back and
  re-raises.
- The **operation** owns the outermost, and its handler reports `Db_Error`.

Invert the middle two and the `ROLLBACK` runs with statements still live.

`Prepare`'s exceptional case reclaims the statement only when `Prepare` itself
raises; a raise from a later bind or step leaves a valid, owned statement, which
is why the release is required and belongs in `finally`. Dropping it gets
`medium: resource or memory leak might occur at end of scope`. The same frame
serves any other owned thing that outlives a raising call: `Save_Session`'s
transcript path and `Reindex_Session`'s copied timestamp are freed there too.

`BEGIN` sits **outside** the frame it opens. An operation whose transaction
covers only part of its work — `Save`, `Save_Session`, `Save_Autorecap`,
`Reindex_Session` — would otherwise reach a `ROLLBACK` on a failure that
happened before any transaction existed.

`Rollback` is the one helper that promises not to raise: it wraps its own `Exec`
in a handler that logs. That promise is what makes it callable from a handler,
which is where it is always called from.

## What the prover required

Two obligations are not obvious from the code and will not survive a rewrite
that forgets them.

**`Check`'s exceptional case must name `St`.**

```ada
   procedure Check (St : Sql.Status)
     with Post => St = Sql.Ok,
          Exceptional_Cases => (Sql_Error => St /= Sql.Ok);
```

Written `Sql_Error => True`, the handle facts do not survive the raise and
`Prepare`'s own exceptional case goes unproved.

**A statement stepped in a loop needs a `Loop_Invariant` restating
`Is_Valid`.** `Sql.Finalize` takes the statement `in out`, so a frame whose
`finally` releases it *writes* it, which puts it in the frame of any loop nested
inside. `Prepare`'s postcondition then does not survive the back edge and every
`Column_*` read in the loop body fails its precondition. Six loops here carry
the invariant; the loops directly in a subprogram's own frame do not need it —
removing any of the six brings the precondition failures straight back.

## Where the layer lives

It is local to the body of `Memcp.Store`. The binding crate stays
primitives-only, because a status-returning primitive is the right shape for a
binding: it is the client that knows which non-`Ok` statuses are answers. If a
second client ever appears, this promotes to a `Sqlite_Vec_Spark.Checked` child
rather than moving into the crate proper.

The package spec did not change, and neither did `Memcp.Tools`. Every operation
still reports `Op_Status`; `Sql_Error` never leaves the body.
