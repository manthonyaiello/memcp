# 0021 — The Header is authored, not derived

Status: **Implemented** in `src/memcp-store.ads` (the schema, `Max_Header`, the
record types), `src/memcp-store.adb` (`Migrate_To_Headers`, `Save`,
`Save_Autorecap`, `Recent_Headers`), `src/memcp-tools.ad?` (the wire names and
the over-budget warning) and `scripts/hooks/session_start.sh`. Supersedes the
summaries/diary split described in 0009. Refs #68, #72.

A Header is the one line a session gets to say to the next one. Everything in
the retrieval ladder hangs off whether that line is worth the fetch behind it.
This records why it is now stored as written, and why the table that used to
hold the written version is gone.

## Two channels, and the wrong one on the wire

`save` took a `diary` argument, documented as "a single headline line". It was
stored in `diary.body`, and no tool read it. What `recent` returned as the
Header, and therefore what `SessionStart` injected, was `summaries.headline` —
computed by the server from the *summary body*: the remainder of a first line
beginning `HEADLINE:`, else the body flattened to one line and cut at 100 bytes.

Both channels were live at once and the corpus shows when they crossed. Through
23 May 2026 the marker was on essentially every row and the `diary` argument
carried whole bodies averaging 8 KB. By 26 May the marker was gone and `diary`
carried a single line of 100–200 characters. Nothing in the store changed; the
model's calling convention did, in exactly the direction its instructions asked
for. The effect was to switch off the only channel the store read from, leaving
a truncation where an authored line had been — and the authored line, now
correctly supplied, in a column nothing selected.

The two derivations were also unsound in their own terms. The cut counted bytes
over UTF-8, so it could land inside a character. The marker had no length bound
at all, so the one path that produced a good Header produced an unbounded one.

## What decided it

Not the diary rows. The autorecap rows.

`Save_Autorecap` writes the recap as the Summary and put the same 100-byte cut
in `headline`. Every recap in the corpus is longer than that — the shortest is
171 characters. So `Header text == Summary text`, which the README, the tool
description and the server instructions all state, and which the `kind` field
exists to let a reader *act* on by skipping a fetch, was false for every
autorecap ever written.

Storing what the author wrote makes that invariant hold by construction rather
than by arithmetic. The recap goes into both columns whole; there is nothing
left to be right or wrong about. That is worth more than the derivation it
costs, which is the general form of the decision here: a Header is text
somebody wrote, and a store that computes one is guessing at a thing it was
handed.

## One column, one word

`diary` was 1:1 with `summaries` — never an orphan, never two to a summary,
with `project_id` and `created_at` identical to its parent in every row. It
contributed `body` and nothing else. Once `body` becomes `summaries.header`,
keeping the table would mean storing the same text twice with no reader, which
is the fault this ADR exists to remove, rebuilt one column over. So it is
dropped, `Recent_Headers` reads `summaries` directly, and `list_projects`
counts summaries instead of a proxy for them.

The word went with it. `diary` named three unrelated things — a table, an
argument, and the `kind` value for a model-authored row — none of which appears
in the four-level vocabulary the README teaches. The argument and the column are
`header`; the kind is `authored`; the table is gone. `HEADLINE:` is no longer
parsed, and the two functions that did the parsing are deleted rather than
rewritten.

## Migrating without losing text

`Migrate_To_Headers` runs once, keyed on `summaries.headline` still existing,
and chooses per row rather than per date:

- an autorecap's Header is its own body, whole;
- otherwise the diary line, where it is the one line within `Max_Header` that a
  Header is;
- otherwise the headline the row already had — which on a row whose diary line
  is a whole body is the marker-authored text from before the split, and is
  therefore the better of the two.

A diary line that is neither promoted nor already a substring of its summary
body is appended to that body before the drop. That case is rare and confined
to the weeks around the changeover, but it is the only place where the table
held text no other column did, so the append is what makes the drop safe rather
than merely tidy.

One consequence is deliberate and inert. `dedup_hash` is taken over (project,
Header, Summary), and for a promoted or autorecap row the values are unchanged,
so the stored digest still matches. For a row that kept its old headline, or
whose body grew an appended line, it no longer does. A stale digest can only
cost a re-save of that same session its no-op path, and these are rows from
sessions that closed months ago.

## The budget goes on the write

`Max_Header` is 400 characters, which clears every line the model has actually
authored since the convention settled. It is enforced where the caller can hear
about it: `save` stores an over-budget Header whole and returns a warning naming
the cost, rather than cutting on display where the loss is silent and the author
has already gone. Losing text nobody else holds is the worse failure, and a save
is a session-scoped upsert — a shortened retry replaces the row in place.

The same reasoning says a *missing* Header is an error and not something to
derive from the summary. A derived Header stored in an `authored` row is
indistinguishable from a written one, which is the confusion this ADR removes.
The fallback for a session that never called `save` already exists, and it is
labelled: SessionEnd writes an autorecap, and `kind` says so.
