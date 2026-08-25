#!/usr/bin/env bash
# memcp SessionStart hook.
#
# Reads the Claude Code SessionStart payload from stdin (JSON with at least
# `session_id`, `cwd`, and `source`), derives the project key, looks up recent
# Headers for it via the `recent` MCP tool, and prints them to stdout so
# Claude Code adds them to the first-turn context.
#
# `<memcp-session/>` carries the session id and the derived project key. The
# key is derived here and used verbatim by the model, so the summary the model
# saves and the transcript the SessionEnd hook uploads land under one project
# instead of two independently guessed ones.
#
# Every failure path emits a `<memcp-hook-error/>` block naming the fault and
# its remedy, so an outage reaches the user on turn one instead of looking like
# a session with no history. Exit status is 0 on every path — a memcp outage
# must never break Claude Code startup.
#
# `<memcp-hook-stale/>` is the same idea for a working-but-behind surface: the
# server reports the release it shipped with, and the remedy is a redeploy the
# user has to arrange, since this surface holds no checkout to update itself
# from.
#
# `recent` answers with `entries`, plus `findings` naming surfaces whose
# sessions save summaries with no transcript behind them. Those are fleet-wide
# and recomputed per call: a surface whose hooks have stopped cannot report
# itself, so every other surface reports it, and nothing is written down.
#
# Configure (environment overrides the config file; see install.sh):
#   MEMCP_CONFIG   config file (default: $HOME/.memcp/hooks.env)
#   MEMCP_URL      MCP endpoint (default: http://127.0.0.1:8786/mcp)
#   MEMCP_PROJECT  project key, overriding derivation
#   MEMCP_RECENT_N number of entries to surface (default: 5)
#
# Install in ~/.claude/settings.json (or per-project .claude/settings.json):
#   "hooks": { "SessionStart": [ { "hooks": [
#       { "type": "command",
#         "command": "/abs/path/to/memcp/scripts/hooks/session_start.sh" } ] } ] }

set -uo pipefail

HOOK_NAME="session_start"
HOOK_PATH="${BASH_SOURCE[0]}"
HOOK_DIR="$(cd -- "$(dirname -- "$HOOK_PATH")" && pwd)"

# The library carries the derivation and the emission helpers, so its absence
# has to report itself without them.
if ! . "$HOOK_DIR/hook_common.sh"; then
    printf '<memcp-hook-error hook="session_start" fault="library-missing">\n'
    printf 'hook_common.sh is missing from %s, so the memcp SessionStart hook could not run and no prior-session context was injected.\n' "$HOOK_DIR"
    printf 'Remedy: reinstall the hooks from the memcp checkout (scripts/hooks/install.sh).\n'
    printf 'Tell the user memcp is not recording this session, then continue.\n'
    printf '</memcp-hook-error>\n'
    exit 0
fi

memcp_load_config

MEMCP_URL="${MEMCP_URL:-http://127.0.0.1:8786/mcp}"
RECENT_N="${MEMCP_RECENT_N:-5}"
PROTO_VER="2025-06-18"

log() { echo "memcp-hook: $*" >&2; }

# Emit the fault, log it, and stop. Startup is never blocked, so this exits 0.
fault() {
    memcp_fault "$HOOK_NAME" "$1" "$2" "$3"
    log "$1"
    exit 0
}

memcp_check_digest "$HOOK_NAME" "$HOOK_PATH"

for bin in curl jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        fault "missing-dependency" \
            "The memcp SessionStart hook needs \`$bin\`, which is not on PATH; no prior-session context was injected." \
            "Install $bin and start a new session."
    fi
done

payload=$(cat)
if [[ -z "$payload" ]]; then
    fault "empty-payload" \
        "The memcp SessionStart hook received an empty payload on stdin, so it could not identify the session or the project." \
        "Check the SessionStart hook wiring in ~/.claude/settings.json."
fi

source_kind=$(jq -r '.source // empty' <<<"$payload" 2>/dev/null || true)
cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null || true)
session_id=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)

# `resume` and `compact` still get the identity block — the model needs the key
# to save under, and a compaction can drop it — but not the Header listing,
# which duplicates context the model already has.
list_prior=1
case "$source_kind" in
    startup|clear|"") : ;;  # empty source = older Claude Code; behave like startup
    *) list_prior=0 ;;
esac

project="${MEMCP_PROJECT:-}"
if [[ -z "$project" ]]; then
    project=$(memcp_project_key "$cwd")
fi
if ! memcp_valid_key "$project"; then
    fault "no-project" \
        "The memcp SessionStart hook could not derive a project key (cwd=${cwd:-unset}), so nothing can be filed for this session." \
        "Run Claude Code from inside the project directory, or set MEMCP_PROJECT."
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
body="$tmpdir/body"

init_body=$(jq -nc \
    --arg proto "$PROTO_VER" \
    --arg version "$(memcp_client_version "$HOOK_PATH")" \
    '{jsonrpc:"2.0",id:1,method:"initialize",params:{
        protocolVersion:$proto,capabilities:{},
        clientInfo:{name:"memcp-session-start",version:$version}}}')

