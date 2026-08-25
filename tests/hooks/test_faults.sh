#!/usr/bin/env bash
#
# test_faults.sh — what SessionStart emits when something is broken, and what
# both hooks send when nothing is.
#
# Every case asserts exit status 0 as well as the block: a hook that reported a
# fault by failing would break the client it is supposed to leave alone.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/harness.sh"

SANDBOX="$TEST_TMP/bin"
SANDBOX_NOJQ="$TEST_TMP/bin-nojq"
make_sandbox "$SANDBOX"
make_sandbox "$SANDBOX_NOJQ" jq

REPO="$TEST_TMP/repo"
make_repo "$REPO" "https://github.com/acme/widget.git"

CONFIG="$TEST_TMP/hooks.env"
printf ': "${MEMCP_SURFACE_LABEL:=bench}"\n: "${MEMCP_SURFACE_ID:=bench-id}"\n' \
    >"$CONFIG"

PAYLOAD=$(printf '{"session_id":"S1","cwd":"%s","source":"startup"}' "$REPO")
END_PAYLOAD=""

OUT=""
STATUS=0

# Run SessionStart under scenario $1 with PATH $2 (default: the full sandbox),
# leaving stdout in OUT and the exit status in STATUS.
run_start() {
    OUT=$(MEMCP_TEST_SCENARIO="$1" \
          MEMCP_TEST_BODY_LOG="${MEMCP_TEST_BODY_LOG:-}" \
          MEMCP_CONFIG="$CONFIG" \
          PATH="${2:-$SANDBOX}" \
          bash "$HOOKS_DIR/session_start.sh" <<<"$PAYLOAD" 2>/dev/null)
    STATUS=$?
}

# --- the healthy path -------------------------------------------------------

export MEMCP_TEST_BODY_LOG="$TEST_TMP/bodies.healthy"
run_start healthy
assert_eq       "healthy: exit 0"                    0 "$STATUS"
assert_contains "healthy: session block carries the derived key" \
    '<memcp-session id="S1" project="widget"' "$OUT"
assert_contains "healthy: the key is marked verbatim" \
    'Pass project="widget", session_id="S1" and surface=' "$OUT"
assert_contains "healthy: prior sessions are listed"  '<memcp-prior-sessions project="widget" count="2">' "$OUT"
assert_contains "healthy: Headers are surfaced"       'kind=autorecap] second header' "$OUT"
assert_not_contains "healthy: no fault block"         '<memcp-hook-error' "$OUT"
assert_not_contains "healthy: no modification block"  '<memcp-hook-modified' "$OUT"

BODIES=$(cat "$MEMCP_TEST_BODY_LOG")
assert_contains "healthy: recent is scoped to the derived key" \
    '"projects":["widget"]' "$BODIES"
assert_match "healthy: initialize reports version and digest" \
    "\"version\":\"$HOOK_VERSION_RE\\+[0-9a-f]{8}\"" "$BODIES"

# The agreement the whole issue turns on: SessionEnd must upload under the key
# SessionStart injected, without either side consulting the other.
export MEMCP_TEST_BODY_LOG="$TEST_TMP/bodies.end"
TRANSCRIPT="$TEST_TMP/transcript.jsonl"
printf '{"type":"user","message":{"content":"hello"}}\n' >"$TRANSCRIPT"
END_PAYLOAD=$(printf '{"session_id":"S1","cwd":"%s","transcript_path":"%s"}' \
    "$REPO/src" "$TRANSCRIPT")
mkdir -p "$REPO/src"

END_OUT=$(MEMCP_TEST_SCENARIO=healthy \
          MEMCP_TEST_BODY_LOG="$MEMCP_TEST_BODY_LOG" \
          MEMCP_CONFIG="$CONFIG" \
          MEMCP_HOOK_DETACHED=1 \
          PATH="$SANDBOX" \
          bash "$HOOKS_DIR/session_end.sh" <<<"$END_PAYLOAD" 2>&1)
END_STATUS=$?
assert_eq "session_end: exit 0" 0 "$END_STATUS"

END_BODIES=$(cat "$MEMCP_TEST_BODY_LOG")
assert_contains "session_end: uploads under the key SessionStart injected" \
    '"project":"widget"' "$END_BODIES"
assert_contains "session_end: uploads under this surface" \
    '"surface":"bench:bench-id"' "$END_BODIES"
assert_match "session_end: initialize reports version and digest" \
    "\"version\":\"$HOOK_VERSION_RE\\+[0-9a-f]{8}\"" "$END_BODIES"
assert_contains "session_end: logs the surface" "surface=" "$END_OUT"

unset MEMCP_TEST_BODY_LOG

# --- faults -----------------------------------------------------------------

run_start healthy "$SANDBOX_NOJQ"
assert_eq       "jq absent: exit 0"      0 "$STATUS"
assert_contains "jq absent: names the dependency" \
    'fault="missing-dependency"' "$OUT"
assert_contains "jq absent: names jq"    'needs `jq`' "$OUT"
assert_contains "jq absent: gives a remedy" 'Remedy: Install jq' "$OUT"

