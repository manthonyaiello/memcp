# 0006 — Parallel proof of projects with a shared GNATprove cache

Status: **Scoping / design** (exploration for [#6]). Not implemented.
Toolchain measured: FSF GNAT / GNATprove **16.1.0**, Why3 1.8.2, Alt-Ergo
2.6.1, cvc5 1.3.2, Z3 4.15.4.

[#6]: https://github.com/manthonyaiello/memcp/issues/6

## The idea, restated

> SPARK supports file-based memcached to share proof results from one session to
> another. If we split the proof across projects, we could still confirm that
> everything has been proved by running a final proof run — and if we shared the
> memcached cache from the per-project proofs, this should be fast.
> — [#6]

This document verifies what GNATprove 16 actually offers, measures it on this
repo, and gives an honest recommendation. **Short version: the shared cache is
real and dramatic (a warm confirming run is ~20x faster than a cold run), but
splitting proof *across the crate DAG* buys almost nothing here, because ~93% of
the work lives in a single project. The high-value, low-risk win is persisting
one file cache across CI runs; multi-runner sharding is a distant, optional
Phase 2.**

## 1. How proof runs today

Proof is driven through the `Makefile` (a thin wrapper over Alire):

```make
prove:        alr gnatprove -P memcp.gpr -j0 --level=2
prove-check:  scripts/check-proof.sh      # prove + gate against an allowlist
```

`scripts/check-proof.sh` runs the same command, then parses
`obj/development/gnatprove/gnatprove.out` and fails if any unproved check is not
covered by `scripts/proof-xfail.txt` (currently **empty** — the gate demands a
fully clean proof).

Key facts about the *scope* of that single run, confirmed from `gnatprove.out`:

- `-P memcp.gpr` analyzes the **entire dependency closure in one invocation** —
  not just the root crate. The summary covers units from `memcp` (the 9 tools +
  `Memcp_Store` + `main`), `spark_mcp`, `sqlite_vec_spark`, `candle_spark`, the
  git-pinned `json` library, and `sparklib`.
- `-j0` runs one prover process per core, scheduling **verification conditions
  (VCs) in parallel** across all cores.
- `--level=2` is SPARK "Silver" (AoRTE + assertions), the confidence target.

Measured on an 18-core Apple-silicon dev machine (`make prove`, cold):

| Metric | Value |
|---|---|
| Checks | **5348** (76% discharged by provers, 24% by flow) |
| Wall time | **130.8 s** |
| CPU (user) | 1107 s |
| Parallel speedup | 1107 / 130.8 ≈ **8.5x on 18 cores** (~47% efficiency) |

The 47% efficiency matters: `gnatprove -j0` is *already* an embarrassingly
parallel VC scheduler, but returns diminish well before the core count — VC
generation is less parallel than proving, and a handful of long-pole VCs (up to
~3 s each) bound the tail. So "more cores" is not free speed.

### Where the work actually is

Proving each project standalone (all subsets of the 5348):

| Project | Checks | Share |
|---|---:|---:|
| `candle_spark` | 12 | 0.2% |
| `sqlite_vec_spark` | 64 | 1.2% |
| `spark_mcp` (via `spark_mcp_prove.gpr`) | 297 | 5.6% |
| **`memcp` root closure (incl. `json`, `sparklib`)** | **~4975** | **~93%** |

This lopsidedness is the single most important fact for this design. The root
`memcp` crate pulls in `json` (heavy: tokenizer/parser/streams generics) and the
`sparklib` containers via instantiation, and contains `Memcp_Store`. It is one
GNATprove project and dominates everything else combined.

## 2. What GNATprove 16 actually provides

`gnatprove --help` on the installed 16.1.0 confirms **both** cache backends:

```
--memcached-server=host:portnumber   Specify a memcached instance ... for caching of proof results.
--memcached-server=file:directory    ... cache stored in the directory ... Best for CI integration.
```

So the flag exists and is supported on the exact toolchain this repo pins. The
`file:` form is what [#6] means by "file-based memcached": **no daemon**, just a
directory GNATprove reads/writes. The `host:port` form talks to a real
[memcached](https://memcached.org/) daemon (useful for a shared team/build
server, but adds an operational service). For CI, `file:` + the runner cache is
the right tool. (Ref: SPARK UG, *"Sharing Proof Results Via a Cache"*, linked
from the issue.)

### What is cached, and the safety property that follows

The cache stores **prover verdicts keyed by the content of each VC** — the Why3
task (the goal formula) together with the prover identity and version. It does
**not** cache flow analysis, VC generation, or the frontend.

Two consequences, both load-bearing:

1. **Correct sharing is automatic and content-addressed.** The same VC produced
   by two different runs — a per-project run and the whole-project run, or two
   CI runs on adjacent commits — hashes to the same key, so the second run gets
   a hit and skips the prover. Any semantic change to the code changes the VC,
   changes the key, and *misses* the cache (→ re-proved). A toolchain/prover
   version bump changes the key for every VC (→ full cold re-prove). This is why
   the mechanism is sound for unchanged code: **a stale entry cannot be silently
   reused, because "unchanged" is defined by the key.**
2. **A confirming run trusts the cache; it does not re-run the provers.** The
   fast confirm run *does* re-run the frontend, flow analysis, and VC
   generation (so it re-checks initialization, data-dependency, and aliasing,
   and it regenerates every VC), but for the SMT verdicts it trusts cache hits.
   Completeness (every VC present and marked proved) is genuinely re-established;
   **soundness of the SMT verdicts rests on cache integrity** (see §5).

### Measured: the confirming run

Same 18-core machine. Populate a fresh `file:` cache with one full cold run,
then delete GNATprove's local proof state and re-run against the warm cache:

| Run | Wall time | vs cold |
|---|---:|---:|
| Cold `-P memcp.gpr` (empty cache) | 130.8 s | 1x |
| **Warm confirming `-P memcp.gpr`** | **6.6 s** | **~20x** |

The warm cache held **14,887 entries / 67 MB** after the cold run (more entries
than checks: multiple provers/VCs per check). The 6.6 s is essentially "frontend
+ flow + VC generation + 14.9k cache lookups, zero prover calls." That is the
number that makes [#6]'s "final confirming run" cheap — and it is real.

## 3. Proposed architectures (and why one of them is a trap)

### Option A — split along the crate DAG (the literal reading of #6). Rejected.

Run `candle_spark`, `sqlite_vec_spark`, `spark_mcp`, and the `memcp` root as
separate parallel jobs, each into the shared cache, then a final `-P memcp.gpr`
confirm.

Why it fails here: per §1, the three binding crates are **~7% of the work
combined**. Splitting them off leaves ~93% on the `memcp`-root critical path.
By Amdahl, best-case wall-clock improvement ≈ **1.07x** — for four jobs' worth of
CI orchestration. Not worth it.

### Option B — persist ONE file cache across CI runs. Recommended (Phase 1).

Keep the single `-P memcp.gpr -j0` job exactly as today, but point it at a
`file:` cache that CI restores at the start and saves at the end:

```
alr gnatprove -P memcp.gpr -j0 --level=2 --memcached-server=file:$CACHE_DIR
```

On a PR that touches a few files, every unchanged VC is a cache hit, so proof
collapses toward the ~6.6 s confirm cost plus the re-prove cost of only the
changed VCs. This is *exactly* [#6]'s "share the cache from one session to
another," delivered without any DAG split. It is one flag, one `actions/cache`
step, and it degrades gracefully (a cold/missing cache just runs like today).

### Option C — shard the *big* project across runners + shared cache + confirm. Optional (Phase 2).

To parallelize the 93% you must split *within* the `memcp` project, not across
crates. GNATprove supports partitioning a single run with `--limit-subp`,
`--limit-line`, `--limit-lines=<file>`, and `--limit-region`. The pattern:

1. N shard jobs, each proving a disjoint slice of subprograms/units into the
   **same shared cache**.
2. A final `-P memcp.gpr` confirm job over the warm cache (~confirm cost)
   verifies *completeness* — that every VC is present and proved.

This can parallelize the dominant crate across runners, but it adds real
complexity: you must **balance** the slices (uneven slices just move the
bottleneck), keep the partition in sync as code changes, and move the cache
between jobs. It only pays off once cold proof time genuinely hurts CI.

## 4. CI sketch

Today (`.github/workflows/ci.yml`, post-[#3]): `build-test` (both platforms) and
`prove` (Linux) run as **sibling jobs with no `needs:` edge**, so proof already
overlaps build/test. Proof installs `gnatprove^16`, runs `make build`, then
`make prove-check` with `GNATPROVE_EXTRA=--timeout=10`.

### Phase 1 (Option B) — persisted cache, single job

```yaml
  prove:
    name: Prove (SPARK Silver, Linux)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup-alire
      - run: alr -n install gnatprove^16 && echo "$HOME/.alire/bin" >> "$GITHUB_PATH"
      - run: make build

      # Restore/save a file cache keyed to the EXACT toolchain fingerprint so a
      # gnatprove/prover bump can never reuse stale verdicts. restore-keys lets a
      # PR warm-start from the base branch's cache.
      - id: cache
        uses: actions/cache@v4
        with:
          path: .gnatprove-cache
          key: gnatprove-${{ runner.os }}-gp16.1.0-why3-1.8.2-${{ github.sha }}
          restore-keys: |
            gnatprove-${{ runner.os }}-gp16.1.0-why3-1.8.2-

      - run: mkdir -p .gnatprove-cache
      - env:
          GNATPROVE_EXTRA: --timeout=10 --memcached-server=file:${{ github.workspace }}/.gnatprove-cache
        run: make prove-check
```

`check-proof.sh` already appends `$GNATPROVE_EXTRA` verbatim to the gnatprove
command, so **no script change is needed** — this is a workflow-only change.
`actions/cache` saves on success automatically. The gate (`gnatprove.out`
parsing) is unaffected: a cache hit still reports the check as proved.

### Phase 2 (Option C) — sharded, only if Phase 1 is insufficient

```yaml
  prove-shard:
    strategy: { matrix: { shard: [0,1,2,3] } }
    steps:
      - ... setup, cache (shared restore-keys) ...
      - run: alr gnatprove -P memcp.gpr -j0 --level=2 \
               --limit-lines=shards/shard-${{ matrix.shard }}.txt \
               --memcached-server=file:$CACHE
  prove-confirm:
    needs: prove-shard
    steps:
      - ... restore the merged cache ...
      - run: make prove-check    # warm confirm over -P memcp.gpr, ~confirm cost
```

Complications to design out before building this: generating/maintaining the
per-shard line files, merging four shard caches into the confirm job (four
`actions/cache` paths, or a single cache updated serially, or artifact
passing), and load-balancing the slices.

## 5. Cost / benefit and risks (honest)

### Does `gnatprove -j0` already cover the need?

Largely, **within one machine, yes.** `-j0` already saturates all cores on the
prove runner. The only thing a multi-job split adds is *cores beyond one
runner* — and that helps only if the work partitions evenly, which here it does
not (§1). So the "parallel across projects" half of [#6] is mostly a non-starter
for this repo's shape. The *cache* half is the valuable part.

### Estimated wall-clock benefit

- **Confirming / warm run: measured ~20x** (130.8 s → 6.6 s) on the dev machine.
- **CI, Phase 1 (persisted cache):** the cold run is not directly measured on a
  hosted runner; extrapolating from 1107 s of prover CPU on a ~4-vCPU
  `ubuntu-latest`, cold proof is roughly **5–8 minutes**. With a warm cache and a
  small PR diff it should fall toward **tens of seconds** (confirm cost + a few
  re-proved VCs). This is the real prize.
- **CI, Phase 2 (sharding a cold cache):** bounded by the largest shard and by
  the ~47% parallel-efficiency ceiling; a well-balanced 4-shard split might take
  cold proof from ~5–8 min to ~2–3 min. Modest, and only on cold caches — which
  Phase 1 already makes rare.

### Risks and operational cost

1. **Cache integrity = soundness (the big one).** A confirming run trusts cache
   hits instead of re-running provers (§2). A poisoned or corrupted cache entry
   claiming a VC is "proved" would produce a **false green**. Mitigations: (a)
   only ever populate the cache from trusted jobs on the same repo/commit/
   toolchain; (b) key the cache to an exact toolchain+prover fingerprint so a
   bump forces a cold re-prove; (c) be aware that `actions/cache` is writable by
   any branch's workflow (fork PRs cannot write base caches, but repo branches
   can) — for a single-maintainer repo this is low risk, but it is the reason
   *not* to trust a cache from an untrusted source. For maximum assurance, a
   periodic scheduled job can run proof **cold** (no cache) as an independent
   check.
2. **Cache growth / staleness.** AdaCore's docs note the `file:` directory
   "will tend to grow over time and should be deleted and recreated from time to
   time." Bake periodic invalidation into the cache key (e.g. a monthly epoch
   token) or a scheduled cache purge.
3. **Correctness of "confirm."** Completeness is genuinely re-established every
   run (flow analysis + VC generation are not cached, and any code change misses
   the relevant keys). The residual gap is purely the trust in cached SMT
   verdicts, addressed by (1).
4. **`host:port` memcached** would add a daemon to run/persist/secure. The
   `file:` backend avoids that entirely; there is no reason to run a memcached
   server for this repo.
5. **Complexity vs. payoff (Phase 2).** Shard files, cache merging, and
   balancing are ongoing maintenance for a modest, cold-cache-only win.

## 6. Recommendation — phased

- **Phase 1 — do it (low risk, high value).** Add opt-in
  `--memcached-server=file:` to the existing single `prove` job and persist the
  directory with `actions/cache`, keyed to the exact toolchain fingerprint with
  periodic invalidation. Keep `-j0` and the single whole-closure run. This
  delivers [#6]'s "share the cache so the confirming run is fast" directly, is a
  workflow-only change (no `check-proof.sh` edit), and degrades gracefully.
  Consider a weekly scheduled **cold** proof run as an integrity backstop.
- **Phase 2 — prototype-first, defer.** Only if cold proof time becomes a real
  CI pain point, prototype sharding the `memcp` project via `--limit-lines` into
  the shared cache with a final confirm job. Measure a balanced 4-shard split
  before committing to the maintenance burden.
- **Do not — crate-DAG split (Option A).** ~93% of the work is in one project;
  splitting by crate yields ≈1.07x. Not worth the orchestration.

### Appendix — reproducing the measurements

```bash
CACHE=$(mktemp -d)
# Cold (anchor):
rm -rf obj/development/gnatprove
alr exec -- gnatprove -P memcp.gpr -j0 --level=2 --memcached-server=file:$CACHE
# Warm confirm (delete local proof state, keep the cache):
rm -rf obj/development/gnatprove
alr exec -- gnatprove -P memcp.gpr -j0 --level=2 --memcached-server=file:$CACHE
# Per-crate subsets:
alr exec -- gnatprove -P crates/candle_spark/candle_spark.gpr        -j0 --level=2
alr exec -- gnatprove -P crates/sqlite_vec_spark/sqlite_vec_spark.gpr -j0 --level=2
alr exec -- gnatprove -P crates/spark_mcp/spark_mcp_prove.gpr        -j0 --level=2
```

Numbers in this doc are from a single 18-core Apple-silicon run; treat them as
orders of magnitude, not benchmarks. Hosted-runner figures are extrapolated and
should be confirmed by the Phase 1 rollout itself.
