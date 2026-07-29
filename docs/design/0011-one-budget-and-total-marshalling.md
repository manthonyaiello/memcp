# 0011 — One budget, one builder, and totality upward

Status: **Implemented** across `Memcp.Text`, `Memcp.Json`, `Memcp.Tools`,
`Memcp.Extractor` and `Memcp.Store`.

0007 records why the core hands the response's length obligation back to us and
how the `tools/list` bound is discharged at each instantiation. This is the
application's half: every length cap in memcp is either `Spark_Mcp.Max_Field`
itself or derived from it, all loop-built strings go through one proved builder,
and the totality the dispatcher's contract assumes is a consequence of that
rather than an independent claim.

## Max_Field is the only budget

`Spark_Mcp.Max_Field = Natural'Last / 8` — the eighth being headroom for JSON
framing, the echoed id and `Writer.Quoted`'s worst-case 6x escaping. memcp
invents no numbers of its own on the request path:

- `Memcp.Text.Max_Len = Spark_Mcp.Max_Field` — the builder's cap;
- `Memcp.Extractor.Max_Transcript = Spark_Mcp.Max_Field` — which is what makes
  transcript line indexing overflow-free;
- `Memcp.Tools.Invoke`'s `Pre => Arguments'Length <= Spark_Mcp.Max_Field` — which
  is exactly what `Respond` guarantees when it calls the `Invoke` formal, and
  what lets a tool build a result straight out of `Arguments`.

So the budget is one constant to move, and none of these caps is an operational
size limit: at `Natural'Last / 8` they are overflow guards, and the degraded
paths below are formally reachable but practically dead.

## One builder holds the loop-index obligation

Appending to a string in a loop is the one place absence of run-time errors is
not free — a growing index can overflow. Rather than reason about that at each
marshalling site, the reasoning is confined to `Memcp.Text`: a SPARKlib character
vector with a `Dynamic_Predicate` bounding its length at `Max_Len`, whose `Add`
stops and raises `Overflowed` instead of exceeding it, and whose `Value` returns
an ordinary `String (1 .. Length)` that every consumer already bounds by
`Max_Field`.

That is why the marshalling layers — the tool serializers, the extractor's turn
assembly, the base64 decoder — never concatenate in a loop. A pathological
payload degrades to an error instead of faulting, and each caller chooses the
error: `Decode_Base64` refuses the upload outright (`Ok => False`, nothing
persisted), a tool renders a JSON error result.

## Totality is what the caps buy

`Memcp.Json.Q` is total by the same move: a string longer than `Max_Field` quotes
as `""` rather than tripping `Writer.Quoted`'s length precondition, so no caller
needs a precondition of its own. Because a whole tool result is already bounded
at `Max_Field`, that branch is unreachable in practice — which is why silently
emptying is acceptable there rather than a data-loss hazard.

The payoff is at the seam. `Memcp.Tools` holds no state, builds every reply
through the builder, and provably never raises; `Memcp.Envelope.Parse_Envelope`
maps invalid JSON to `Bad_Json` and well-formed-but-not-JSON-RPC to
`Bad_Request` instead of raising. `Spark_Mcp.Server.Dispatch` documents itself as
total — malformed input becomes a JSON-RPC error response, so a caller needs no
handler — and that claim is only true of *these* actuals: it holds because
GNATprove proves absence of run-time errors for the instantiated body together
with them. A tool that raised, that built a reply outside the builder, or an
envelope parser that let an exception escape, would each break the dispatcher's
proof rather than merely misbehave.

## Across the json seam, the pin is part of the proof

Three bodies — `Memcp.Json`, `Memcp.Envelope`, `Memcp.Extractor` — create, parse
and destroy json parsers, string buffers and value trees. Their leak-freedom and
termination are **proved, not justified**, and they are proved against contracts
the pinned json revision supplies: `Ownership` annotations with
`Post => not Has_Storage` on `Destroy`, and `Always_Terminates` across the public
API. A json bump that drops either leaves those checks unproved in memcp, and the
correct response is the pin, never a justification.

What the `pragma Warnings (GNATprove, Off, ...)` clauses in those bodies suppress
is something else entirely: flow *reports* about a handle that `Free` / `Destroy`
/ `Parse` nulls and nobody reads again — the same shape json-spark suppresses in
its own body. No check in memcp is justified away.

## The store's two caps, and main's one

`Memcp.Store` needs its own bounds because it generates SQL text and scans
candidates:

- **`Max_Filter_Terms = 1024`** bounds a dynamically built `IN (...)` clause.
  `Placeholders (K)` returns `2 * K - 1` characters and says so in its `Post`;
  the cap is what keeps that length and its indices clear of `Integer'Last`. A
  longer filter list is **refused** — an empty result with `Success` — never
  truncated, so a caller that relaxed or dropped the cap would reopen an
  overflow on `2 * K - 1`.
- **`Max_Search_Limit = 1000`** clamps a requested result count. The 5x
  over-fetch (0009) is applied to the *clamped* value, so this also bounds the
  candidate scan. A larger request is clamped rather than rejected.

`main` follows the same refuse-don't-truncate rule for configuration:
`Max_Env = 4096`, and a longer environment value is **ignored** in favour of the
default. That is what makes every path and port string derived in `main`
provably bounded — and why `Connect_To_Server` restates those bounds in its own
precondition, since facts an `Env` postcondition gives to constants with variable
input do not travel into a nested subprogram's proof context on their own.

## Where it lives

- `crates/spark_mcp/src/spark_mcp.ads`, `Max_Field` — the budget and its
  rationale.
- `src/memcp-text.ads` / `.adb` — the builder, `Max_Len`, `Overflowed`.
- `src/memcp-json.ads`, `Q` — the total quoting fallback.
- `src/memcp-tools.ads`, `Invoke`'s precondition; `src/memcp-tools.adb` — the
  builder-only reply construction.
- `src/memcp-extractor.ads`, `Max_Transcript`; `.adb`, `Decode_Base64` — refusal
  on overflow.
- `src/memcp-store.ads`, `Max_Filter_Terms` / `Max_Search_Limit`;
  `src/memcp-store.adb`, `Placeholders`.
- `src/main.adb`, `Max_Env` and `Connect_To_Server`'s precondition.
- `alire.toml`, the `json` pin — the commit whose ownership and termination
  contracts the three marshalling bodies prove against.
