#!/usr/bin/env bash
#
# test_deploy.sh — what deploy.sh puts on a surface, and what it refuses to
# touch.
#
# The far side is the harness ssh stub, which joins its command words the way
# ssh does. That is deliberate: the arguments deploy.sh sends have to survive a
# shell on the remote host, and a stub that took an argument vector would prove
# nothing about the case where one of them is empty.
#
# Every wiring assertion reads the settings file back rather than the output,
# since the output is a report and the file is the effect.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/harness.sh"

SANDBOX="$TEST_TMP/bin"
SANDBOX_NOCLAUDE="$TEST_TMP/bin-noclaude"
make_sandbox "$SANDBOX"
make_sandbox "$SANDBOX_NOCLAUDE" claude

SETTINGS="$HOME/.claude/settings.json"
DEST="$HOME/.claude/hooks/memcp"
REGISTRY="$TEST_TMP/mcp-registry"

UNRELATED="/usr/local/bin/unrelated.sh"

# Restore the unwired settings file, so a later case can tell "wrote nothing"
# from "wrote the same thing again".
reset_settings() {
    mkdir -p "$HOME/.claude"
    cat >"$SETTINGS" <<EOF
{ "model": "opus",
  "hooks": {
    "SessionStart": [ { "hooks": [ { "type": "command", "command": "$UNRELATED" } ] } ],
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/opt/guard.sh" } ] } ] } }
EOF
}

reset_settings

OUT=""
STATUS=0

# Run deploy.sh with PATH $1 under scenario $2, leaving stdout and stderr in
# OUT and the exit status in STATUS. Remaining arguments go to deploy.sh.
run_deploy() {
    local path="$1" scenario="$2"; shift 2
    OUT=$(PATH="$path" \
          MEMCP_TEST_SCENARIO="$scenario" \
          MEMCP_TEST_MCP_REGISTRY="$REGISTRY" \
          bash "$HOOKS_DIR/deploy.sh" "$@" 2>&1)
    STATUS=$?
}

# The commands wired for hook event $1, newline separated.
wired() {
    jq -r --arg e "$1" '.hooks[$e][]?.hooks[]?.command' "$SETTINGS" 2>/dev/null
}

# MEMCP_SURFACE_ID as recorded in the surface config.
surface_id() {
    sed -n 's/.*MEMCP_SURFACE_ID:=\([^}"]*\).*/\1/p' "$HOME/.memcp/hooks.env" 2>/dev/null
}

# --- what it refuses before touching anything -------------------------------

run_deploy "$SANDBOX" healthy
assert_eq "no target: exit 2" 2 "$STATUS"
assert_contains "no target: says what is missing" "nothing to do" "$OUT"

run_deploy "$SANDBOX" healthy --dest '$HOME/a;rm -rf b' host
assert_eq "dest with a metacharacter: exit 2" 2 "$STATUS"

run_deploy "$SANDBOX" healthy --url 'http://h/`id`' host
assert_eq "url with a metacharacter: exit 2" 2 "$STATUS"

# deploy.sh streams deploy_remote.sh to the far side, so a tree carrying
# everything else is still not a working deploy and has to say so.
ALONE="$TEST_TMP/alone"
mkdir -p "$ALONE"
cp "$HOOKS_DIR/deploy.sh" "$HOOKS_DIR/hook_common.sh" "$HOOKS_DIR/install.sh" \
   "$HOOKS_DIR/session_start.sh" "$HOOKS_DIR/session_end.sh" "$ALONE/"
OUT=$(PATH="$SANDBOX" bash "$ALONE/deploy.sh" --local 2>&1)
STATUS=$?
assert_eq "remote half missing: nonzero exit" 1 "$STATUS"
assert_contains "remote half missing: names the file" "deploy_remote.sh" "$OUT"

BEFORE=$(cat "$SETTINGS")

run_deploy "$SANDBOX" healthy --dry-run host
assert_eq "dry run: exit 0" 0 "$STATUS"
assert_contains "dry run: reports the dependency check" "deps ok" "$OUT"
assert_eq "dry run: the settings file is untouched" "$BEFORE" "$(cat "$SETTINGS")"

# --- the healthy path -------------------------------------------------------

run_deploy "$SANDBOX" healthy host
assert_eq "deploy: exit 0" 0 "$STATUS"

assert_eq "deploy: the payload is the four scripts and nothing else" \
    "hook_common.sh install.sh session_end.sh session_start.sh" \
    "$(cd "$DEST" && ls | sort | tr '\n' ' ' | sed 's/ $//')"

assert_eq "deploy: SessionStart is wired to the copy" \
    "$UNRELATED
$DEST/session_start.sh" "$(wired SessionStart)"

assert_eq "deploy: SessionEnd is wired to the copy" \
    "$DEST/session_end.sh" "$(wired SessionEnd)"

assert_eq "deploy: an unrelated event is left alone" \
    "/opt/guard.sh" "$(wired PreToolUse)"

assert_eq "deploy: a key outside hooks is left alone" \
    "opus" "$(jq -r .model "$SETTINGS")"

assert_eq "deploy: the settings file is backed up" \
    "$BEFORE" "$(cat "$SETTINGS.memcp-bak")"

assert_contains "deploy: registers the server" \
    "registered memcp" "$OUT"
assert_eq "deploy: registers the URL the hooks were given" \
    "memcp http://127.0.0.1:8786/mcp" "$(cat "$REGISTRY")"

# An empty --url is the case that made this test worth writing: passed through
# ssh unquoted it arrives as no argument at all.
assert_not_contains "deploy: the arguments survive ssh's word joining" \
    "expected 3 arguments" "$OUT"

# --- a second run -----------------------------------------------------------

FIRST_ID=$(surface_id)

run_deploy "$SANDBOX" healthy host
assert_eq "re-deploy: exit 0" 0 "$STATUS"

assert_eq "re-deploy: the wiring is replaced, not appended" \
    "$UNRELATED
$DEST/session_start.sh" "$(wired SessionStart)"

assert_eq "re-deploy: the surface keeps the identity it minted" \
    "$FIRST_ID" "$(surface_id)"

assert_contains "re-deploy: the registration is recognised, not repeated" \
    "already registered" "$OUT"
assert_eq "re-deploy: the registry gains no second entry" \
    1 "$(wc -l <"$REGISTRY" | tr -d ' ')"

# --- a registration pointing somewhere else ---------------------------------

printf 'memcp %s\n' "http://elsewhere.invalid:8786/mcp" >"$REGISTRY"

run_deploy "$SANDBOX" healthy host
assert_contains "other URL: says it was left alone" "left alone" "$OUT"
assert_eq "other URL: the registration is not overwritten" \
    "memcp http://elsewhere.invalid:8786/mcp" "$(cat "$REGISTRY")"

# --- a surface that cannot be finished --------------------------------------

reset_settings
BEFORE=$(cat "$SETTINGS")
rm -f "$SETTINGS.memcp-bak"

run_deploy "$SANDBOX_NOCLAUDE" healthy hostA hostB
assert_match "no claude: names the missing dependency" \
    "missing on this surface:.*claude" "$OUT"
assert_eq "no claude: nonzero exit" 1 "$STATUS"
assert_contains "no claude: the other host is still attempted" "== hostB" "$OUT"
assert_eq "no claude: nothing is wired" "$BEFORE" "$(cat "$SETTINGS")"
assert_eq "no claude: no backup is written" \
    "absent" "$([[ -f "$SETTINGS.memcp-bak" ]] && echo present || echo absent)"

# --- a CLI the profile's PATH does not reach --------------------------------
#
# An installed CLI that only an interactive shell can find, which is the stock
# arrangement on both Linux and macOS: the far side must deploy, not report the
# surface as having no Claude Code on it.

reset_settings
rm -f "$SETTINGS.memcp-bak" "$REGISTRY"
mkdir -p "$HOME/.local/bin"
make_stub_claude "$HOME/.local/bin"

run_deploy "$SANDBOX_NOCLAUDE" healthy host
assert_eq "claude off PATH: exit 0" 0 "$STATUS"
assert_not_contains "claude off PATH: not reported missing" \
    "missing on this surface" "$OUT"
assert_contains "claude off PATH: the server is registered" \
    "registered memcp" "$OUT"
assert_eq "claude off PATH: SessionStart is wired" \
    "$UNRELATED
$DEST/session_start.sh" "$(wired SessionStart)"

rm -f "$HOME/.local/bin/claude"

# --- an unreachable host does not stop the others ---------------------------

run_deploy "$SANDBOX" healthy --url "" host
FAIL_OUT=$(PATH="$SANDBOX" MEMCP_TEST_SSH_FAIL=deadhost \
           MEMCP_TEST_MCP_REGISTRY="$REGISTRY" \
           bash "$HOOKS_DIR/deploy.sh" deadhost host 2>&1)
FAIL_STATUS=$?
assert_eq "unreachable host: nonzero exit" 1 "$FAIL_STATUS"
assert_contains "unreachable host: named as failed" "failed: deadhost" "$FAIL_OUT"
assert_contains "unreachable host: the reachable host still runs" \
    "== host" "$FAIL_OUT"

# --- this machine -----------------------------------------------------------

run_deploy "$SANDBOX" healthy --local
assert_eq "local: exit 0" 0 "$STATUS"
assert_eq "local: wired to the checkout, not to a copy" \
    "$UNRELATED
$HOOKS_DIR/session_start.sh" "$(wired SessionStart)"

# --- no server on the surface -----------------------------------------------

run_deploy "$SANDBOX" unreachable host
assert_eq "no server: exit 0, the surface is still wired" 0 "$STATUS"
assert_contains "no server: says the hooks will no-op" "no server at" "$OUT"

finish
