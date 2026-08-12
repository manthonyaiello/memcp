#!/usr/bin/env bash
# memcp SessionEnd hook.
#
# Reads the Claude Code SessionEnd payload from stdin (JSON with at least
# `session_id`, `transcript_path`, and `cwd`), base64-encodes the transcript
# file, and uploads it via the `upload_session` MCP tool.
#
# All failures are logged and exit 0 — a memcp outage must never break
# Claude Code shutdown.
#
# SessionEnd fires at shutdown, and Claude Code kills hooks that don't return
# promptly ("Hook canceled") — but the upload handshake below can take tens of
# seconds. So the hook drains stdin, then re-execs itself detached in a new
# session with the payload piped back in, and returns immediately. The detached
# worker does the real upload; its output goes to MEMCP_HOOK_LOG. (This
# survives Claude Code exiting, but not the whole host being torn down.)
#
# The project key comes from the same derivation the SessionStart hook injects
# into the session, so this transcript and the model's summary share one key.
#
# SessionEnd runs after the agent has exited, so it has nobody to emit a fault
# block to; it logs instead, and a surface whose uploads stop is detected from
# the corpus (summaries with no transcript) rather than from here.
#
# Configure (environment overrides the config file; see install.sh):
#   MEMCP_CONFIG    config file (default: $HOME/.memcp/hooks.env)
#   MEMCP_URL       MCP endpoint (default: http://127.0.0.1:8786/mcp)
#   MEMCP_PROJECT   project key, overriding derivation
#   MEMCP_HOOK_LOG  detached-worker log (default: $HOME/.claude/memcp-hook.log)
#
# Install in ~/.claude/settings.json (or per-project .claude/settings.json):
#   "hooks": { "SessionEnd": [ { "hooks": [
#       { "type": "command",
#         "command": "/abs/path/to/memcp/scripts/hooks/session_end.sh" } ] } ] }

set -uo pipefail

HOOK_PATH="${BASH_SOURCE[0]}"
HOOK_DIR="$(cd -- "$(dirname -- "$HOOK_PATH")" && pwd)"

log() { echo "memcp-hook: $*" >&2; }

if ! . "$HOOK_DIR/hook_common.sh"; then
    log "hook_common.sh missing from $HOOK_DIR"
    exit 0
fi

memcp_load_config

MEMCP_URL="${MEMCP_URL:-http://127.0.0.1:8786/mcp}"
PROTO_VER="2025-06-18"
MEMCP_HOOK_LOG="${MEMCP_HOOK_LOG:-${HOME}/.claude/memcp-hook.log}"

# --- detach: return immediately so Claude Code has nothing to cancel ---------
# Read the payload in the foreground (the stdin pipe closes when Claude Code
# exits), then re-exec detached with it piped back in. setsid gives a fresh
# session; where it's absent (macOS), nohup provides the SIGHUP immunity that
# actually matters here. Failing to detach must never mean a silent no-op, so
# if neither is available we fall through and run the upload synchronously.
if [[ "${MEMCP_HOOK_DETACHED:-}" != "1" ]]; then
    payload=$(cat)
    detach=""
    if command -v setsid >/dev/null 2>&1; then
        detach="setsid"
    elif command -v nohup >/dev/null 2>&1; then
        detach="nohup"
    fi
    if [[ -n "$detach" ]]; then
        mkdir -p "$(dirname "$MEMCP_HOOK_LOG")" 2>/dev/null || true
        printf '%s' "$payload" \
          | MEMCP_HOOK_DETACHED=1 MEMCP_HOOK_LOG="$MEMCP_HOOK_LOG" \
            "$detach" bash "$0" >>"$MEMCP_HOOK_LOG" 2>&1 &
        exit 0
    fi
    # No way to detach: run synchronously below. Set the guard so the re-exec
    # skips this block, and feed the drained payload back through the worker's
    # `payload=$(cat)` via a here-string.
    exec env MEMCP_HOOK_DETACHED=1 MEMCP_HOOK_LOG="$MEMCP_HOOK_LOG" \
        bash "$0" <<<"$payload"
