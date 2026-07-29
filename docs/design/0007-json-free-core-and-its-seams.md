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
symmetry's sake: `Parse_Envelope` defaults to `Requests.No_Parser`, so the core
builds, proves and is drivable end to end with no JSON crate present at all.

## Text means the response's length is our obligation

A serializer would own overflow; concatenation into unconstrained `String`s
hands that back to us, and `tools/list` is the one response whose size grows
with the application. Its bound is carried on the recursive builder by two ghost
functions: `Item_Len_Bound`, one item, taking `Writer.Quoted`'s worst-case 6x
expansion from that function's own `Post`; and `Items_Len_Bound`, that summed
over the remaining tools with one comma per gap.

Neither carries a per-item cap, and that is the point. The bound is generic over
the tool set: it says the catalog fits *if* the sum fits `Result_Response`'s
precondition, and GNATprove discharges that concretely **at each
instantiation** — `crates/spark_mcp/prove/proof_harness.ads` for the crate's own
two-tool proof, and memcp's nine-tool instantiation in `src/main.adb` under
`make prove`. A tool with an enormous `inputSchema` therefore fails in the
application's proof run; the fix is that schema or `Max_Field`, never a cap
invented inside the core.

`Add_Sat` saturates purely so the ghost recursion is itself provable over an
arbitrarily large `Tool_Id`. It loosens nothing: for any catalog within
`Max_Field` it never saturates, so the concrete bound is identical to a plain
sum with only the unprovable overflow on `+` removed.

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
- `crates/spark_mcp/src/spark_mcp-server.adb` — the envelope and result
  builders; `Item_Len_Bound`, `Add_Sat`, `Items_Len_Bound`.
- `crates/spark_mcp/prove/proof_harness.ads`,
  `crates/spark_mcp/spark_mcp_prove.gpr` — the instantiation that gives the
  generic body its obligations when the crate is proved alone.
- `src/main.adb`, `Connect_To_Server` — the composition root: the only unit that
  supplies `Parse_Envelope`, joins `Dispatch` to `Serve`, and knows both
  ownership pointer types.
