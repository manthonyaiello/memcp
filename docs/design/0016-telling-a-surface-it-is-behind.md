# 0016 — Telling a surface it is behind

Status: **Implemented** in `src/memcp-hooks.ads`, the `Client_Meta` formal of
`Spark_Mcp.Server`, and `scripts/hooks/hook_common.sh`; gated by
`scripts/check-hook-version.sh`; tested by `tests/hooks/test_stale.sh` and
`tests/src/test_dispatch.adb`.

Surfaces drift. A hook wired months ago keeps running, keeps exiting 0, and
keeps looking exactly like a current one. That is the same shape as every other
defect in this epic: nothing is broken loudly, so nothing is noticed.

## What the digest already answers, and what it cannot

`install.sh` records the digest of each hook as installed, and each hook
re-digests itself at runtime and reports a mismatch. That answers *is this hook
what was installed here* — a question with both operands on the surface.

*Is what was installed here what the repository ships* has one operand on a
machine the surface cannot see. No amount of local checking reaches it.

The server can. It shipped from the same repository as the hooks, and it
receives their release on every `initialize`, in `clientInfo.version` — a field
both hooks already sent. So the comparison happens where the two facts meet, and
needs no new call, no schema, and no stored state.

## The comparison is the server's

The hook sends a version and reads a verdict; it never compares. That keeps
version handling out of bash, and it means the policy can change without
redeploying a single hook — which matters precisely because the hooks that most
need a policy change are the ones too old to have received it.

It is equality, not ordering. Server and hooks ship together, so a surface is
current iff the strings match; nothing anywhere orders releases.

Only the release part is compared. A hook reports `release+digest`, and the
digest describes files on a machine the server knows nothing about, so treating
it as part of the identity would report every surface as stale forever.

Only clients whose `clientInfo.name` begins with `memcp-` are compared at all.
Claude Code's own MCP connection reports its own version; calling that a stale
hook would put an unactionable block in front of the user on turn one.

The note's *presence* is the whole signal. A current hook, a client that is not
a hook, and a server too old to know about any of this all answer without it.
The hook therefore reads absence as silence, never as confirmation that it is
current — the one reading that cannot be produced by an old server.

## Report, do not update

The issue this closes was drafted as a self-updater: fetch the pinned release
tag over `curl`, verify it against a digest the server advertises, install to a
temp path, self-test, atomic rename, refuse a downgrade.

Every one of those rails exists because a pull is untrusted and partial. The
transport that shipped instead is a push — `deploy.sh` tars the hook set over
ssh from the one machine that holds a checkout, runs `install.sh` on the far
side, and rewires that surface's `settings.json`. The bytes come from a tree
that was just built and tested, and the digest is re-recorded in the same
operation. There is nothing left for a fetch-verify-selftest pipeline to
protect.

What a push cannot do is remind you to run it. That is the whole of what is
built here.

So the remedy names `deploy.sh` and the surface, and stops. Acting on it is the
user's: the surface holds no checkout to update itself from, and a hook that
deployed itself at session start with nobody watching, and then broke, would
have destroyed the channel it needed to report that it broke. That is the
silent-hook failure this epic exists to fix, arrived at from the other
direction.

The related rail — *refuse to overwrite a locally modified hook* — was dropped
deliberately. It fired once, during development on the machine that holds the
checkout, and `deploy.sh --local` wires `settings.json` straight at the working
tree there, so on a development surface a local modification is the normal state
and gating on it is noise. The runtime report remains, as diagnosis.

## Two copies of one string

`MEMCP_HOOK_VERSION` is bash and `Memcp.Hooks.Hook_Version` is Ada, so nothing
in either language can hold them together. `scripts/check-hook-version.sh` does,
and also gates the bump: a change anywhere under `scripts/hooks/` must come with
a change to the string.

That second half is strict on purpose. The digest a hook reports covers every
byte of `hook_common.sh` and the hook, so after a comment-only change a deployed
surface genuinely no longer matches the repository. Over-reporting costs a
redeploy. Under-reporting is the silent drift the gate exists to prevent.

The honest limitation: the string is still bumped by hand, and the gate can only
check that a bump happened, not that it was correct. A hand-edit that moves both
constants to the wrong value is undetectable here, and would report every
surface as stale at once — loud, and therefore survivable.

## What this does not catch

A surface that stopped calling. Staleness is inferred from a version that
arrived; a dark surface sends nothing to compare and looks exactly like a
surface nobody is using. Separating those needs stored per-surface provenance,
which is issue #58, and a fleet-wide view computed from it, which is #59. The
boundary stays there rather than being pulled forward into a mechanism that
cannot see across surfaces.
