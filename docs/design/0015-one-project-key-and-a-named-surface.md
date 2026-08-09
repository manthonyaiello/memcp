# 0015 — One project key, and a surface that says who it is

Status: **Implemented** in `scripts/hooks/hook_common.sh`,
`scripts/hooks/install.sh` and the two hooks, tested by `tests/hooks/`.

memcp records two artifacts per session: a Summary the model writes through
`save`, and a Session transcript the SessionEnd hook uploads. They are filed
under a project key that each side derived on its own — the hook from its
payload, the model from whatever it believed the project was called. Two
derivations, no agreement, and nothing anywhere comparing them.

## Agreement, not signing

The split does not need a token to close. If one side derives the key and the
other is *told* it, both sides file under one key by construction. So
SessionStart derives it and injects it, and the model uses it verbatim.

An HMAC over that key defends against something narrower and later: an agent
inventing a plausible project name when no hook ran at all. That is a real
failure mode, but it is not this one, and pricing the fix for it into the fix
for this one is what kept several surfaces unusable. The signed token is
therefore a separate change, and nothing here has to be migrated when it lands
— the key it signs is the key derived here.

## Why `--git-common-dir`

`--show-toplevel` answers with the path of the worktree you are standing in, so
a linked worktree invents a project and every worktree of one repository
fragments its history. `--git-common-dir` answers with the shared `.git` of the
main worktree whichever worktree asked, which is what collapses them.

The remote comes first anyway, because it is the only name that survives the
directory being renamed, cloned to a different path, or checked out twice. The
main worktree is the fallback for a repository that has no remote, and
`basename(cwd)` — the old behaviour, and the origin of the phantom keys — is
what is left when there is no repository at all.

The derivation is deliberately not idempotent under renaming an upstream: a
renamed repository becomes a new key. Renames are rare and a rename is visible;
a wrong key is neither.

## Silence is the defect

Both hooks exit 0 on every error path, and must: a memcp outage cannot be
allowed to break the client. But an exit status nobody reads is the same thing
as no error at all, and the specific thing being lost — injected context — is
an *absence*. The model cannot be relied on to notice that prior sessions did
not appear, because that is indistinguishable from a project that has none.

So SessionStart emits a block instead. Each names one fault and one remedy,
addressed to the model, which reports it to the user on turn one. The exit
status stays 0, so nothing about the client's behaviour changes; what changes
is that the failure has a reader.

SessionEnd cannot do this — it runs after the agent is gone — so it does not
try. A surface that stops uploading is detected from the shape of the corpus
instead: sessions carrying a summary and no transcript.

## What the loud version found on its first run

The first live run of the non-silent hook reported `no-session-header` against
the server this repository ships, and that turned out to be true of three
things at once. memcp answers `initialize` without assigning an `Mcp-Session-Id`,
answers in plain JSON rather than `data:` event frames, and returns a tool's
result as a text content block rather than in `structuredContent`.

All three are permitted by Streamable HTTP, and none of them is a fault in the
server: it declares no `outputSchema`, so a client that will not read `content`
is the side making an assumption the protocol does not grant it.

All three differ from the Python server the hooks were written against, and
each one on its own is enough to stop a hook dead while exiting 0. What makes
that worth an ADR is not how long it went unnoticed — it did not: the hooks
worked until the SPARK binary took the port, and the first session after the
switch is the one that reported it. It is that nothing about the failure was
*legible* before this change. The same three defects, arriving through a
handshake that exits 0 either way, would have read as a quiet project with no
history for as long as nobody went looking.

That is also the limit of what a replay harness at the `Dispatch` seam can tell
you (0013). Two of the three divergences are below that seam — a response
header and the transport's framing — and the third is a choice about the
envelope rather than about the payload the seam compares. A client assumption
is not a server bug, so no amount of server-versus-server replay will surface
one.

The hooks therefore accept either framing, treat the session id as the optional
thing it is, and read a result from `structuredContent` or from the text block,
whichever the server sent. The alternative — changing the server to match the
hooks — would have been a protocol change to fix a client assumption, and would
have left the client just as brittle for the next server.

Two error channels exist for the same reason and both are read: a JSON-RPC
`error`, and a successful response whose result carries `isError: true`. A tool
failure reported on the channel nobody reads is another silent failure.

## Version and digest, in one field

Both hooks already send `clientInfo.name` and `clientInfo.version` on
`initialize`, hardcoded and never bumped. Semver build metadata (`0.2.0+a1b2c3d4`)
carries the digest in that same field, so reporting what a surface is running
needs no protocol change and no new call.

Both halves are load-bearing. A version orders releases but is a claim the file
makes about itself, and a hook edited on the machine keeps making it — which is
exactly what happened: a deployed `session_end.sh` ran 42 lines ahead of git
while reporting the same `0.1.0` as every other copy. The digest is over the
hook *and* the library it sources, because the behaviour is the pair; the
installer records what it installed, and each hook digests itself at runtime
and compares.

Comparison is for equality, never ordering. Nothing in bash has to know that
0.2.0 follows 0.1.0.

## Config that needs no parser

The hooks are bash + curl + jq so they can run on a machine that hosts neither
implementation of the server. A config format requiring a parser would spend
that property, so the config is shell:

```sh
: "${MEMCP_URL:=http://127.0.0.1:8786/mcp}"
```

Every line is `:=`, so a variable already in the environment keeps its value.
Precedence is a property of the file's syntax rather than logic in the hooks,
which means there is no precedence bug to have. New keys arrive with defaults,
so an update never has to touch a user's configuration.

The one obligation this creates: the hooks must load the config *before*
applying their own defaults, or `${MEMCP_URL:-...}` masks the file. That is why
`tests/hooks/test_config.sh` asserts precedence twice — once on the loader, and
once through a whole hook run.

## Surface identity is minted, not derived

A host name is not an identity: it changes, and it is shared by every clone of
a machine image. So `install.sh` mints a UUID once and keeps it across re-runs,
alongside a human-readable label and the host name *as of minting*. A config
that later appears on a differently named host was inherited rather than
created there — a cloned VM, a restored backup — and that is exactly the
condition under which two machines would otherwise report as one surface and
quietly corrupt the provenance being added.

It is minted here rather than with the token that will carry it, so the surface
key never has to be migrated from host name to UUID afterwards.

## Testing bash without a server

The fault table is about what a hook does when the server misbehaves, and a
real server is a poor way to ask: making it refuse a handshake or return a body
that is not an event stream is harder than making a stub do it, and slower.

What the hooks actually branch on is `curl`'s exit status and the bytes it
prints. So the stub is a fake `curl` first on `PATH`, and `PATH` is replaced
outright from a directory of symlinks — which also makes "jq is not installed"
a case that can simply be staged. One case still dials a closed port with the
real `curl`, so the unreachable path is exercised end to end and the stub's
fidelity on the case that matters most is not taken on trust.

Derivation is table-driven over fixture repositories built in test setup, since
the interesting inputs (a linked worktree, a detached HEAD, a repository with
no remote) are all cheap to construct and impossible to assert against
otherwise.
