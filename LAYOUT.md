# Project layout

SPARK (Ada) reimplementation of **memcp** (a progressive-disclosure MCP memory
server) for provability. Python source of truth: `../memcp`.

## Organization

An Alire workspace whose **root is the composition-root crate** (`memcp`):
`alire.toml` + `memcp.gpr` sit at the top level, so AdaCore IDEs open the repo
directly. The reusable library crates live under `crates/`.

```
spark-memcp/
├── alire.toml  memcp.gpr  gnat.adc     the memcp bin crate, at the root
├── src/                                the 9 concrete tools + Store + main
├── tests/                              memcp_tests.gpr + unit drivers
├── crates/
│   ├── spark_mcp/                      MCP core + the HTTP transport it ships with
│   │   ├── src/spark_mcp-*.ads         Spark_Mcp.Server / .Requests / .Writer / .Tools
│   │   ├── src/spark_mcp-http-*.ads    Spark_Mcp.Http[.Serve/.Bridge] (tiny_http)
│   │   └── rust/                       tiny_http staticlib (built by a cargo pre-build)
│   ├── sqlite_vec_spark/               binding to SQLite3 + sqlite-vec (C)
│   └── candle_spark/                   binding to candle (Rust): Embed(text) → [384]
└── models/                             provisioned embedding weights (git-ignored)
```

## Crates

| Crate | Role |
|---|---|
| `memcp` (root) | Composition root: wires the 9 concrete tools into the core and the core into the transport; owns the Store + Embedder singletons and `main`. The only crate that depends on `json`. |
| `crates/spark_mcp` | Reusable MCP server. `Spark_Mcp.Server` is the transport-agnostic, json-free, provable core; the frozen seam is `Spark_Mcp.Server.Dispatch (String → Response_Ptr)`. `Spark_Mcp.Http` is the concrete HTTP transport it ships with — MCP-shaped (one route, `POST /mcp`), so it lives here rather than as a peer crate. |
| `crates/sqlite_vec_spark` | Binding to SQLite3 + sqlite-vec (vendored C amalgamations). Storage + vector-search primitives. |
| `crates/candle_spark` | Binding to candle (Rust staticlib). Single-embed path: `Embed(text) → [384]`. |

The binding crates are `SPARK_Mode => On`: the Ada wrappers are proven, the
foreign body (C/Rust across the FFI) is trusted via `Pre`/`Post`.

## Two things that look like dependencies but aren't

- **`json`** is a separate crate ([manthonyaiello/json-spark], the SPARK Silver
  fork of json-ada), git-pinned to a fixed commit from the root `alire.toml`, so
  `alr build` fetches it automatically — no sibling checkout needed. Only `memcp`
  depends on it (it supplies `Spark_Mcp.Server`'s `Parse_Envelope` formal), so
  the core stays json-free.

  [manthonyaiello/json-spark]: https://github.com/manthonyaiello/json-spark
- **`Spark_Mcp.Http`** carries a *build* dependency (a cargo pre-build for the
  `tiny_http` staticlib + linker options in `spark_mcp.gpr`), but **not** an Ada
  crate dependency: `Spark_Mcp.Server` `with`s nothing, and `gnatprove` neither
  runs the cargo action nor links — so the core proves independently.