fi
# --- detached worker (or synchronous fallback) runs everything below ---------

for bin in curl jq base64; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        log "missing required binary: $bin"
        exit 0
    fi
done

payload=$(cat)
if [[ -z "$payload" ]]; then
    log "empty stdin payload"
    exit 0
fi

session_id=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)
transcript_path=$(jq -r '.transcript_path // empty' <<<"$payload" 2>/dev/null || true)
cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null || true)

if [[ -z "$session_id" ]]; then
    log "missing session_id in payload"
    exit 0
fi
if [[ -z "$transcript_path" ]]; then
    log "missing transcript_path in payload"
    exit 0
fi
if [[ ! -f "$transcript_path" ]]; then
    log "transcript not found at $transcript_path"
    exit 0
fi

project="${MEMCP_PROJECT:-}"
if [[ -z "$project" ]]; then
    project=$(memcp_project_key "$cwd")
fi
if ! memcp_valid_key "$project"; then
    log "could not derive project key (cwd=$cwd)"
    exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
body="$tmpdir/body"

# Write base64 to a file rather than a shell var: on Linux a single argv
# string is capped at ~128 KB (MAX_ARG_STRLEN), so passing the encoded
# transcript via `jq --arg` blows up for anything larger than ~96 KB raw.
# `jq --rawfile` reads it from disk and sidesteps the limit.
base64 <"$transcript_path" | tr -d '\n' > "$tmpdir/b64"

init_body=$(jq -nc \
    --arg proto "$PROTO_VER" \
    --arg version "$(memcp_client_version "$HOOK_PATH")" \
    '{jsonrpc:"2.0",id:1,method:"initialize",params:{
        protocolVersion:$proto,capabilities:{},
        clientInfo:{name:"memcp-session-end",version:$version}}}')

if ! curl -sS --max-time 10 -o "$body" \
        -X POST "$MEMCP_URL" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -H "MCP-Protocol-Version: ${PROTO_VER}" \
        -d "$init_body"; then
    log "initialize failed (server down at $MEMCP_URL?)"
    exit 0
fi

# memcp assigns no session, so initialize is the whole handshake: there is no
# id to carry, and `notifications/initialized` is discarded unread.
if ! memcp_is_rpc "$(cat "$body")"; then
    log "initialize did not answer with an MCP response"
    exit 0
fi

# Logged, not emitted: nobody is left to read a block by the time this runs. The
# SessionStart hook reports the same verdict where it can be acted on, and this
# line is what `doctor` reads when diagnosing this surface specifically.
expected=$(memcp_stale_expected "$body")
[[ -z "$expected" ]] || \
    log "hooks $MEMCP_HOOK_VERSION, server shipped $expected; redeploy this surface"

# Stream the assembled body through a file so the base64 payload never has
# to fit in an argv slot — same MAX_ARG_STRLEN reason as the b64 file above.
jq -nc \
    --arg project "$project" \
    --arg session_id "$session_id" \
    --rawfile b64 "$tmpdir/b64" \
    '{jsonrpc:"2.0",id:2,method:"tools/call",params:{
        name:"upload_session",
        arguments:{project:$project,session_id:$session_id,transcript_b64:$b64}}}' \
    > "$tmpdir/req"

data=$(curl -sS --max-time 60 -X POST "$MEMCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -H "MCP-Protocol-Version: ${PROTO_VER}" \
    --data-binary @"$tmpdir/req") || {
    log "upload_session call failed"
    exit 0
}

if ! memcp_is_rpc "$data"; then
    log "upload_session did not answer with an MCP response: $data"
    exit 0
fi

err=$(memcp_tool_error "$data")
if [[ -n "$err" ]]; then
    log "upload_session error: $err"
    exit 0
fi

result=$(memcp_tool_result "$data")
log "uploaded project=$project session=$session_id surface=$(memcp_surface_label) result=$result"
exit 0
