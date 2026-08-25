# Contributing

Contributions are welcome. One rule here is not the usual one.

## The trust surface

memcp is SPARK, proved to Silver (absence of runtime errors, `--level=2`), with
nothing unproved. `scripts/trust-surface.txt` lists every site that proof does
not cover:

- code outside SPARK — `SPARK_Mode => Off`
- assumptions the prover takes on faith — `pragma Assume`, and any
  `False_Positive` or `Intentional` justification
- suppressions — `pragma Warnings (Off)`, `Unreferenced`, `Unmodified`,
  `Suppress`
- the foreign code behind the bindings — the imports, and the C and Rust bodies

Suppressions are on that list because the build is warnings-as-errors
(`-gnatwe`) and `make prove-check` fails on any GNATprove warning in our
sources. A suppression is the only way to leave one standing, which makes it a
claim, made by hand, that the tool is wrong.

A contribution is not expected to add to that list. Where one genuinely must,
add the entry with a one-sentence justification in its fourth field, and say so
in the pull request. A reviewer will read that sentence.

```sh
make trust         # list the derived set, in manifest form
make trust-check   # the same set as a gate: any drift from the manifest exits 1
```

The gate runs first in CI, ahead of the documentation, build and proof jobs.

SPARK is the default: `gnat.adc` sets `pragma SPARK_Mode (On)` for the product
sources, so a unit outside SPARK has to say so at its own declaration. Units
also carry that aspect explicitly, which the configuration pragma does not
replace.

`gnat.adc` also sets `pragma Extensions_Allowed (All_Extensions)`, which is what
admits the `finally` parts `Memcp.Store` releases its statements in. It opens
every extension, not that one; see
[`docs/design/0020`](docs/design/0020-a-sql-error-is-an-exception.md).

## Before opening a pull request

```sh
make               # build the whole DAG
make test          # unit drivers + smoke tests (hook tests and version gate included)
make trust-check   # the trust surface is unchanged
make prove-check   # Silver, gated on a clean proof
make docs-check    # every entity documented, every doc block correctly placed
```

If the change touches `scripts/hooks/`, bump `MEMCP_HOOK_VERSION` and
`Memcp.Hooks.Hook_Version` together — CI fails the pull request otherwise, since
without a bump the surfaces already running the old hooks are never told they are
behind.

Why the surface is budgeted rather than forbidden, and what the gate cannot see,
are in [`docs/design/0014-the-trust-surface.md`](docs/design/0014-the-trust-surface.md).

Comment conventions are in [CLAUDE.md](CLAUDE.md). Design rationale belongs in a
numbered ADR under [`docs/design/`](docs/design/), not in a comment; history
belongs in the commit message.
