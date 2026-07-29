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
- **Don't explain aspects.** `Global`, `Depends`, `Volatile_Function`,
  `Annotate`, `Abstract_State` and their properties say what they say. Do not
  restate them or justify their shape. Where a note is genuinely needed on an
  aspect, put it *inside* the aspect clause.
- **Say what an entity is, not how it came to be that way.** A type gets a line
  ("Opaque database connection handle."), not a paragraph on its representation.
- **Unit headers name the unit and its scope**, in a sentence or two. Facts
  about individual entities belong on those entities, never summarized upward
  into the header.

### Placement is correctness, not style

The AdaCore LSP plugins follow gnatdoc `--style=gnat`, so a doc block is
attributed to the declaration **above** it. A block placed *before* a
declaration therefore becomes the hover text of the *preceding* entity — the
comment is not merely dropped, it is shown against the wrong name.

- **Every doc block goes below its declaration.** Types, subprograms, objects,
  constants, `pragma`s, and local declarations inside bodies. Bodies included:
  hover works there too, and a body reader deserves documentation even though
  gnatdoc does not publish it.
- **One block per declaration.** Never share a leading block across a run of
  constants — separate them with blank lines and give each its own block below.
- **Never let a comment be the first thing inside a package.** It silently
  becomes the package comment and overrides the file header.
- **Packages and generics are the exception**: their block is read from above,
  which is what makes a file header work.
- Start the text with the entity's name where that aids hover reading
  ("`Length`, clamped from size_t to Natural...").
- `@param`/`@return`/`@enum` complete, and always a one-sentence lead line even
  where it repeats a tag. Never delete a tag: `make docs-check` gates on them.
- `scripts/check-doc-placement.sh` gates specs.

## Development

If the user wants to do development, check to make sure the AdaCore skills
plugin is installed - you'll have (at least) /alire and /gnatprove. If not,
stop and ask the user to install the plugin.
