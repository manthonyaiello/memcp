# 0014 — The trust surface, and why it is a budget

Status: **Implemented** in `scripts/check-trust-surface.sh` against
`scripts/trust-surface.txt`; the root job of the CI graph.

The claim this project makes is that its code is proved. The interesting part of
that claim is not what the prover covers but what it does not, and that set was
until now held only in a maintainer's head — so a change widening it landed as an
ordinary review comment, if it was noticed at all. `scripts/trust-surface.txt`
makes the set explicit and CI holds it still.

## A budget, not a ban

A rule of "never add to the trust surface" cannot survive its first genuine
exception, and there will be one: a runtime unit with no contracts, an allocator
SPARK forbids, a C library that has to be called. Once the rule is broken the
rule is gone, and until then it makes the maintainer the obstacle in every
conversation.

So the rule is a price instead. A new site may be added, and it costs a named
entry, a sentence saying why no SPARK formulation works, and a reviewer who reads
that sentence. The manifest diff *is* the argument — the discussion happens over
the contributor's own justification rather than over the principle, and the
answer to "may I" is decided by whether the sentence holds up.

An entry with an empty justification fails the gate. An exception nobody argued
for is the thing the manifest exists to prevent.

## The grain differs by kind

`SPARK_Mode => Off`, `pragma Assume`, a GNATprove justification and a suppression
are **point exceptions**: each one is a specific claim about a specific
subprogram, so each is keyed by file and enclosing declaration. Nothing is keyed
by line number — the manifest has to survive an edit above it.

A foreign import and a hand-written `.c` or `.rs` are not point exceptions but
**boundary**. Adding an import to a file that already binds C is work inside a
boundary the project has already accepted; a *new* file of imports moves the
boundary. So those kinds are keyed by file, and it is the appearance of a file
that trips the gate, not the count of imports within one.

## SPARK by default, and still said out loud

The leakiest hole was never `SPARK_Mode => Off` — it was a new file saying
nothing at all, which no search for `Off` can find. `gnat.adc` sets
`pragma SPARK_Mode (On)`, and each crate carries its own because
`Local_Configuration_Pragmas` is project-local. A unit outside SPARK now has to
say so at its own declaration, and GNATprove names the configuration pragma when
it rejects one.

The per-unit aspects stay, and are not redundant with it. The configuration
pragma closes the hole; the aspect is what a reader sees at the declaration
without going looking for a default. They answer different questions.

## Suppressions are trust, which needs warnings to be fatal

The build is `-gnatwe` and the proof runs `--warnings=error`. A warning therefore
cannot be left standing — it is fixed, or it is suppressed. That is what makes a
suppression pragma a claim, made by hand, that the tool is wrong about this line,
and so a trusted site like any other.

The order matters: without warnings-as-errors, listing suppressions would gate
only the honest path, since nothing would stop a contributor leaving the warning
unsuppressed and unexamined instead.

## What this gate cannot see

It reads syntax. A weakened postcondition still proves. A `Global => null` that
lies about a foreign import still proves. A `Pre` that moves an obligation onto a
caller outside SPARK still proves. A widened subtype makes a range check vanish
rather than fail.

The semantic half is the proof gate with its empty allowlist (`0006` covers how
that run is cached): nothing unproved at `--level=2`. Neither gate is the
invariant on its own. Together they say *this code is in SPARK* and *it
discharges* — and the first is what the second silently assumed.

There is a further hole the gate cannot close: it can be satisfied by editing the
manifest, since it checks that a justification is present and not that anyone
read it. `.github/CODEOWNERS` covers that by requesting the review the design
assumes. Requesting is not requiring — making it blocking is
`require_code_owner_review` on the `main` ruleset, which is a repository setting
rather than a change to the tree, and which with a single owner would also block
that owner's own pull requests, because GitHub does not allow self-approval.

One stronger mechanism is deliberately not used. The `.spark` files GNATprove
emits carry a per-entity SPARK status that no formatting can evade, unlike a
search of the sources, but they exist only after a prover run and would gate
minutes late rather than at the root.

## Where it lives

- `scripts/trust-surface.txt` — the manifest; the fourth field is the argument.
- `scripts/check-trust-surface.sh` — derives the same set from `git ls-files` over
  `src/` and `crates/*/src` and fails on any difference in either direction.
  Test drivers and proof harnesses are out of scope; they ship to nobody.
- `gnat.adc`, `crates/*/gnat.adc` — SPARK as the default.
- `scripts/check-proof.sh` — `--warnings=error`, and the exit status that makes it
  bite.
- `.github/CODEOWNERS` — review routing for all of the above.
- `CONTRIBUTING.md` — the same rule, for someone who has not read this.
