# Proof caching in CI

`make prove` proves the whole `memcp` closure (`memcp` + `spark_mcp` +
`sqlite_vec_spark` + `candle_spark` + `json` + `sparklib`) to SPARK Silver in one
`gnatprove -P memcp.gpr -j0 --level=2` run — 5348 checks. Cold, on the GitHub
runner, that is **~23 minutes**. This note explains how we make CI proof cheap
without weakening the guarantee.

Three decisions, each load-bearing:

**We cache proof results.** GNATprove 16's file-based cache
(`--memcached-server=file:DIR`) stores prover verdicts on disk. CI restores it at
the start of the `prove` job, so a PR warm-starts from the cache `main` last
published and only *changed* VCs re-prove. Cold ~23 min collapses to the cost of
a warm confirming run (measured ~20x faster than cold) plus the handful of VCs a
PR actually touches.

**We do not shard.** Proof work is overwhelmingly in one project, so
`--no-subprojects` (which shards by subproject) only trims cold time from ~130s
to ~101s locally — a few minutes off 23 on the runner, not worth the machinery.
And naming units (`-u`/`--limit-*`) would transfer GNATprove's whole-project
completeness guarantee onto us: a silently-omitted unit becomes a false green
with no signal. For a proof-first project that trade is unacceptable. So we run
the single whole-closure command and let `-j0` use every core.

**We reprove cold on `main` daily.** A scheduled job re-proves `main` from an
*empty* cache to refresh it and to act as a poison guard — a cold run re-runs
every prover from scratch, so no corrupt cached verdict can survive it. It skips
itself when `main` has not moved in 24h: unchanged source means identical VC
keys, so the existing cache is already valid and re-proving would be wasted CI.

## Why trusting a cache hit is sound

The cache is **content-addressed**: each entry is keyed by the verification
condition (the Why3 goal formula) together with the prover identity and version.

- Any change to the code changes the VC, changes the key, and *misses* the cache
  — a stale verdict can never be silently reused, because "unchanged" is defined
  by the key.
- Flow analysis and VC generation are **never cached**; they re-run on every
  invocation. So data-dependency, initialization, and aliasing checks, and the
  set of VCs that must exist, are re-established every run. Only the SMT verdict
  for an unchanged VC is taken from the cache.
- The cache key includes the exact toolchain fingerprint (gnatprove 16.1.0 /
  why3 1.8.2), so a toolchain or prover bump misses every entry and forces a
  full cold re-prove.

That leaves exactly one thing to protect: the integrity of the cached verdicts
themselves. Two controls do it — PRs may **restore but never write** the cache
(a branch or fork PR cannot poison what `main` trusts), and the daily **cold**
reprove is the periodic ground truth that flushes everything.

## Where it lives

- `.github/workflows/ci.yml`, `prove` job — restores the cache, proves, and
  saves only on pushes to `main`.
- `.github/workflows/proof-cache-refresh.yml` — the daily cold reprove + cache
  purge, guarded on `main` having moved.

## Reproduce

```bash
CACHE=$(mktemp -d)
# Cold, then warm confirm (delete local proof state, keep the cache):
alr exec -- gnatprove -P memcp.gpr -j0 --level=2 --memcached-server=file:$CACHE
rm -rf obj/development/gnatprove
alr exec -- gnatprove -P memcp.gpr -j0 --level=2 --memcached-server=file:$CACHE
```
