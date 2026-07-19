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

**We do not shard.** Splitting proof by subproject or unit is not worth the
complexity, or the risk that we leave a unit out and get a false green (an
unsoundness). We run the single whole-closure command and let `-j0` use every
core.

**We reprove cold on `main` daily.** A scheduled job re-proves `main` from an
*empty* cache to refresh it and to act as a poison guard — a cold run re-runs
every prover from scratch, so no corrupt cached verdict can survive it. It skips
itself when `main` has not moved in 24h: unchanged source means identical VC
keys, so the existing cache is already valid and re-proving would be wasted CI.

## Where it lives

- `.github/workflows/prove.yml` — reusable workflow with the install / build /
  prove / cache logic; the cold-vs-warm difference is three inputs
  (`restore`, `purge`, `save`).
- `.github/workflows/ci.yml`, `prove` job — calls it warm: restore, and save
  only on pushes to `main`.
- `.github/workflows/proof-cache-refresh.yml` — calls it cold (purge + save)
  daily, guarded on `main` having moved.

## Reproduce

```bash
CACHE=$(mktemp -d)
# Cold, then warm confirm (delete local proof state, keep the cache):
alr exec -- gnatprove -P memcp.gpr -j0 --level=2 --memcached-server=file:$CACHE
rm -rf obj/development/gnatprove
alr exec -- gnatprove -P memcp.gpr -j0 --level=2 --memcached-server=file:$CACHE
```
