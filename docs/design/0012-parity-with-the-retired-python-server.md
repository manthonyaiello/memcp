# 0012 — What still has to match the Python server

Status: **Implemented**; the reference implementation is no longer in this repo.

memcp is a reimplementation of a Python MCP memory server (`server.py` +
`store.py`). That source is gone, so nothing in the tree can be diffed against it
any more — but three classes of obligation it imposed are still live, pinned by
artifacts outside the code: **databases and transcripts already on disk**,
**clients bound to the wire surface**, and a short list of **deliberate
divergences** that must not be "fixed" back. Nothing below is a free choice.

## Frozen because bytes already exist in it

- **The dedup hash.** SHA-256, hex, over project, diary body and summary body,
  **NUL-delimited** so field boundaries cannot collide (`"ab" + "c"` against
  `"a" + "bc"`). It is stored in `summaries.dedup_hash` and indexed, and
  databases seeded by the Python store — including the conformance corpus —
  hold hashes built exactly this way. Change the digest or the delimiting and
  `save` stops recognising its own retries against any pre-existing database.
- **`created_at`.** ISO-8601 with the local UTC offset, e.g.
  `2026-07-13T14:12:13-04:00`, sub-second precision dropped. It is what the
  Python store wrote, and every date window and `DESC` index compares these
  strings **lexically** (0009), so a `Z` suffix or a different offset format
  would mis-sort against rows already stored. The clock's own precision does not
  matter: the only path needing determinism injects `Created_At` instead (0013).
- **The embedding blob.** The bytes `struct.pack('384f', ...)` produces on this
  machine: packed little-endian float32, which is what `sqlite-vec` stores in a
  `vec0` column and compares against. `To_Blob` is a reinterpretation, not a
  serializer, so parity here is the machine's float layout — and stored vectors
  from either implementation are interchangeable only for that reason.
- **Raw transcripts on disk.** `<db_parent>/sessions/<project>/<session_id>.jsonl`,
  written with `Stream_IO` one byte per `Character` so UTF-8 passes through
  unaltered. `Parent_Dir` reproduces `pathlib`'s `.parent`, edge cases included:
  `/a/b/x` → `/a/b`, `/x` → `/`, and anything with no separator (`:memory:`
  included) → `.`. Those three cases *are* the specification, and they are what
  puts new transcripts in the same directories as the old ones.
- **The stored turn text.** A chunk body is `[<role>] ` followed by the message's
  text parts joined by a blank line, each part stripped, non-text parts
  (thinking, tool use) dropped. That shape is in `chunks.body` for every session
  already uploaded and is echoed verbatim by `fetch_turns` and `fetch_chunks`.

## Frozen because clients are bound to it

The nine tool names, their descriptions, their `inputSchema` objects and the
`initialize` instructions text were transcribed from the Python server rather
than designed here, and each tool's rendered reply matches — field for field —
what the tool of the same name returned. A tool added since has no counterpart
to match and no obligation here: the frozen set is the nine that were inherited. `MEMCP_DB_PATH`, `MEMCP_PORT` and
`MEMCP_MODEL_PATH` are the same kind of inherited surface: renaming one breaks
deployed hook scripts and client configuration, not just a test.

The acceptance rules on the way in are inherited too, and are stricter than they
look:

- **Base64 is decoded strictly**, as `b64decode(validate=True)` was: standard
  alphabet only, a whole number of 4-character groups *including* padding, and
  padding only in the final group. A stray character or missing padding fails
  `upload_session` with invalid-params. Accepting it leniently would be a
  behaviour change, not a bug fix.
- **The decoded bytes must be well-formed UTF-8** per RFC 3629 — no overlong
  forms, no surrogates `U+D800..DFFF`, nothing above `U+10FFFF` — which is the
  acceptance `bytes.decode("utf-8")` enforced. The check lives at the decode
  boundary, not at any reader, because the store must never hold bytes that
  `fetch_turns` / `fetch_chunks` would later hand back as mojibake.
- **`Strip` removes the whole ASCII whitespace set**, as `str.strip()` does.
  `Ada.Strings.Fixed.Trim`'s default drops spaces only, which would leave CR/LF
  on every extracted turn and recap — silently changing stored text on any CRLF
  transcript.
- **`Valid_Timestamp` accepts what `datetime.fromisoformat` accepted** for these
  values, not the ISO-8601 grammar: `YYYY-MM-DD`, optionally a `T`/space
  separator then `HH:MM` and beyond. The reference parser, not the standard, is
  the authority any widening or tightening has to be measured against. A
  malformed `since` / `until` is rejected as invalid-params rather than silently
  mis-filtering the lexical `created_at` comparison.

## Divergences, on purpose

- **`save` salvage is narrower.** The reference `_salvage_leaked_params` split a
  value at a leaked `<parameter>` boundary unconditionally. `Salvage` splits only
  when the boundary's **named sibling slot is actually empty** — a leak's
  defining signature is that the swallowed sibling arrives missing. With both
  fields supplied, a boundary-looking sequence is legitimate content (a memory
  quoting this very format), and the reference would have dropped everything
  after it. The narrowing changes only the both-fields-present case, never a
  genuine leak, and all three cases are pinned by regressions in
  `tests/src/test_tools.adb`. The scanner itself is a literal, case-folded
  matcher — SPARK has no regex — whose tolerated shapes (optional `ns:` prefix,
  either quote, whitespace around the tag internals) are those of the two named
  regexes it replaces.
- **Failures the reference discarded are logged.** `Memcp.Log` exists for the
  two failures no layer can recover at the point they occur: a `ROLLBACK` that
  itself fails, which can leave the database mid-transaction, and a replay
  embedding miss (0013). The Python source was silent at both points. The extra
  output on standard output — free for diagnostics, since the transport is HTTP —
  is deliberate and should not be trimmed as noise for parity's sake.

## Where it lives

- `src/memcp-store.adb` — `Dedup_Hash`, `Now_Iso`, `Parent_Dir`,
  `Write_Session_File`, `To_Blob`.
- `src/memcp-extractor.adb` — `Decode_Base64`, `Valid_Utf8`, `Strip`,
  `Append_Text_Parts` (the `[<role>] ` shape).
- `src/memcp-tools.ads` — `Name`, `Description`, `Input_Schema`, `Instructions`:
  the whole inherited wire surface.
- `src/memcp-tools.adb` — `Valid_Timestamp`; `Find_Leak_Boundary` and `Salvage`.
- `src/main.adb` — the three environment variable names.
- `tests/src/test_tools.adb` — the salvage regressions, including the
  both-fields-present case that pins the narrowing.
