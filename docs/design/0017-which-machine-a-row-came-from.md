# 0017 — Which machine a row came from

Status: **Implemented** in `src/memcp-store.ads` (the `surfaces` table and the
`Surface` parameters), `src/memcp-tools.adb` (the `surface` argument) and
`scripts/hooks/hook_common.sh`; tested by `tests/src/test_store.adb`,
`tests/src/test_tools.adb`, `tests/hooks/test_config.sh` and
`tests/hooks/test_faults.sh`.

The corpus knew what was written and when, but not where from. Diagnosing a
machine whose uploads had silently stopped therefore meant reconstructing its
history by hand, because no row said which machine it belonged to.

## The value is a random UUID, not a signature

The original design signed a `project:surface:issued_at` token with an HMAC, so
that an agent could not manufacture one. `MEMCP_SURFACE_ID` already achieves
that: `install.sh` mints a UUID once per surface, and an agent running where no
hook ran has no way to produce it. Signing would additionally resist replaying
an id lifted from an old transcript, which is not a threat this corpus has.

What that buys is the absence of an HMAC implementation in SPARK, of a secret
that has to reach both a hook config and a server config and stay in agreement,
and of a TTL whose expiry becomes a failure mode of its own.

## One argument, carried by the model

The hook cannot hand the value to the server directly. Its own MCP connection
lives for the length of the handshake; the writes that need attributing come
from the client's connection, whose `clientInfo` is the client's. The only
channel between them is the context the hook injects, so the surface travels
the same route the project key already does: injected, passed verbatim,
recorded.

It travels as one `label:id` argument rather than two. The id is what cannot be
guessed; the label is what a diagnosis can print, and printing a UUID at a human
is not a diagnosis. A hook with no minted id injects an empty surface rather
than a bare label — the server must read absence, and a label alone is
something an agent could have invented.

## Fail soft, and say so

A write with no surface, or with one that does not split, still lands. Refusing
it would convert a silent gap in provenance into a lost summary, which is a
worse outcome than the one being fixed. The result carries a warning naming the
fault instead, so the failure reaches the user through the model on the turn it
happens.

## Migration has no version to hang on

The two columns are nullable and additive, so a database that has them and one
that does not are both readable by either build. Gating them on a
`schema_version` bump would therefore be bookkeeping with nothing behind it, and
would stop an older memcp from opening a migrated database for no gain.

`Add_Column` instead asks `pragma_table_info` whether the column is there and
adds it when it is not. That is idempotent on every open, needs no stored
version, and keeps a failing `ALTER` a real error rather than the expected
duplicate-column refusal that tolerating the error would hide.

## What the surfaces row holds

`surface_id` is the identity; `label`, `first_seen` and `last_seen` are what a
diagnosis reads. The label is refreshed on every write because it is config on
the surface and can legitimately change, while the id cannot. Summaries and
sessions both point at it: the failure being diagnosed is an asymmetry between
those two, so attributing only one of them would leave the comparison blind on
one side.
