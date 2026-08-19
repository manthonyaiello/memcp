# 0018 — Detecting a hook that stopped

Status: **Implemented** in `src/memcp-store.adb` (`Degraded_Surfaces`,
`Touch_Surface`), `src/memcp-tools.adb` (the result objects, the warning on
every tool, the `findings` member) and `scripts/hooks/hook_common.sh`
(`memcp_degraded`, `memcp_unattributed`); tested by `tests/src/test_store.adb`,
`tests/src/test_tools.adb` and `tests/hooks/test_health.sh`.

Two hooks can stop, and they fail differently. SessionEnd is forked off at
shutdown with nowhere to report to, so its failure has to be read from the
corpus. SessionStart failing is worse: nothing is injected, so nothing that
follows knows anything is wrong.

## The signature of each, and who can see it

A session that saved a summary and never had a transcript uploaded is exactly
what a stopped SessionEnd looks like from the corpus. Nothing else needs to be
recorded — no local error log, no cross-session propagation, no clearing
protocol — because the absence of the row *is* the report.

A surface where SessionStart never ran cannot produce a surface id
(see [0017](0017-which-machine-a-row-came-from.md)), so a call arriving without
one says so on its own. That is why this needs no fleet-wide inference: the
machine reports itself, on the surface, at the moment it is used.

## Both ride on calls that already happen

The metric is a member of `recent`, which the SessionStart hook already calls
once per session; the missing-surface warning is a member of every tool's
result. Nothing new is called, and no tool exists whose purpose is to be asked
how things are going.

`recent` is therefore also where a surface is recorded as still working, which
separates *last checked in* from *last wrote a row* — a surface that reads and
never saves is not a surface that has stopped. No other tool does this: a read
from anywhere is not the start of a session.

## Every result is an object

A bare JSON array has nowhere to put a warning, and the two things a caller
must be told here are not part of the data it asked for. So a list arrives in
`entries`, a single record in `entry`, and `warning` accompanies either.

The alternative — an object only when there is something to say — makes the
shape depend on the health of the fleet, so a client would first parse a
different shape on exactly the day something broke.

## Warn, never refuse

A missing surface does not fail the call, and a degraded fleet does not fail
anything. Refusing would convert silent data loss into loud data loss, and the
goal is diagnosis, not enforcement. Both messages name `doctor` as the step
that turns them into a remedy.

## Two bounds, because one number cannot do both jobs

A session still in flight has saved but not yet uploaded, and a machine that
was retired last year should stop being reported. The first wants sessions
weighed only in bulk, the second wants old ones to age out; a single threshold
expresses neither. `Health_Window` bounds how far back a surface is read and
`Health_Threshold` how many gaps it takes, and the count is over distinct
sessions, so a session that saves repeatedly as it develops weighs once.

## Computed per call, written nowhere

A finding written into the corpus would be embedded, become searchable, and
read back later as project history. Recomputing it per call is also
self-clearing: a fixed surface stops being reported without anything having to
acknowledge or forget it.