if ! curl -sS --max-time 10 -o "$body" \
        -X POST "$MEMCP_URL" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -H "MCP-Protocol-Version: ${PROTO_VER}" \
        -d "$init_body"; then
    fault "server-unreachable" \
        "The memcp server did not answer at $MEMCP_URL, so no prior-session context was injected and nothing will be recorded for this session." \
        "Start the memcp server (make run), or point MEMCP_URL at the right endpoint."
fi

# memcp assigns no session, so initialize is the whole handshake: there is no
# id to carry, and `notifications/initialized` is discarded unread.
if ! memcp_is_rpc "$(cat "$body")"; then
    fault "initialize-rejected" \
        "The server at $MEMCP_URL answered initialize with something that is not an MCP response, so no prior-session context was injected." \
        "Check that MEMCP_URL points at memcp and not at another HTTP service."
fi

# Before the early exit below: a resumed session needs the report as much as a
# fresh one, and nothing about it depends on the Header listing.
expected=$(memcp_stale_expected "$body")
if [[ -n "$expected" ]]; then
    memcp_stale "$HOOK_NAME" "$expected"
    log "hooks $MEMCP_HOOK_VERSION, server shipped $expected"
fi

surface=$(memcp_surface_ref)

# The handshake held, so the model can save. The key is derived once, here.
emit_session_block() {
    printf '<memcp-session id="%s" project="%s" surface="%s">\n' \
        "$session_id" "$project" "$surface"
    printf 'Pass project="%s", session_id="%s" and surface="%s" verbatim to every memcp tool call in this session. Do not derive or abbreviate any of them.\n' \
        "$project" "$session_id" "$surface"
    printf '</memcp-session>\n'
}

if [[ "$list_prior" == "0" ]]; then
    emit_session_block
    log "surfaced project=$project (source=$source_kind; no Header listing)"
    exit 0
fi

# The surface rides on `recent` too: it is what records this surface as still
# working, and what the server answers a warning to when it is missing.
#
# The three facts alongside it are this surface's report on itself, and this is
# the only call that can carry them: the model's calls know none of them, and
# `initialize` carries a version with no surface to attach it to. Recorded,
# they stay readable once this surface stops calling, which is when a diagnosis
# needs them most.
recent_body=$(jq -nc \
    --arg project "$project" \
    --arg surface "$surface" \
    --arg hook_version "$MEMCP_HOOK_VERSION" \
    --arg host "$(memcp_hostname)" \
    --arg install_host "$(memcp_install_host)" \
    --argjson n "$RECENT_N" \
    '{jsonrpc:"2.0",id:2,method:"tools/call",params:{
        name:"recent",
        arguments:{projects:[$project],n:$n,surface:$surface,
                   hook_version:$hook_version,host:$host,
                   install_host:$install_host}}}')

data=$(curl -sS --max-time 10 -X POST "$MEMCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -H "MCP-Protocol-Version: ${PROTO_VER}" \
    -d "$recent_body") || {
    fault "tool-call-failed" \
        "The memcp server at $MEMCP_URL dropped the \`recent\` call, so no prior-session context was injected." \
        "Check the memcp server log, then restart it (make run)."
}

if ! memcp_is_rpc "$data"; then
    fault "malformed-response" \
        "The server at $MEMCP_URL answered \`recent\` with a body that is not an MCP response, so no prior-session context was injected." \
        "Check that MEMCP_URL points at memcp and not at another HTTP service."
fi

err=$(memcp_tool_error "$data")
if [[ -n "$err" ]]; then
    fault "tool-error" \
        "The memcp \`recent\` tool failed: $err. No prior-session context was injected." \
        "Check the memcp server log; a tool error usually means a schema or database fault on the server."
fi

emit_session_block

result=$(memcp_tool_result "$data")
[[ -n "$result" ]] || result='{}'

memcp_unattributed "$HOOK_NAME" "$(jq -r '.warning // empty' <<<"$result")"
memcp_degraded "$(jq -c '.findings // []' <<<"$result")"

entries=$(jq -c '.entries // []' <<<"$result" 2>/dev/null || echo '[]')
count=$(jq 'length' <<<"$entries" 2>/dev/null || echo 0)

if [[ "$count" == "0" ]]; then
    log "no prior Headers for project=$project"
    exit 0
fi

# Surface to Claude. Headers only — bodies are recoverable via fetch_summary.
# `kind` (authored|autorecap) tells the model whether fetch_summary will return
# anything richer than the Header itself.
printf '<memcp-prior-sessions project="%s" count="%s">\n' "$project" "$count"
jq -r '.[] | "[\(.created_at) kind=\(.kind // "authored")] \(.header)"' <<<"$entries"
printf '</memcp-prior-sessions>\n'

log "surfaced $count Headers for project=$project"
exit 0
