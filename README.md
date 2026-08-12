# memcp

[![CI](https://github.com/manthonyaiello/memcp/actions/workflows/ci.yml/badge.svg)](https://github.com/manthonyaiello/memcp/actions/workflows/ci.yml)
[![SPARK](https://img.shields.io/badge/SPARK-Silver-C0C0C0.svg)](https://docs.adacore.com/spark2014-docs/html/ug/en/source/assurance_levels.html)
[![License](https://img.shields.io/github/license/manthonyaiello/memcp.svg?color=blue)](https://github.com/manthonyaiello/memcp/blob/main/LICENSE)

A custom memory system for Claude Code sessions designed for progressive
disclosure, implemented in SPARK and proven to SPARK Silver (Absence of
Runtime Errors).

`memcp` runs an HTTP MCP server to which Claude Code connects to during a
session, plus a pair of shell hooks that run on session start and session end.
Storage is a single sqlite file at `~/.memcp/memcp.db` (override with
`MEMCP_DB_PATH`); raw session transcripts live next to it under
`~/.memcp/sessions/<project>/<session_id>.jsonl`. Embeddings are local via
the `candle` embedder (all-MiniLM-L6-v2) + `sqlite-vec`. No network calls, no
auth, no cost.

## Vocabulary

memcp distinguishes four levels of detail for any past session:

| Term | What | Where |
| --- | --- | --- |
| **Header** | 1–2 line title that surfaces in `recent()` and `search()` hits. The 5 most recent Headers are injected into Claude's starting context by the `SessionStart` hook. This adds up to about 10 lines to your context window. | `summaries.headline` |
| **Summary** | Possibly long, semi-structured account of the session. Not injected into starting context, but reachable from the injected Headers if Claude determines that a Header is relevant to your discussion. | `summaries.body` |
| **Details** | The verbatim conversation, one embedded chunk per turn (a single user or assistant message). Thinking, tool calls, and tool results are deliberately not stored — only what was actually said. `fetch_chunks` searches turns by relevance; `fetch_turns` retrieves them by position (`ordinal` = turn index, e.g. `last=2`). Both can be scoped by `session_id`. | `chunks.body` |
| **Session** | The raw `.jsonl` transcript itself. Never surfaced by Claude through the `memcp`. Retrieved (over the HTTP MCP connection, thus allowing session files to be saved from remote Claude sessions to the machine running `memcp`) so that you always have a full backup. | on disk, write-only from the model's perspective |

Every Header carries a `kind`:

- `kind="diary"` — the model called `save()` and wrote a real Summary.
- `kind="autorecap"` — the model didn't `save()`, so the SessionEnd hook's
  upload found a `※ recap` line in the transcript and used it as the Header.
  For these, the Header text **is** the Summary text — there's nothing more
  to learn from `fetch_summary`. Go straight to `fetch_chunks` if you need
  more.

Raw Sessions are deliberately not retrievable through any MCP tool —
transcripts routinely run 100K+ tokens, far too much to consume without
direct human action. The files are there if you want to do archaeology by
hand, but the model never sees them.

## Retrieval ladder

When picking up a session cold, Claude's retrieval order, in order of cost:

1. Read the Headers already injected by the SessionStart hook (inside
   `<memcp-prior-sessions>`). Often enough.
2. If a Header points at a file or artifact, `Read` it directly.
3. `fetch_summary(summary_id)` for a richer body — **skip if
   `kind="autorecap"`**.
4. `search(query, projects=[...])` for semantic recall over Summaries beyond
   the recent window.
5. `fetch_chunks(query, projects=[...])` for turn-level Details by relevance,
   or `fetch_turns(session_id, last=N)` / `fetch_turns(session_id, start, end)`
   to pull specific turns by position (e.g. the last two turns of a session).

An Explore subagent starts cold (no SessionStart injection); its Step 0 is
`recent(projects=[<repo>])` to load Headers, then it follows the same ladder
from there.

This ladder is also delivered to Claude automatically as the memcp MCP
server's instructions string, so it's available to subagents that connect to
`mcp__memcp__*` and to anyone reading source code.

## Installation and Setup

### Prerequisites

- **[Alire](https://alire.ada.dev)** (`alr`) — the Ada package manager; it
  drives the whole build and provisions the GNAT toolchain and `gnatprove`.
- **[Rust](https://rustup.rs)** (`cargo`) — builds two staticlibs linked into
  the server: the `tiny_http` transport and the `candle` embedder.
- **`bash`, `curl`, `jq`, `base64`** — for the hooks and the model-fetch script.

`make` invokes `cargo` and vendors the pinned SQLite + sqlite-vec C sources
automatically (Alire pre-build actions) — you never run either by hand.

***Important:*** You must install the two hooks (see [Hooks](#hooks)) for
`memcp` to work correctly — `scripts/hooks/deploy.sh --local` registers the
server, writes the hook config and wires `settings.json` in one step.

### Building

```sh
git clone <this-repo> memcp && cd memcp
make model      # one-time: fetch the embedding weights into ~/.memcp/models
make            # build the whole crate DAG
```

`make model` downloads all-MiniLM-L6-v2 (weights + tokenizer + config) into
`~/.memcp/models/all-MiniLM-L6-v2`, where the server finds it with no config.
The embedder loads from disk — there are no runtime network calls. Override the
location with `MEMCP_MODEL_PATH`.

### Running

```sh
make run        # serves POST /mcp on 127.0.0.1:8786 (blocking)
```

Register the server and install the hooks in one step:

```sh
scripts/hooks/deploy.sh --local
```

Or register the server alone:

```sh
claude mcp add --transport http --scope user memcp http://127.0.0.1:8786/mcp
```

or add it by hand to `~/.claude.json` (MCP servers live there, **not** in
`~/.claude/settings.json`):

```json
{
  "mcpServers": {
    "memcp": { "type": "http", "url": "http://127.0.0.1:8786/mcp" }
  }
}
```

## Hooks

The hooks live in `scripts/hooks/` and are pure bash + curl + jq — they talk to
the server over the HTTP MCP surface, so they are independent of how the server
is built. Both exit 0 on every path — a memcp outage will never block Claude
Code startup or shutdown — and SessionStart prints a block naming any fault it
hit (see [below](#when-a-hook-cannot-do-its-job)).

Install on this machine, which wires straight to the checkout:

```sh
scripts/hooks/deploy.sh --local
```

Install on any other surface, which needs no checkout of its own:

```sh
scripts/hooks/deploy.sh HOST [HOST...]
```

Hosts are ssh destinations: names, users, ports and keys come from your ssh
configuration. A remote surface gets the four scripts copied into
`~/.claude/hooks/memcp/`, mints its own identity there, and has the MCP server
registered at the same `MEMCP_URL`. `curl`, `jq`, `base64` and `claude` must all
be present or nothing is wired; `--dry-run` reports without changing anything.

Both paths run `install.sh`, which writes `~/.memcp/hooks.env` — the
shell-sourceable config both hooks read — and prints the `settings.json` block
with the absolute paths filled in, should you prefer to wire it by hand into
`~/.claude/settings.json` (or per-project `.claude/settings.json`):

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [
        { "type": "command",
          "command": "/abs/path/to/memcp/scripts/hooks/session_start.sh" } ] } ],
    "SessionEnd": [
      { "hooks": [
        { "type": "command",
          "command": "/abs/path/to/memcp/scripts/hooks/session_end.sh" } ] } ]
  }
}
```

Re-run after every pull — `deploy.sh` for the surfaces that hold copies,
`install.sh` on its own if you wired this machine by hand. Either re-records the
hook digests, and neither re-rolls the surface identity it minted the first
time. A surface you miss says so on its next session start (see
[below](#when-a-surface-falls-behind)).

**SessionStart** derives the project key, emits it in a `<memcp-session>` block
for the model to use verbatim, and prints the most recent diary entries for
that project inside a `<memcp-prior-sessions>` block, which Claude picks up as
first-turn context. On `source=resume` and `source=compact` the diary listing
is skipped — the model already has that context — but the key is still injected,
because a compaction can drop it.

**SessionEnd** base64-encodes the transcript at `transcript_path` and uploads
it via the `upload_session` tool. The server writes the raw transcript to
`<db_parent>/sessions/<project>/<session_id>.jsonl`, splits it into verbatim
user/assistant turns (dropping thinking, tool calls, and tool results), and
stores one searchable chunk per turn. If no Header exists for that
`session_id` and the transcript contains a `※ recap` line, the server writes
a `kind="autorecap"` Header so the session is at least anchored in
`recent()`. A real `save()` from the model always takes precedence —
autorecap never overwrites a diary entry. Idempotent on
`(project, session_id)`: re-runs are no-ops.

### One project key per repository

Both hooks derive the key the same way, and SessionStart injects the result so
the model files its summary under exactly the key the transcript is uploaded
with. Resolved in order:

1. the upstream remote's repository name, with or without a trailing `.git`
2. else the directory name of the **main worktree**, from
   `git rev-parse --git-common-dir`
3. else `basename($cwd)`

So a subdirectory, a linked worktree and a detached HEAD all answer with the
same key as the top of the repository. Override per session with
`MEMCP_PROJECT`.

### When a hook cannot do its job

Every SessionStart failure path prints a block naming the fault and its remedy:

```
<memcp-hook-error hook="session_start" fault="server-unreachable">
The memcp server did not answer at http://127.0.0.1:8786/mcp, so no
prior-session context was injected and nothing will be recorded for this
session.
Remedy: Start the memcp server (make run), or point MEMCP_URL at the right endpoint.
Tell the user memcp is not recording this session, then continue.
</memcp-hook-error>
```

The exit status is 0 in every one of those cases. SessionEnd runs after the
agent has exited and so has nobody to tell; it logs to `MEMCP_HOOK_LOG`.

Both hooks report `<release>+<digest>` as their MCP `clientInfo.version`. The
digest is over the hook and `hook_common.sh` as installed; a hook whose runtime
digest differs from what `install.sh` recorded emits a `<memcp-hook-modified>`
block and keeps working.

### When a surface falls behind

The digest above compares a hook against what was installed on that surface.
The server compares the release each hook reports on `initialize` against the
one it shipped with, and on a mismatch SessionStart emits a block that prompts
the agent to alert the user that the hooks are stale and how to resolve the
problem. SessionEnd logs the same verdict to `MEMCP_HOOK_LOG`.

### Surface identity

`install.sh` mints a UUID and a label for the machine, once, and records the
host name as of that minting. A config that later turns up on a differently
named host was inherited — a cloned VM, a restored backup — rather than created
there, which is what keeps two machines from reporting as one surface.

## Tools

In-session tools (call from inside a Claude Code session via the MCP server):

| Tool | Purpose |
| --- | --- |
| `list_projects` | Enumerate known projects with diary counts and latest activity; use to discover scopes for `recent` / `search` |
| `recent` | N most recent Headers for the given projects (includes `kind`) |
| `save` | Write a `(diary line, structured summary)` pair; session-scoped upsert when `session_id` is provided, otherwise content-idempotent |
| `search` | Semantic search over saved Summaries (includes `kind` per hit) |
| `fetch_summary` | Retrieve a full Summary by id (includes `kind`) |
| `forget` | Delete a Summary, its diary line, and its embedding by summary id |

`save` has two modes:

- **Session-scoped upsert** (when `session_id` is provided): a second
  `save()` within the same session **replaces** that session's existing
  Header in place — same `summary_id` and `diary_id`, new
  body/headline/embedding/timestamp/kind. The response carries
  `already_existed: true, replaced: true`. This lets the model save at
  an early milestone and re-save when more lands without producing
  multiple Headers for one session. An identical retry (same content)
  is a no-op: `already_existed: true, replaced: false`. A real `save()`
  also promotes a prior `kind="autorecap"` row for the same session
  into a real `kind="diary"` entry.
- **Content-idempotent insert** (no `session_id`, or no prior row for
  that session): a retry with the same `(project, diary, summary)`
  returns the original ids with `already_existed: true, replaced: false`;
  otherwise it inserts fresh. Safe for the harness to retry when an
  encoding glitch drops a parameter on the first attempt.

`forget` is the escape hatch for removing throwaway entries.

Async capture (driven by the hooks, but callable directly):

| Tool | Purpose |
| --- | --- |
| `upload_session` | Persist a transcript to disk and embed its verbatim turns as chunks (one per user/assistant message); writes an `autorecap` Header if none exists |
| `fetch_chunks` | Semantic search over turns (the Details), by relevance |
| `fetch_turns` | Retrieve turns by position — `last=N`, or a `[start, end)` ordinal range; scoped to one `session_id` |

There is no tool that returns a raw Session transcript — that's by design (see
Vocabulary). If you genuinely need to inspect one, the files are at
`~/.memcp/sessions/<project>/<session_id>.jsonl`.

## Configuration

| Variable | Default | Read by |
| --- | --- | --- |
| `MEMCP_DB_PATH` | `~/.memcp/memcp.db` | server |
| `MEMCP_PORT` | `8786` | server |
| `MEMCP_URL` | `http://127.0.0.1:8786/mcp` | both hooks, scripts |
| `MEMCP_CONFIG` | `~/.memcp/hooks.env` | both hooks, `install.sh` |
| `MEMCP_PROJECT` | derived (see [above](#one-project-key-per-repository)) | both hooks |
| `MEMCP_RECENT_N` | `5` | `session_start.sh` |
| `MEMCP_HOOK_LOG` | `~/.claude/memcp-hook.log` | `session_end.sh` |
| `MEMCP_SURFACE_ID` | minted at install | both hooks |
| `MEMCP_SURFACE_LABEL` | host name at install | both hooks |
| `MEMCP_SURFACE_HOST` | host name at install | `install.sh` |

Everything below `MEMCP_URL` in that table is normally read from
`~/.memcp/hooks.env`, whose every line is `: "${VAR:=value}"` — so an
environment variable of the same name wins, with no precedence logic anywhere
in the hooks.

## Development

### Testing

```sh
make test          # unit drivers + self-contained smoke tests + the hook tests
make test-hooks    # just the hook tests: no Alire, no compiler
```

`-gnata` turns the SPARK `Pre`/`Post` along each path into executable checks,
so a contract violation fails the run.

| Driver | Exercises |
| --- | --- |
| `test_dispatch` | end-to-end `Dispatch`: the real json `Parse_Envelope` → routing |
| `test_store` | `Memcp.Store` write/read/list against an in-memory DB |
| `test_tools` | the 9 tools' JSON marshalling (embedder-off paths) |
| `test_spark_mcp` | the json-free `spark_mcp` core: Writer + Respond routing |
| `sqlite_smoke` | the `sqlite_vec_spark` binding: open → vec0 → KNN match |

The hooks are tested in the language they are written in, under `tests/hooks/`.
The server is stubbed by a `curl` shim first on `PATH`; one case dials a closed
port with the real `curl`.

| Script | Exercises |
| --- | --- |
| `test_derivation` | the project key over fixture repositories: remote, subdirectory, worktree, detached HEAD, no remote, no repository |
| `test_faults` | every SessionStart failure path — the block it emits and its exit status — and that SessionEnd uploads under the key SessionStart injected |
| `test_config` | config file, environment, and which of the two wins |
| `test_digest` | identity minted once and not re-rolled; a hook edited in place detected |

### Proof

```sh
make prove         # gnatprove -P memcp.gpr -j0 --level=2
make prove-mcp     # the same, for the reusable MCP core on its own
```

The whole `memcp` crate is `SPARK_Mode => On` and proves to **Silver** (Absence
of Runtime Errors) at `--level=2`, with no unproved and no justified checks.

`Spark_Mcp.Server` is generic, so its body is analysed only through an
instantiation. `make prove` reaches it through memcp's — the one over the JSON
parser — and `make prove-mcp` through a proof-only instantiation in
`crates/spark_mcp/prove/`, over a two-tool set and no parser. Both are CI gates,
so the core is proved as a reusable component and not only as memcp's copy of it.

### Trust surface

```sh
make trust         # list every site the proof does not cover
make trust-check   # the same set as a gate: any drift from the manifest exits 1
```

`scripts/trust-surface.txt` lists each one — code outside SPARK, assumptions the
prover takes on faith, suppressed warnings, and the foreign code behind the
bindings — with a justification. The build is warnings-as-errors (`-gnatwe`) and
`make prove-check` fails on any GNATprove warning in our sources, so a warning
can only be left standing by a suppression the manifest then has to name.
`gnat.adc` sets `pragma SPARK_Mode (On)` for the product sources,
so a unit outside SPARK has to say so at its own declaration. The gate runs first
in CI, ahead of the documentation, build and proof jobs. Contributions are not
expected to add to the manifest; see [CONTRIBUTING.md](CONTRIBUTING.md), and
[`docs/design/0014`](docs/design/0014-the-trust-surface.md) for the reasoning.

### API documentation

```sh
alr -n install gnatdoc_bin=26.0.0      # once; puts gnatdoc in ~/.alire/bin
export PATH="$HOME/.alire/bin:$PATH"

make docs          # generate docs/api/ + report undocumented entities
make docs-check    # the same run as a gate: any finding exits 1
```

`gnatdoc` is not part of the FSF toolchain and is not an `alire.toml`
dependency — it is a tool memcp never links against, so making it one would have
every build fetch a crate it never uses. The version is pinned because the set of
warnings *is* the gate.

Documentation style is `--style=gnat`: the doc block sits **below** the
declaration it describes, with `@param` / `@return` / `@enum` / `@formal`
mandatory. A block left *above* its declaration is silently ignored — the entity
is then reported as undocumented and nothing ever points at the orphaned comment.
`scripts/check-docs.sh` records those choices, drives all six project roots, and
CI runs `make docs-check` as the gate that both the build/test matrix and the
prover wait on.

## Security

memcp stores conversation transcripts, so the security posture matters. The
defaults are deliberately conservative: no network calls, no auth, no remote
storage, no telemetry. Everything lives on local disk under `~/.memcp/`, and
embeddings are computed in-process from weights loaded off disk.

What SPARK buys here: the entire `memcp` server is proved free of runtime errors
— no buffer overruns, no integer overflow, no null-dereference, no
use-after-free or memory leaks on the request path (see [Proof](#proof)). The
memory-management obligations that dominate a C server's attack surface are
discharged by the prover: request and response buffers are ownership pointers
allocated to exact size and provably freed exactly once. The trust boundary is
narrow and explicit — the three foreign bodies (tiny_http, candle, and
SQLite/sqlite-vec) are trusted across the FFI via `Pre`/`Post` contracts that
gnatprove checks at every Ada call site and that `-gnata` test builds execute.
`scripts/trust-surface.txt` enumerates that boundary in full, and CI gates on it
(see [Trust surface](#trust-surface)).

The server binds `127.0.0.1` only and speaks a single route (`POST /mcp`) with
no authentication: treat access to the port as read/write access to your memory
store, and do not expose it beyond loopback.

## License

Licensed under the [Apache License 2.0](LICENSE)
(`SPDX-License-Identifier: Apache-2.0`).
