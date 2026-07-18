#!/usr/bin/env bash
# memcp SessionEnd hook.
#
# Reads the Claude Code SessionEnd payload from stdin (JSON with at least
# `session_id`, `transcript_path`, and `cwd`), base64-encodes the transcript
# file, and uploads it via the `upload_session` MCP tool.
#
# All failures are logged to stderr and exit 0 — a memcp outage must never
# break Claude Code shutdown.
#
# Configure:
#   MEMCP_URL      MCP endpoint (default: http://127.0.0.1:8786/mcp)
#   MEMCP_PROJECT  project name (default: basename of cwd from payload)
#
# Install in ~/.claude/settings.json (or per-project .claude/settings.json):
#   "hooks": { "SessionEnd": [ { "hooks": [
#       { "type": "command",
#         "command": "/abs/path/to/memcp/scripts/hooks/session_end.sh" } ] } ] }

set -uo pipefail

MEMCP_URL="${MEMCP_URL:-http://127.0.0.1:8786/mcp}"
PROTO_VER="2025-06-18"

log() { echo "memcp-hook: $*" >&2; }

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
    if [[ -z "$cwd" ]]; then
        log "no cwd in payload and MEMCP_PROJECT unset"
        exit 0
    fi
    project=$(basename "$cwd")
fi
if [[ -z "$project" || "$project" == "/" || "$project" == "." ]]; then
    log "could not derive project name (cwd=$cwd)"
    exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
headers="$tmpdir/headers"
body="$tmpdir/body"

# Write base64 to a file rather than a shell var: on Linux a single argv
# string is capped at ~128 KB (MAX_ARG_STRLEN), so passing the encoded
# transcript via `jq --arg` blows up for anything larger than ~96 KB raw.
# `jq --rawfile` reads it from disk and sidesteps the limit.
base64 <"$transcript_path" | tr -d '\n' > "$tmpdir/b64"

if ! curl -sS --max-time 10 -D "$headers" -o "$body" \
        -X POST "$MEMCP_URL" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "MCP-Protocol-Version: ${PROTO_VER}" \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
            "protocolVersion":"'"${PROTO_VER}"'","capabilities":{},
            "clientInfo":{"name":"memcp-session-end","version":"0.1.0"}}}'; then
    log "initialize failed (server down at $MEMCP_URL?)"
    exit 0
fi

sid=$(grep -i '^mcp-session-id:' "$headers" | tr -d '\r' | awk '{print $2}')
if [[ -z "$sid" ]]; then
    log "no mcp-session-id header from initialize"
    exit 0
fi

curl -sS --max-time 10 -X POST "$MEMCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "MCP-Protocol-Version: ${PROTO_VER}" \
    -H "Mcp-Session-Id: ${sid}" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null || {
    log "notifications/initialized failed"
    exit 0
}

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

response=$(curl -sS --max-time 60 -X POST "$MEMCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "MCP-Protocol-Version: ${PROTO_VER}" \
    -H "Mcp-Session-Id: ${sid}" \
    --data-binary @"$tmpdir/req") || {
    log "upload_session call failed"
    exit 0
}

# SSE: payload arrives as `data: {...}` lines.
data=$(echo "$response" | sed -n 's/^data: //p')
if [[ -z "$data" ]]; then
    log "empty response from upload_session: $response"
    exit 0
fi

err=$(jq -r '.error.message // empty' <<<"$data" 2>/dev/null || true)
if [[ -n "$err" ]]; then
    log "upload_session error: $err"
    exit 0
fi

result=$(jq -c '.result.structuredContent // .result.content // empty' <<<"$data" 2>/dev/null || true)
log "uploaded project=$project session=$session_id result=$result"
exit 0