run_start unreachable
assert_eq       "server down: exit 0"    0 "$STATUS"
assert_contains "server down: names the fault" 'fault="server-unreachable"' "$OUT"
assert_not_contains "server down: no session block" '<memcp-session' "$OUT"

run_start initialize-rejected
assert_eq       "initialize refused: exit 0" 0 "$STATUS"
assert_contains "initialize refused: names the fault" 'fault="initialize-rejected"' "$OUT"

run_start malformed
assert_eq       "malformed body: exit 0" 0 "$STATUS"
assert_contains "malformed body: names the fault" 'fault="malformed-response"' "$OUT"

run_start tool-call-failed
assert_eq       "dropped tool call: exit 0" 0 "$STATUS"
assert_contains "dropped tool call: names the fault" 'fault="tool-call-failed"' "$OUT"

run_start tool-error
assert_eq       "tool error: exit 0"     0 "$STATUS"
assert_contains "tool error: names the fault" 'fault="tool-error"' "$OUT"
assert_contains "tool error: quotes the server's message" 'no such tool' "$OUT"

# A tool that failed inside a successful JSON-RPC response is still a failure.
run_start tool-is-error
assert_eq       "isError result: exit 0" 0 "$STATUS"
assert_contains "isError result: names the fault" 'fault="tool-error"' "$OUT"
assert_contains "isError result: quotes the server's message" 'database is locked' "$OUT"

OUT=$(MEMCP_CONFIG="$CONFIG" PATH="$SANDBOX" \
      bash "$HOOKS_DIR/session_start.sh" </dev/null 2>/dev/null)
STATUS=$?
assert_eq       "empty payload: exit 0"  0 "$STATUS"
assert_contains "empty payload: names the fault" 'fault="empty-payload"' "$OUT"

OUT=$(MEMCP_TEST_SCENARIO=healthy MEMCP_CONFIG="$CONFIG" MEMCP_PROJECT=" " \
      PATH="$SANDBOX" bash "$HOOKS_DIR/session_start.sh" \
      <<<'{"session_id":"S1","cwd":"/","source":"startup"}' 2>/dev/null)
STATUS=$?
assert_eq       "underivable project: exit 0" 0 "$STATUS"
assert_contains "underivable project: names the fault" 'fault="no-project"' "$OUT"

# The library is what carries the emission helpers, so its absence has to
# report itself without them.
ORPHAN="$TEST_TMP/orphan"
mkdir -p "$ORPHAN"
cp "$HOOKS_DIR/session_start.sh" "$ORPHAN/"
OUT=$(MEMCP_CONFIG="$CONFIG" PATH="$SANDBOX" \
      bash "$ORPHAN/session_start.sh" <<<"$PAYLOAD" 2>/dev/null)
STATUS=$?
assert_eq       "library missing: exit 0" 0 "$STATUS"
assert_contains "library missing: names the fault" 'fault="library-missing"' "$OUT"

# The one case that goes through the real curl: nothing listens on port 1.
OUT=$(MEMCP_CONFIG="$CONFIG" MEMCP_URL="http://127.0.0.1:1/mcp" \
      bash "$HOOKS_DIR/session_start.sh" <<<"$PAYLOAD" 2>/dev/null)
STATUS=$?
assert_eq       "closed port, real curl: exit 0" 0 "$STATUS"
assert_contains "closed port, real curl: names the fault" \
    'fault="server-unreachable"' "$OUT"

# --- resume and compact -----------------------------------------------------

OUT=$(MEMCP_TEST_SCENARIO=healthy MEMCP_CONFIG="$CONFIG" PATH="$SANDBOX" \
      bash "$HOOKS_DIR/session_start.sh" \
      <<<"$(printf '{"session_id":"S1","cwd":"%s","source":"compact"}' "$REPO")" \
      2>/dev/null)
assert_contains "compact: the key is still injected" \
    '<memcp-session id="S1" project="widget"' "$OUT"
assert_not_contains "compact: no Header listing" '<memcp-prior-sessions' "$OUT"

# --- what the hooks must not send -------------------------------------------
# The two are co-designed: memcp assigns no session and reads no notification,
# so a hook that sends either has drifted from the server it is paired with.

ARGV_LOG="$TEST_TMP/argv"
: >"$ARGV_LOG"
MEMCP_TEST_SCENARIO=healthy MEMCP_TEST_ARGV_LOG="$ARGV_LOG" \
    MEMCP_CONFIG="$CONFIG" PATH="$SANDBOX" \
    bash "$HOOKS_DIR/session_start.sh" <<<"$PAYLOAD" >/dev/null 2>&1
SENT=$(cat "$ARGV_LOG")
assert_not_contains "no session header is echoed" "Mcp-Session-Id" "$SENT"
assert_not_contains "no notification is sent"     "notifications/initialized" "$SENT"
assert_not_contains "no event stream is accepted" "text/event-stream" "$SENT"
assert_eq "the handshake is one round trip plus the tool call" \
    2 "$(grep -c . "$ARGV_LOG")"

run_start no-entries
assert_not_contains "empty result: no fault block" '<memcp-hook-error' "$OUT"
assert_not_contains "empty result: no listing"     '<memcp-prior-sessions' "$OUT"

finish
