#!/usr/bin/env bash
#
# test_stale.sh — a surface behind the repository is told so, and told what to
# run.
#
# The verdict is the server's: the stub compares the version the hook reports
# against the release it shipped with, so these cases drive the hook the way
# production does rather than injecting a decision it would not have received.
# What is asserted here is the reporting -- that the block appears exactly when
# the server says so, names something actionable, and stops there.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/harness.sh"

SANDBOX="$TEST_TMP/bin"
make_sandbox "$SANDBOX"

REPO="$TEST_TMP/repo"
make_repo "$REPO" "https://github.com/acme/widget.git"

CONFIG="$TEST_TMP/hooks.env"
export MEMCP_CONFIG="$CONFIG"
export MEMCP_SURFACE_LABEL="testbox"

# Run SessionStart against a server that shipped with release $1 ("" for a
# server that reports nothing), for payload source $2, logging request bodies
# to $3.
run_start() {
    local shipped="$1" source_kind="${2:-startup}"
    MEMCP_TEST_SCENARIO=healthy \
    MEMCP_TEST_SERVER_HOOK_VERSION="$shipped" \
    MEMCP_TEST_BODY_LOG="${3:-}" \
    MEMCP_CONFIG="$CONFIG" PATH="$SANDBOX" \
        bash "$HOOKS_DIR/session_start.sh" 2>/dev/null <<EOF
{"session_id":"S1","cwd":"$REPO","source":"$source_kind"}
EOF
}

# --- current -----------------------------------------------------------------

BODY_LOG="$TEST_TMP/bodies"
OUT=$(run_start "$HOOK_VERSION" startup "$BODY_LOG")
assert_not_contains "current: no staleness block" '<memcp-hook-stale' "$OUT"
assert_contains     "current: still injects the key" \
    '<memcp-session id="S1" project="widget"' "$OUT"

# The version on the wire is `release+digest`, and that run was not called
# stale: comparing the whole string would report every surface as stale forever,
# since the server knows its own release and not the digest of files on some
# other machine.
assert_match "current: the reported version carried a digest" \
    "\"version\":\"$HOOK_VERSION_RE\\+[0-9a-f]{8}\"" "$(cat "$BODY_LOG")"

# --- a server that says nothing ----------------------------------------------

OUT=$(run_start "")
assert_not_contains "no note: absence is not a verdict" '<memcp-hook-stale' "$OUT"

# --- stale -------------------------------------------------------------------

OUT=$(run_start "9.9.9")
STATUS=$?
assert_eq       "stale: exit 0" 0 "$STATUS"
assert_contains "stale: names the hook" '<memcp-hook-stale hook="session_start"' "$OUT"
assert_contains "stale: names the surface" 'surface="testbox"' "$OUT"
assert_contains "stale: names what it runs" "running=\"$HOOK_VERSION\"" "$OUT"
assert_contains "stale: names what the server shipped" 'expected="9.9.9"' "$OUT"
assert_contains "stale: names the command and the surface to run it for" \
    'scripts/hooks/deploy.sh testbox' "$OUT"

# Reporting, not withholding: a behind-but-working hook still does its job.
assert_contains "stale: still injects the key" \
    '<memcp-session id="S1" project="widget"' "$OUT"
assert_contains "stale: still injects the diary" \
    '<memcp-prior-sessions' "$OUT"

# --- a resumed session -------------------------------------------------------

# `resume` and `compact` skip the diary listing, so the report has to be emitted
# ahead of that early exit or a long-running session never hears about it.
OUT=$(run_start "9.9.9" resume)
assert_contains     "resume: still reports staleness" '<memcp-hook-stale' "$OUT"
assert_not_contains "resume: still skips the diary listing" \
    '<memcp-prior-sessions' "$OUT"

# --- SessionEnd --------------------------------------------------------------

# Nobody is left to read a block, so it logs. Run undetached: the detached
# worker writes to its own log and would race this assertion.
TRANSCRIPT="$TEST_TMP/transcript.jsonl"
printf '{"type":"user"}\n' >"$TRANSCRIPT"
END_ERR="$TEST_TMP/end.err"
END_OUT=$(MEMCP_TEST_SCENARIO=healthy \
    MEMCP_TEST_SERVER_HOOK_VERSION="9.9.9" \
    MEMCP_HOOK_DETACHED=1 MEMCP_CONFIG="$CONFIG" PATH="$SANDBOX" \
    bash "$HOOKS_DIR/session_end.sh" 2>"$END_ERR" <<EOF
{"session_id":"S1","cwd":"$REPO","transcript_path":"$TRANSCRIPT"}
EOF
)
assert_not_contains "session_end: emits no block" '<memcp-hook-stale' "$END_OUT"
assert_contains     "session_end: logs the version gap" \
    "server shipped 9.9.9" "$(cat "$END_ERR")"

finish
