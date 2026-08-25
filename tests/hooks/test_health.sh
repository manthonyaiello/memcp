#!/usr/bin/env bash
#
# test_health.sh — the two fleet faults SessionStart reports but cannot see in
# itself: a surface whose transcripts stopped arriving, and a call that carries
# no surface at all.
#
# Both ride on the `recent` result, so the assertions are on what the hook
# renders from a server answer, not on any state of its own.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/harness.sh"

SANDBOX="$TEST_TMP/bin"
make_sandbox "$SANDBOX"

REPO="$TEST_TMP/repo"
make_repo "$REPO" "https://github.com/acme/widget.git"

CONFIG="$TEST_TMP/hooks.env"
printf ': "${MEMCP_SURFACE_LABEL:=bench}"\n: "${MEMCP_SURFACE_ID:=bench-id}"\n: "${MEMCP_SURFACE_HOST:=minted-on}"\n' \
    >"$CONFIG"

PAYLOAD=$(printf '{"session_id":"S1","cwd":"%s","source":"startup"}' "$REPO")

OUT=""
STATUS=0

# Run SessionStart under scenario $1, leaving stdout in OUT and the exit status
# in STATUS.
run_start() {
    OUT=$(MEMCP_TEST_SCENARIO="$1" \
          MEMCP_TEST_BODY_LOG="${MEMCP_TEST_BODY_LOG:-}" \
          MEMCP_CONFIG="$CONFIG" \
          PATH="$SANDBOX" \
          bash "$HOOKS_DIR/session_start.sh" <<<"$PAYLOAD" 2>/dev/null)
    STATUS=$?
}

# --- the surface reaches the server -----------------------------------------

export MEMCP_TEST_BODY_LOG="$TEST_TMP/bodies.healthy"
run_start healthy
BODIES=$(cat "$MEMCP_TEST_BODY_LOG")
assert_contains "recent carries the surface" \
    '"surface":"bench:bench-id"' "$BODIES"

# The check-in is the only call that can carry these: they are facts about the
# surface, and the model's calls know none of them.
assert_contains "recent reports the hook release" \
    "\"hook_version\":\"$HOOK_VERSION\"" "$BODIES"
assert_contains "recent reports the host it is running on" \
    "\"host\":\"$(hostname -s 2>/dev/null || hostname)\"" "$BODIES"
assert_contains "recent reports the host the identity was minted on" \
    '"install_host":"minted-on"' "$BODIES"

# --- a healthy fleet says nothing -------------------------------------------

assert_eq       "healthy: exit 0"                  0 "$STATUS"
assert_not_contains "healthy: no degraded block"   '<memcp-hook-degraded' "$OUT"
assert_not_contains "healthy: no unattributed block" \
    '<memcp-hook-unattributed' "$OUT"

run_start no-entries
assert_not_contains "no entries: still no degraded block" \
    '<memcp-hook-degraded' "$OUT"

# --- a degraded surface, reported from a healthy one -------------------------
#
# The findings name another surface, never this one: the machine whose uploads
# stopped is not the machine that can notice.

unset MEMCP_TEST_BODY_LOG
run_start degraded
assert_eq       "degraded: exit 0"                 0 "$STATUS"
assert_contains "degraded: the block is emitted"   '<memcp-hook-degraded count="2">' "$OUT"
assert_contains "degraded: names the other surface" \
    '  - otherbox: 9 of the last 20 sessions have no transcript' "$OUT"
assert_contains "degraded: counts the sessions it cannot attribute" \
    '  - an unidentified surface: 6 of the last 6 sessions have no transcript' "$OUT"
assert_contains "degraded: names the remedy" '`doctor`' "$OUT"
assert_contains "degraded: tells the user"   'Tell the user' "$OUT"
assert_contains "degraded: the Headers are still listed" \
    '<memcp-prior-sessions project="widget" count="2">' "$OUT"

# --- an unattributed call ----------------------------------------------------
#
# The server's warning is passed through verbatim: it carries its own remedy,
# and a hook that reworded it would drift from the server that decides.

run_start unattributed
assert_eq       "unattributed: exit 0"             0 "$STATUS"
assert_contains "unattributed: the block is emitted" \
    '<memcp-hook-unattributed hook="session_start">' "$OUT"
assert_contains "unattributed: carries the server's words" \
    'no surface argument, so memcp cannot record which machine' "$OUT"
assert_contains "unattributed: the Headers are still listed" \
    '<memcp-prior-sessions project="widget" count="2">' "$OUT"

finish
