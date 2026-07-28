# CLAUDE.md — spark-memcp

## Build / run

Drive everything through the `Makefile` at the repo root (a thin wrapper over
Alire) rather than invoking `alr`/`gnatprove` directly:

```bash
make            # build the whole DAG (runs the cargo pre-builds + fetch-deps)
make model      # one-time: fetch embedding weights into ~/.memcp/models
make run        # serves POST /mcp on 127.0.0.1:8786 (blocking)
make test       # unit drivers + smoke tests
make prove      # gnatprove to Silver (--level=2)
make docs-check # gnatdoc gate: fails on any undocumented entity (see README)
make help       # list all targets
```

## Toolchain

If `alr`, `gnatprove`, `gnat`, or `cargo` is missing from PATH, **stop and ask
the user to fix it** — do not hunt for binaries or reinstall.

## Comments

Terse. Say what a competent Ada/SPARK reader cannot see in the code, then stop.
Applies to Ada, C shims, GPR files, shell scripts and the Makefile alike.

- **No teaching.** Do not explain SPARK, Ada or SQLite semantics. Name the
  entity and let the RM or vendor docs be the source. Explain this code's
  purpose, requirement or hazard.
- **No history.** Describe the code as it is, not as a change from what it was.
  No dates, no "used to", no PR narration — that belongs in the commit.
- **Respect abstraction.** Never name a client of the current unit. Name a peer
  unit only when it is `with`'d *and* the comment is wrong without it. Naming
  the C entity being bound is fine: that is the contract.
- **gnatdoc `--style=gnat`, bodies included.** Doc block goes *below* the
  declaration, with `@param`/`@return`/`@enum` complete. Always keep a
  one-sentence lead line, even where it repeats a tag. `scripts/check-doc-placement.sh`
  gates placement; packages and generics are the exception (read from above).
- **Aspect rationale follows the summary**, never precedes it.
- **In bodies**, one or two lines where a reader would otherwise think the code
  is wrong.

## Development

If the user wants to do development, check to make sure the AdaCore skills
plugin is installed - you'll have (at least) /alire and /gnatprove. If not,
stop and ask the user to install the plugin.
