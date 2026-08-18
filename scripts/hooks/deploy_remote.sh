#!/usr/bin/env bash
#
# deploy_remote.sh — the half of deploy.sh that runs on the surface being
# installed. Streamed to `bash -s` there, never copied and never executed
# directly, so it is not part of the payload and carries no digest.
#
# Kept separate because it runs on a different machine from its caller: only
# POSIX sh features, no bash arrays, nothing from the caller's environment
# beyond the three arguments and whatever ssh forwards.
#
# Arguments, positional: $1 destination directory, unexpanded so $HOME resolves
# here; $2 MEMCP_URL, empty to leave the default; $3 1 to report and change
# nothing.

set -eu
#  An empty argument that reached ssh unquoted would arrive as no argument at
#  all, so say so rather than failing later on an unbound variable.
[ $# -eq 3 ] || { echo "   !! expected 3 arguments, got $#" >&2; exit 2; }
dest_raw=$1; url=$2; dry=$3
eval "dest=$dest_raw"
settings="$HOME/.claude/settings.json"
rc=0

fail() { echo "   !! $*" >&2; exit 1; }

#  ssh runs this without a login shell, so PATH is whatever the profile sets --
#  which on a stock Linux or macOS account excludes every directory the Claude
#  Code installers write to. Searching them is what separates "not installed"
#  from "not on this PATH". A PATH assembled by a node version manager is still
#  out of reach, which is why the failure below names where it looked.
for d in "$HOME/.local/bin" "$HOME/.claude/local" "$HOME/bin"; do
    if [ -d "$d" ]; then PATH="$PATH:$d"; fi
done
export PATH

#  claude is required, not optional: without the CLI the MCP server cannot be
#  registered, and hooks without tools are a half-deployed surface.
missing=""
for bin in curl jq base64 claude; do
    command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
done
[ -z "$missing" ] || fail "missing on this surface:$missing (searched PATH=$PATH)"

if [ "$dry" = 1 ]; then
    echo "   deps ok; would run $dest/install.sh and rewire $settings"
    exit 0
fi

[ -f "$dest/install.sh" ] || fail "scripts not present at $dest"

if [ -n "$url" ]; then
    MEMCP_URL="$url" "$dest/install.sh" >/dev/null || fail "install.sh failed"
else
    "$dest/install.sh" >/dev/null || fail "install.sh failed"
fi

cfg="$HOME/.memcp/hooks.env"
id=$(sed -n 's/.*MEMCP_SURFACE_ID:=\([^}"]*\).*/\1/p' "$cfg")
label=$(sed -n 's/.*MEMCP_SURFACE_LABEL:=\([^}"]*\).*/\1/p' "$cfg")
host=$(sed -n 's/.*MEMCP_SURFACE_HOST:=\([^}"]*\).*/\1/p' "$cfg")
echo "   surface $label ($id)"
[ "$host" = "$label" ] || echo "   !! identity was minted on $host, not $label"

# Replace memcp's own entries rather than appending, so this is idempotent;
# every other hook on the surface is preserved.
start="$dest/session_start.sh"
end="$dest/session_end.sh"
mkdir -p "$(dirname "$settings")"
[ -f "$settings" ] || echo '{}' >"$settings"
cp "$settings" "$settings.memcp-bak" || fail "could not back up $settings"

tmp=$(mktemp) || fail "mktemp failed"
jq --arg start "$start" --arg end "$end" '
  def prune($re): map(.hooks = ((.hooks // [])
                     | map(select((.command // "") | test($re) | not))))
                  | map(select((.hooks | length) > 0));
  .hooks //= {}
  | .hooks.SessionStart = ((.hooks.SessionStart // []) | prune("session_start\\.sh"))
      + [{hooks: [{type: "command", command: $start}]}]
  | .hooks.SessionEnd = ((.hooks.SessionEnd // []) | prune("session_end\\.sh"))
      + [{hooks: [{type: "command", command: $end}]}]
' "$settings" >"$tmp" || { rm -f "$tmp"; fail "jq could not rewrite $settings"; }

jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; fail "rewritten settings is not valid JSON"; }
mv "$tmp" "$settings" || fail "could not write $settings"
echo "   wired $settings (backup at $settings.memcp-bak)"

# Commands the rewrite dropped, so an orphaned copy on disk is visible here
# rather than found later. Nothing outside $dest is deleted.
orphans=$(jq -r --arg d "$dest" '
  [.. | objects | select(has("command")) | .command]
  | map(select(test("session_(start|end)\\.sh") and (startswith($d) | not)))
  | unique | .[]' "$settings.memcp-bak" 2>/dev/null || true)
if [ -n "$orphans" ]; then
    echo "   unwired, still on disk:"
    echo "$orphans" | sed 's/^/     /'
fi

# A surface with hooks and no server records nothing -- silently, by design.
eff_url=$(sed -n 's/.*MEMCP_URL:=\([^}"]*\).*/\1/p' "$cfg")
if curl -sS --max-time 5 -o /dev/null -X POST "$eff_url" \
        -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' 2>/dev/null
then
    echo "   server answers at $eff_url"
else
    echo "   !! no server at $eff_url -- hooks will no-op until one runs"
fi

# The hooks inject and upload on their own, but save/search/fetch_* reach the
# server as MCP tools, so a surface without the registration can never author a
# diary entry. Scope is user: the CLI defaults to the current directory only.
if claude mcp get memcp 2>&1 | grep -q 'No MCP server named'; then
    if claude mcp add -s user -t http memcp "$eff_url" >/dev/null 2>&1; then
        echo "   registered memcp -> $eff_url"
    else
        echo "   !! claude mcp add failed"
        rc=3
    fi
else
    have=$(claude mcp get memcp 2>&1 | sed -n 's/^  *URL: //p')
    if [ "$have" = "$eff_url" ]; then
        echo "   memcp already registered -> $have"
    else
        echo "   memcp already registered -> ${have:-unknown}, not $eff_url; left alone"
    fi
fi

exit $rc
