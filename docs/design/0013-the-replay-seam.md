# 0013 — The replay seam, and what the harness owes it

Status: **Implemented** in `Memcp.Replay`; the driver that arms it lives outside
this repository.

Conformance against the Python server was checked by replaying a recorded run and
comparing responses **byte for byte**. Two things make that impossible for a live
server, and `Memcp.Replay` exists to neutralize exactly those two:

- **Embeddings.** The oracle's vectors came from
  `sentence-transformers`/torch; memcp's come from candle. They differ in the low
  bits, so any comparison of live embeddings needs a tolerance — and a tolerance
  is precisely what hides the divergences the comparison exists to find.
- **"Now".** A stored `created_at` is part of nearly every reply, so a live clock
  makes every response unique.

Rather than loosen the comparison, the recorded values are injected: the tool
layer draws its timestamps and its embeddings from data loaded per `tools/call`,
and everything downstream — including the dedup hash, which covers no timestamp,
and the vec0 blob, which is a reinterpretation of the injected vector — is then
bit-identical to the oracle's run. The unit is inert until `Enable` is called, so
production serving never touches it: `Memcp.Tools` consults
`Memcp.Replay.Enabled` at each injection point and otherwise takes the wall clock
and the live model.

## A miss is a conformance failure, not a fallback

`Lookup_Embedding` returns the zero vector when the text was not recorded. The
zero vector is not neutral — it skews every distance — so the fallback exists only
to keep the path total. What matters is that the miss is **counted**:
`Miss_Count` and `Last_Miss` are the harness's signal that the SPARK path
embedded a text the oracle did not, i.e. that the corpus is out of step with the
request stream. A run with a non-zero `Miss_Count` must be **failed**, not
compared; if the harness ignores it, a divergence in *which* texts get embedded
degrades silently to zero vectors and the byte comparison can still pass.
`Embed_One` also logs the miss (0012 records why that logging exists at all).

## Clocks are positional; embeddings are keyed

The two recorded channels are addressed differently, and the asymmetry is load
bearing:

- **Embeddings are looked up by exact text** and are not consumed. A repeated
  embedding of the same text within a call is a hit, and a text the oracle never
  embedded is a detectable miss.
- **Clocks are a FIFO queue** consumed positionally: each injection point takes
  the head if one remains and advances past it. There is no key, so nothing
  detects misalignment. If the SPARK path reads a different *number* of
  timestamps than the oracle wrote, or reads them in a different order, the rest
  of the call silently uses the wrong values and the harness sees only a diff it
  cannot attribute. Any change to how many clock values a tool consumes is
  therefore a change to the corpus format — and the count is not even fixed per
  tool: `upload_session` takes one clock for the session row and a second only if
  the transcript carries an `away_summary` recap *and* the session was not
  already stored.

`Begin_Call` clears both channels plus the miss counter, so the recorded data is
per-call and never leaks across requests.

## The harness is out of tree, so this spec is the contract

No unit in this repository calls `Enable`, `Add_Clock` or `Add_Embedding`: the
record/replay driver is external, and `src/memcp-replay.ads` is the whole
interface between them. The obligations on that driver, which nothing here can
enforce:

1. `Begin_Call` once per `tools/call`;
2. `Add_Clock` for that call's recorded timestamps, **in recorded order**;
3. `Add_Embedding` for every text the oracle embedded during that call;
4. fail the run when `Miss_Count > 0`, reporting `Last_Miss`.

Because the seam is dormant in-tree, it is also unexercised by `make test` and
`make prove` beyond absence of run-time errors. A change to the tool layer's
timestamp or embedding call pattern will not break any build — it will break the
external corpus, and only a replay run will say so.

## Where it lives

- `src/memcp-replay.ads` / `.adb` — the whole seam: the FIFO clock queue, the
  text-keyed embedding table, the miss counter.
- `src/memcp-tools.adb` — `Embed_One` and `Embedder_Available` (the embedding
  injection point and the gate that treats replay as an available embedder), plus
  the `Rep`/`Peek_Clock`/`Advance_Clock` blocks in `save` and `upload_session`.
