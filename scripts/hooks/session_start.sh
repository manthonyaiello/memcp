#!/usr/bin/env bash
# memcp SessionStart hook.
#
# Reads the Claude Code SessionStart payload from stdin (JSON with at least
# `session_id`, `cwd`, and `source`), looks up recent diary entries for the
# current project via the `recent` MCP tool, and prints them to stdout so
# Claude Code adds them to the first-turn context.
#
# Also surfaces `<memcp-session id="..."/>` carrying the current Claude Code
# session_id. This is the value the model must pass to `memcp.save` so its
# diary entry links to the transcript that the SessionEnd hook uploads under
# the same id. The tag is only emitted when memcp is reachable — its absence
# tells the model to skip the memcp save.
#
# All failures are logged to stderr and exit 0 — a memcp outage must never
# break Claude Code startup.
#
# Configure:
#   MEMCP_URL      MCP endpoint (default: http://127.0.0.1:8786/mcp)
#   MEMCP_PROJECT  project name (default: basename of cwd from payload)
#   MEMCP_RECENT_N number of entries to surface (default: 5)
#
# Install in ~/.claude/settings.json (or per-project .claude/settings.json):
#   "hooks": { "SessionStart": [ { "hooks": [
#       { "type": "command",
#         "command": "/abs/path/to/memcp/scripts/hooks/session_start.sh" } ] } ] }

set -uo pipefail

MEMCP_URL="${MEMCP_URL:-http://127.0.0.1:8786/mcp}"
RECENT_N="${MEMCP_RECENT_N:-5}"
PROTO_VER="2025-06-18"

log() { echo "memcp-hook: $*" >&2; }

for bin in curl jq; do
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

source_kind=$(jq -r '.source // empty' <<<"$payload" 2>/dev/null || true)
cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null || true)
session_id=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)

# Skip on `resume` and `compact`: the model already has prior context in those
# cases, and injecting diary on top is duplicative noise. Surface only on
# fresh sessions (`startup`, `clear`).
case "$source_kind" in
    startup|clear|"") : ;;  # empty source = older Claude Code; behave like startup
    *)
        log "skipping (source=$source_kind)"
        exit 0
        ;;
esac

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

if ! curl -sS --max-time 10 -D "$headers" -o "$body" \
        -X POST "$MEMCP_URL" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "MCP-Protocol-Version: ${PROTO_VER}" \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
            "protocolVersion":"'"${PROTO_VER}"'","capabilities":{},
            "clientInfo":{"name":"memcp-session-start","version":"0.1.0"}}}'; then
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

recent_body=$(jq -nc \
    --arg project "$project" \
    --argjson n "$RECENT_N" \
    '{jsonrpc:"2.0",id:2,method:"tools/call",params:{
        name:"recent",
        arguments:{projects:[$project],n:$n}}}')

response=$(curl -sS --max-time 10 -X POST "$MEMCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "MCP-Protocol-Version: ${PROTO_VER}" \
    -H "Mcp-Session-Id: ${sid}" \
    -d "$recent_body") || {
    log "recent call failed"
    exit 0
}

data=$(echo "$response" | sed -n 's/^data: //p')
if [[ -z "$data" ]]; then
    log "empty response from recent: $response"
    exit 0
fi

err=$(jq -r '.error.message // empty' <<<"$data" 2>/dev/null || true)
if [[ -n "$err" ]]; then
    log "recent error: $err"
    exit 0
fi

# memcp is reachable — surface session_id so the model can pass it to save().
# Tag presence doubles as the "memcp is up" signal for the dual-write flow.
if [[ -n "$session_id" ]]; then
    printf '<memcp-session id="%s"/>\n' "$session_id"
fi

entries=$(jq -c '.result.structuredContent.result // []' <<<"$data" 2>/dev/null || true)
count=$(jq 'length' <<<"$entries" 2>/dev/null || echo 0)

if [[ "$count" == "0" ]]; then
    log "no prior diary entries for project=$project"
    exit 0
fi

# Surface to Claude. Headlines only — bodies are recoverable via fetch_summary.
# `kind` (diary|autorecap) tells the model whether fetch_summary will return
# anything richer than the headline itself; see INSTRUCTIONS in server.py.
printf '<memcp-prior-sessions project="%s" count="%s">\n' "$project" "$count"
jq -r '.[] | "[\(.created_at) kind=\(.kind // "diary")] \(.headline)"' <<<"$entries"
printf '</memcp-prior-sessions>\n'

log "surfaced $count diary entries for project=$project"
exit 0
