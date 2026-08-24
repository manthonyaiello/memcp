# 0019 — Turning a fault into a remedy

Status: **Implemented** in `src/memcp-store.ads` (the `surfaces` report columns,
`Fleet_Health`), `src/memcp-hooks.ads` (`Is_Current`), `src/memcp-tools.adb`
(the `doctor` tool) and `scripts/hooks/session_start.sh` (the check-in's three
new arguments); tested by `tests/src/test_store.adb`, `tests/src/test_tools.adb`
and `tests/hooks/test_health.sh`.

Everything before this issue answered *something is wrong*. A warning naming no
machine, and a finding naming a machine but no step, both end at the same place:
somebody has to work out what to do. `doctor` is where that stops being the
reader's job.

## A remedy, not a status

Every fault carries the surface, the fault, and the command. The command is
text for the agent to run, never something memcp does: the server may not be
running on the surface at fault, and it cannot write files on a machine it has
never seen. That constraint is what makes the output shape what it is — a status
code would be actionable only where the server and the fault happen to coincide.

It also sets the test obligation. A check that the fleet "reports unhealthy"
would pass while emitting something nobody can act on, so every case asserts the
remedy's content instead: the surface named, the fault identified, the command
to run.

The surface asking gets `deploy.sh --local`, and every other surface gets
`deploy.sh <label>`. That is a real distinction and not a cosmetic one:
`deploy.sh` takes an ssh destination, the corpus stores a label, and the two are
not required to be the same string. For the surface asking, no destination is
needed at all.

## The roster is the other half of the answer

`recent` reports only what crosses the alarm line, because it reports unasked.
`doctor` was asked, so it also returns every surface on record with its counts
and what it last said about itself. A gap of one in three trips nothing and is
exactly what somebody diagnosing wants to see.

That is also what makes `doctor` useful with no surface id and no context, which
it has to be: it is where a missing surface id points, and a caller with no
surface has nothing else to go on.

## One query behind both

`Degraded_Surfaces` is `Fleet_Health` with the threshold applied. Two queries
computing the same window would eventually disagree, and the disagreement would
appear as `doctor` contradicting the finding that sent the reader to it. The
roster is driven from the `surfaces` table so a surface that has checked in and
written nothing still appears; the sessions that named no surface arrive as one
further group, windowed together, because no row can tell them apart.

## What a surface reports about itself

Three facts ride on the SessionStart check-in: the hook release, the host now,
and the host the identity was minted on.

The check-in is the only call that can carry them. `initialize` carries a version
with no surface to attach it to — memcp assigns no session, so the two cannot be
joined — and the model's calls carry a surface but know nothing about the hooks.
Recording them at the check-in is also what keeps them readable *after* a surface
stops calling, which is when a diagnosis needs them most: [0016](0016-telling-a-surface-it-is-behind.md)
can only report a surface that is still talking.

The columns are nullable and additive, as in [0017](0017-which-machine-a-row-came-from.md).
An empty hook version therefore means one of two things — a surface that has not
started a session since memcp began recording one, or hooks too old to report
one — and `doctor` says so rather than picking. Both take the same redeploy, so
the ambiguity costs the reader nothing.

Only the release is stored, not the `+digest` build metadata a hook reports on
`initialize`. The digest describes files on a machine this server knows nothing
about; the surface checks it against its own installer's record and reports the
mismatch there. Storing it here would be storing something no comparison can
use.

## Comparisons stay on the server

The surface sends both host names and the server compares them, rather than the
hook comparing and sending a verdict. Same reason as [0016](0016-telling-a-surface-it-is-behind.md):
the policy can then change without redeploying anything, which matters most for
the surfaces too far behind to receive a new policy. It is also the only
formulation that lets `doctor` report a mismatch on a surface *other* than the
one asking.

## Why the clone check is a diagnosis and not a detector

A hostname that differs from the one the identity was minted on means the config
was inherited — but a clone and a renamed machine produce the identical
observation, and their remedies are opposites. One re-rolls the identity; the
other keeps it and corrects the recorded host. A turn-one block would have to
either guess or print both, and printing both unprompted, every session, on a
machine that was simply renamed, is noise.

So the check lives where a two-branch remedy can be read at the moment somebody
is asking, and where the mismatch is visible for every surface rather than only
this one. That is the same argument that moved the per-surface hook version out
of the detectors and into here.

## No dark-surface fault

A surface that has stopped calling entirely was in scope and is not implemented.
Reporting it needs a threshold on clock distance, and every value is wrong for
somebody: a laptop away for three weeks is not a fault, and a build machine
silent for three days is. The roster carries `last_seen` per surface, which is
the fact; the reader supplies the judgement. A fault would be memcp asserting a
policy it has no way to get right.

## Every fault dates its evidence

`latest` is the newest row behind the claim. The sessions that named no surface
are why: in a converted fleet, that group's window is frozen historical rows
that no redeploy can attribute, so without a date it would be reported forever
as a live fault. With one, history reads as history and no recency policy is
needed anywhere.
