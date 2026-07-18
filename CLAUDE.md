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
make help       # list all targets
```

## Toolchain

If `alr`, `gnatprove`, `gnat`, or `cargo` is missing from PATH, **stop and ask
the user to fix it** — do not hunt for binaries or reinstall.

## Development

If the user wants to do development, check to make sure the AdaCore skills
plugin is installed - you'll have (at least) /alire and /gnatprove. If not,
stop and ask the user to install the plugin.
