# 0007 — A JSON-library-free core, and the shape of its seams

Status: **Implemented** in `crates/spark_mcp`.

`spark_mcp` `with`s no JSON library. Inbound decoding is a generic formal the
composition root supplies; outbound JSON is built as text. `LAYOUT.md` records
the dependency fact — this note records why the seams have the shape they do,
and what stops working if they change.

## Outbound is a writer, not a value tree

json-ada, and our SPARK fork of it, is parse-oriented: it reads value trees and
re-serializes them, and has no first-class API for *constructing* fresh values.
Every byte this server emits is freshly built — no response is a transformation
of the request — so a value tree buys nothing and would pull the whole library
into the core.

So the outbound path is `Spark_Mcp.Writer`: RFC 8259 string escaping and
quoting, and nothing else. Above it, every JSON-RPC envelope and every `result`
object in `Spark_Mcp.Server` is a concatenation of literals and `Writer.Quoted`
calls. Escaping is the one piece of genuinely fiddly logic in the path, and it
is where the proof effort goes.

The seam is therefore **deliberately asymmetric** — a parser in, a writer out.
It is not an oversight to be tidied up by giving the core a JSON dependency for
symmetry's sake: `Parse_Envelope` is a generic formal with **no default**, so no
unit in the crate names a JSON library, and the crate builds, proves and is
driven end to end with no JSON crate present at all.

No default, specifically. `Requests` could carry a null parser reporting
`Unimplemented` for instantiations to inherit, and the crate's own two — the
proof harness and the test driver — are the only things that would ever inherit
it, because both drive `Respond` directly and neither has a request to decode.
A shipped entity whose only callers are harnesses is code no product runs, and
this one costs more than its footprint: a parser that ignores its argument needs
a `pragma Unreferenced`, which lands in `scripts/trust-surface.txt` and is read
as budget the *shipped* library spends. Each harness declaring its own trivial
expression function is more verbose at the instantiation and buys back both. The
same reasoning is why `Client_Meta` has no default either.

## Text means the response's length is our obligation

A serializer would own overflow; concatenation into unconstrained `String`s
hands that back to us, and `tools/list` is the one response whose size grows
with the application. Two static caps in `Spark_Mcp.Server` carry its bound:
`Max_Tool_Item`, the length of one item — the name and description at
`Writer.Quoted`'s worst-case 6x expansion, the `inputSchema` verbatim, and the
object's framing — and `Max_Tools`, the size of `Tool_Id`.

The per-item cap is where an application's tool set is actually checked, and it
is checked **at each instantiation** — `crates/spark_mcp/prove/proof_harness.ads`
for the crate's own two-tool proof, and memcp's instantiation in `src/main.adb`
under `make prove`. GNATprove unfolds that tool's `Name`, `Description` and
`Input_Schema` and discharges `Item`'s postcondition against the ceiling, one
tool at a time. A tool with an enormous `inputSchema` therefore still fails in
the application's proof run; the fix is that schema, or `Max_Tool_Item`.

What the caps buy is that the *listing's* bound does not depend on what any
accessor returns. `Items_Len_Bound` is `Remaining (T) * (Max_Tool_Item + 1)`, so
the recursive builder's postcondition is an induction with one step — the
ceiling, a comma, the tail's bound — and the response's own range check follows
from a static figure. Neither cost grows with the tool set.

`Item` is a plain function and not an expression function for the same reason:
an expression function's text is visible wherever it is called, so the recursion
would drag the accessors' case expressions into every obligation of its own. Its
postcondition states `'First` as well as the length, `Item` being the left
operand of a concatenation, which takes its lower bound from there.

A bound stated as the sum of the items does grow, and that is why this one is
not: each further tool adds a level of the accumulation to unfold and a concrete
length to add in, all inside a single obligation, so the catalog reaches a size
past which no timeout helps.

`Max_Tools` is what makes the product safe to state at all, `Tool_Id` being a
formal discrete type an instantiation could satisfy with one whose positions run
to `Integer'Last`. A `pragma Compile_Time_Error` on the generic rejects an
oversized tool set, so that limit is a build failure naming the cap rather than
an unproved check.

## Both seams are formal procedures

The tool seam (`Spark_Mcp.Server`'s `Invoke`) and the transport's handler seam
(`Spark_Mcp.Http.Serve`'s `On_Request`) are generic formal **procedures**. Two
things follow, and both are load-bearing:

- **Effects stay visible where the call is.** Dispatching a request mutates
  application state — memcp's `save` and `forget` write the store. GNATprove
  re-analyses the generic body at each instantiation, so the actual's `Global`
  is in scope exactly at the call site, inside a body that is itself proved.
  An access-to-subprogram formal would hide the callee from flow analysis
  there.
- **A function could not express it.** SPARK functions are side-effect free,
  and the toolchain accepts `Side_Effects` only on a plain function
  declaration, not on a generic formal; even granted it, a function could not
  size the unconstrained result. The procedure shape is not a preference — the
  function seam does not exist to be chosen.

## The transport knows nothing about MCP

`Spark_Mcp.Http` and its child `Serve` sit under `Spark_Mcp` for packaging
only: the transport is MCP-*shaped* (a single route, `POST /mcp`), so it ships
in this crate rather than as a peer. Nothing in it is MCP-*specific* —
`Port_Number` and `Message_Ptr` are transport vocabulary, the handler is an
abstract seam, and tying that seam to `Spark_Mcp.Server.Dispatch` is the
composition root's job. `src/main.adb` is the only place the two ever meet.

The FFI runs one way, and that is what makes the flow-analysis claim above
complete rather than nearly complete: because no Ada subprogram is ever called
from Rust, there are no exported symbols, no access-to-subprogram values
crossing the boundary, and no callback whose caller SPARK cannot see. A
Rust→Ada callback would not merely extend the FFI, it would break that
argument.

`Serve`'s only exit is `Transport_Error` (port unbindable, or the accept loop
died), and its `Exceptional_Cases` makes that a discharged obligation rather
than documented folklore.

## Where it lives

- `crates/spark_mcp/src/spark_mcp-writer.ads` — the whole outbound JSON
  dependency, such as it is.
- `crates/spark_mcp/src/spark_mcp-server.ads` — `Max_Tool_Item`, `Max_Tools`,
  and the `Compile_Time_Error` that enforces the second.
- `crates/spark_mcp/src/spark_mcp-server.adb` — the envelope and result
  builders; `Item`'s ceiling, `Remaining` and `Items_Len_Bound`.
- `crates/spark_mcp/prove/proof_harness.ads`,
  `crates/spark_mcp/spark_mcp_prove.gpr` — the instantiation that gives the
  generic body its obligations when the crate is proved alone.
- `src/main.adb`, `Connect_To_Server` — the composition root: the only shipped
  unit that supplies `Parse_Envelope`, joins `Dispatch` to `Serve`, and knows
  both ownership pointer types.
