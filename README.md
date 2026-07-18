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
- **`bash`, `curl`, `jq`** — for the hooks and the model-fetch script.

`make` invokes `cargo` and vendors the pinned SQLite + sqlite-vec C sources
automatically (Alire pre-build actions) — you never run either by hand.

***Important:*** You must install the two hooks (see [Hooks](#hooks)) for
`memcp` to work correctly.

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

Register the server with Claude Code in `~/.claude/settings.json`:

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
is built. All failures are logged to stderr and the script exits 0 — a memcp
outage will never block Claude Code startup or shutdown.

Add to `~/.claude/settings.json` (or per-project `.claude/settings.json`),
substituting the absolute path to your checkout:

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

**SessionStart** reads the most recent diary entries for the current project
and prints them inside a `<memcp-prior-sessions>` block, which Claude picks up
as first-turn context. It only fires on `source=startup` or `source=clear`;
`resume` and `compact` skip, because the model already has prior context.

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

Project name defaults to `basename($cwd)` from the hook payload; override per
session with the `MEMCP_PROJECT` env var.

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
| `MEMCP_PROJECT` | `basename($cwd)` | both hooks |
| `MEMCP_RECENT_N` | `5` | `session_start.sh` |

## Development

### Testing

```sh
make test          # unit drivers + self-contained smoke tests
```

The drivers are dependency-light (no AUnit, so they run the moment the crates
build); `-gnata` turns the SPARK `Pre`/`Post` along each path into executable
checks, so a contract violation fails the run.

| Driver | Exercises |
| --- | --- |
| `test_dispatch` | end-to-end `Dispatch`: the real json `Parse_Envelope` → routing |
| `test_store` | `Memcp_Store` write/read/list against an in-memory DB |
| `test_tools` | the 9 tools' JSON marshalling (embedder-off paths) |
| `test_spark_mcp` | the json-free `spark_mcp` core: Writer + Respond routing |
| `sqlite_smoke` | the `sqlite_vec_spark` binding: open → vec0 → KNN match |

### Proof

```sh
make prove         # gnatprove -P memcp.gpr -j0 --level=2
```

The whole `memcp` crate is `SPARK_Mode => On` and proves to **Silver** (Absence
of Runtime Errors) at `--level=2`: **0 unproved, 0 justified in memcp's own
code** (5211 checks). The two residual `medium` messages you will see both come
from **SPARKlib's floating-point lemmas**
(`spark-lemmas-floating_point_arithmetic.ads`), not from this project — they
need the COLIBRI solver, which the default prover set does not ship. Expected,
and outside our code.

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

The server binds `127.0.0.1` only and speaks a single route (`POST /mcp`) with
no authentication: treat access to the port as read/write access to your memory
store, and do not expose it beyond loopback.

## License

Licensed under the [Apache License 2.0](LICENSE)
(`SPDX-License-Identifier: Apache-2.0`).
