# 0022 — The stack is outside the proof

Status: **Implemented** in `crates/spark_mcp/src/spark_mcp-writer.ad?`
(`Escape`, `Quoted`, `Concat`), `crates/spark_mcp/src/spark_mcp-server.adb`
(the response envelope), `src/memcp-store.adb` (the row constructors),
`src/memcp-extractor.adb`, `src/memcp-tools.adb`, `src/memcp-json.adb`,
`src/memcp-replay.adb`, `src/main.adb` (the handler that reports a breach), and
the json pin. Refs #96, manthonyaiello/json-spark#19.

Silver proves the absence of run-time errors, except one: `Storage_Error` is not
covered by SPARK analysis (SPARK User's Guide §8.1, and §8.3.5 *Dealing with
Storage_Error*). A local `String (1 .. Text'Length)` proves: its bounds are valid
for every `Text` the types admit. Whether the frame that holds it fits the stack
the process actually has is a separate claim, and nothing here checked it.

It failed. A 40 MB transcript is a 53 MB `upload_session` request, under the
64 MiB request cap. The json crate decoded its base64 field into a local the size
of the field, on an 8 MiB main-thread stack. The server died with the
connection still open, and its handler reported a transport error.

## The rule

A value whose size follows the input is never held in the caller's frame. It is
either owned through an access value, or returned by a function. It is never a
local, an aggregate passed as an actual, a concatenation, or a conditional
expression evaluated in place.

What puts storage where was measured, not assumed, against GNAT 16 at `-Og`
(the development profile the server is built in) and `-O2`, with 64 MiB values
on an 8 MiB stack:

| Shape | Lands on |
|---|---|
| constrained local sized by the input | primary stack |
| aggregate passed as an actual parameter | primary stack |
| `&` with an operand of dynamic length | primary stack at `-Og`, not at `-O2` |
| `X : constant String := (if C then A else B)` | primary stack |
| function result of an unconstrained type, including an expression function returning an aggregate | secondary stack |
| extended return object, aggregate-initialized or not | secondary stack |
| `new T'(aggregate)`, `new String'(slice)` | heap |

Concatenation depending on the optimization level is the reason for
`Writer.Concat`: a result that is safe only in a release build is a defect in
the build the server actually runs.

Hence the constructors: `To_Chunk`, `To_Summary_Hit` and the others in the
Store body, `To_Turn`, `To_Chunk_Input`, `To_Name`. Each one is an expression
function wrapping the aggregate that used to be passed straight to `Append`, so
the prover still sees the aggregate. `Escape` builds in a heap buffer it frees
on return. The json crate's `Unescape` does the same.

## The secondary stack is an assumption too

The full runtime grows the secondary stack in heap-allocated chunks, which is
what makes "returned by a function" safe at any size. A restricted runtime gives
it a fixed size, and GNATstack does not analyse it. So the rule moves the
assumption from "the primary stack is big enough" to "the secondary stack is
heap-backed". That holds for the runtime memcp ships on, and nothing here
checks it either.

## What is left, and how to see it

Compiling with `-fstack-usage` writes a `.su` file next to each object, and
marks every function whose frame size is not static as `dynamic`. That listing
is the inventory: a frame not marked `dynamic` holds nothing sized by the
input.

```sh
alr exec -- gprbuild -q -f -c -P memcp.gpr -cargs:Ada -fstack-usage
find . -name '*.su' | xargs cat | awk -F'\t' '$3 ~ /dynamic/'
```

The frames still marked `dynamic` are each sized by something other than a
payload:

| Frame | Sized by |
|---|---|
| `Main`, `Connect_To_Server` | environment values, capped at `Max_Env` |
| `Store.Now_Iso`, `Placeholders`, `Add_Column`, `Write_Session_File`, `Fetch_Turns` | timestamps, SQL text, paths |
| `Store.Save`, `Save_Session`, `Save_Autorecap` | a timestamp, the client's `created_at` when given |
| `Extractor.Process_Line` | a transcript line's `type` and `role` |
| `Tools.Warning_Member`, `Ser_Faults` | the `surface` argument |
| `Server.Respond` | `initialize`'s `_meta`, from the client's name and version |
| `Server.Dispatch` | the constant error envelopes |
| `Server.Tools_List_Result`, `Items_From`, `Item` | the tool set, capped at `Max_Tool_Item` |
| `Sqlite_Vec_Spark.Open`, `Execute` | the database path and SQL text |
| SPARKlib `Unbounded_Vectors.Insert` | one pointer per element inserted; the element goes on the heap |
| json `Append_Image` | not called |

These are bounded in practice, not by type. A client that sent a 20 MB tool name
or surface label could still exhaust the stack. memcp listens on 127.0.0.1 for
one user, and a payload, which is what real sessions are made of, no longer can.

A test does not replace this listing. A frame larger than the stack is not
guaranteed to fault. Whether it hits a guard page or lands in other mapped
memory depends on the layout of the process. The 16 MiB tests here pass with
the Store row aggregate put back, while the same build of the server dies on
the same turn. The listing has no such dependence on layout.

## When the assumption fails anyway

`Connect_To_Server` handles `Storage_Error`: it logs the failure and exits with
a failure status, and launchd restarts the server. SPARK, which assumes the
exception cannot occur, reports that handler as unreachable. The suppression
that keeps it is the trust-surface entry for this ADR: it names, at the one
point where a breach is caught, the property the proof does not establish.
