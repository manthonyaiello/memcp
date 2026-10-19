---
name: issue
description: Work a memcp GitHub issue end to end in an isolated worktree. Fetches the issue, creates a worktree under .claude/worktrees, reproduces the observation, does the work, runs the gates, opens a PR, and saves a summary to memcp. Use when the user says "/issue <number>" or asks to work on a specific issue by number.
---

# Work a GitHub issue

Fetch issue #$1 from `manthonyaiello/memcp`, set up a worktree in
`.claude/worktrees` for it, move to the worktree, reproduce what the issue
observed, do the work, run the gates, open a PR, and save a summary to memcp. If
you have questions, ask them as needed, but try to get as much done with
reasonable assumptions as possible.

```sh
gh issue view <n> --comments
git fetch origin
git worktree add .claude/worktrees/issue-<n>-<slug> -b issue-<n>-<slug> origin/main
```

The branch is `issue-<n>-<short-slug>`, which is what the merged branches here
are called. If the issue names a parent epic, read the parent first: a
sub-issue's body omits the decisions and non-goals the epic already settled.

**The worktree comes first, before any file is touched.** The main checkout is
what the user reads in the IDE while you work, so a branch checked out there,
or an edit made there, changes the files under them. No change is too small for
this.

## What this repository expects of the work

- **Reproduce first.** Most issues state the observation that opened them, so
  the after needs a before. A bug that crashes the server is reproduced against
  a scratch server, never the one on 8786 (see below).
- **Proof is the gate, not tests.** The tree proves to Silver with an empty
  allowlist. A change that admits a new class of error closes it with a
  postcondition or an assertion, not a test. Never suppress or justify a check
  to get green: fix the contract, which is often in json-spark.
- **Rationale goes in an ADR.** Why a seam, bound or trust boundary has its
  shape belongs in a new numbered `docs/design/NNNN-*.md`, not in a comment.
  CLAUDE.md has the comment rules, and `make docs-check` enforces where doc
  blocks are placed.
- **The trust surface is a budget.** A new `SPARK_Mode => Off`, `pragma Assume`,
  justification, suppression or binding file needs a line in
  `scripts/trust-surface.txt` with a one-sentence justification, and the PR
  has to say so (CONTRIBUTING.md).
- **Fail loud.** No failure is swallowed: `Log.Error` plus a nonzero exit,
  detected in the helper and halted at the root.
- **The repository is public.** Issue, PR and commit text never names a
  machine, host or surface, a project key from a corpus, or a per-key count.

## A fix that belongs in json-spark

memcp pins `json` to a commit of `manthonyaiello/json-spark` in `alire.toml`. A
root cause in that library is fixed there, in its own worktree and PR (its
default branch is `master`; its Makefile has its own `tests`, `prove-check`,
`docs-check` and `trust-check`). memcp then bumps the pin.

While the json-spark PR is open, the memcp branch may pin its head commit, and
both PRs say so. A squash merge produces a new SHA, so after the json-spark
merge repin to the commit on `master` before the memcp PR merges. A pin to a
commit that is not on `master` builds today and stops building once the branch
is deleted.

## Things that go wrong in a worktree specifically

- **The first `make` is slow.** `alire/`, `obj/` and the cargo `target/`
  directories are gitignored, so a fresh worktree fetches dependencies and
  builds the Rust crates. Run it once with `run_in_background`, not in the
  foreground.
- **Never touch the production server.** `make run` and `bin/memcp` default to
  port 8786 and `~/.memcp/memcp.db`, which is the live store, kept running by
  launchd. To run a scratch server:

  ```sh
  MEMCP_PORT=8799 MEMCP_DB_PATH=<scratchpad>/test.db bin/memcp
  ```

  Run it with `run_in_background`, and stop it by the PID you started. Never use
  `pkill` or `killall`.
- **To diagnose a crash, use a backtrace.** If an exception kills the server, run it
  under `lldb -b` with a breakpoint on `__gnat_debug_raise_exception` and send
  the request.

## The gates

Before opening the PR, run these in the worktree:

```sh
make test          # always
make prove-check   # always: the proof gate, empty allowlist, warnings are errors
make docs-check    # always: undocumented entities and misplaced doc blocks
make trust-check   # always: drift from scripts/trust-surface.txt
make prove-mcp     # when crates/spark_mcp/ changed
make test-hooks    # when scripts/hooks/ changed (with make hook-version)
```

A gate you skip is named in the PR along with the reason, so that a deliberate
omission and a silent one do not look the same in review. A green CI covers only
the source closure of each gate: a `.gpr` that no target names has not been
verified.

## The PR

Write the body to a file and open the PR with
`gh pr create --body-file <file>`. Title it the way recent merged PRs are
titled: an imperative sentence about the effect, then `(fixes #<n>)`. In the
body:

- the before and the after, both measured, including a null result or a
  regression;
- every gate run, and every gate skipped with its reason;
- any change to the trust surface, with its justification;
- the ADR, when the change made one.

The user merges. After they confirm the merge, delete the branch and remove the
worktree. If the issue's premise turns out to be wrong, say so in the PR and leave
the issue open with what was learned, rather than closing it with a change
that does not help.

Finish by saving the session to memcp (`save`, with the surface and session id
exactly as SessionStart injected them).
