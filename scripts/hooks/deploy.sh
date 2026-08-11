#!/usr/bin/env bash
#
# deploy.sh — wire the hooks into a surface, here or over ssh.
#
# Copies the four scripts to each host, runs install.sh there so the surface
# mints its own identity, rewires that surface's settings.json onto the copies,
# and registers the MCP server if it is not registered already. --local does
# the same for this machine without copying anything: install.sh writes the
# config and prints the wiring, but applies neither.
#
# hooks.env is never copied. A surface's UUID names it for the lifetime of the
# corpus, so a config that arrives from elsewhere makes two machines claim one
# identity -- the case MEMCP_SURFACE_HOST exists to expose.
#
# Digests cover hook_common.sh concatenated with each hook, so the four files
# move as a set and install.sh re-records afterwards. Re-run after every pull.
#
# Hosts are ssh destinations and nothing else: names, users, ports and keys all
# come from the caller's ssh configuration.
#
# Usage:
#   scripts/hooks/deploy.sh --local
#   scripts/hooks/deploy.sh HOST [HOST...]
#   scripts/hooks/deploy.sh --dry-run HOST
#   scripts/hooks/deploy.sh --url http://127.0.0.1:8786/mcp HOST
#   scripts/hooks/deploy.sh --dest '$HOME/.claude/hooks/memcp' HOST
#
# Exit status is nonzero if any surface failed, after attempting them all.

set -euo pipefail

HOOK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

FILES=(hook_common.sh install.sh session_start.sh session_end.sh)
#  install.sh is deployed too: it is what mints identity on the far side.

DEST='$HOME/.claude/hooks/memcp'
#  Expanded by the remote shell, not this one. Its own directory, so the hooks
#  this replaces are unwired rather than overwritten.

URL=""
DRY=0
LOCAL=0
DEST_SET=0
HOSTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)   LOCAL=1; shift ;;
        --dry-run) DRY=1; shift ;;
        --dest)    DEST="${2:?--dest needs a path}"; DEST_SET=1; shift 2 ;;
        --url)     URL="${2:?--url needs a URL}"; shift 2 ;;
        -h|--help) sed -n '3,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*)        echo "!! unknown option $1" >&2; exit 2 ;;
        *)         HOSTS+=("$1"); shift ;;
    esac
done

if [[ ${#HOSTS[@]} -eq 0 && $LOCAL -eq 0 ]]; then
    echo "!! nothing to do: give --local, a host, or both; try --help" >&2
    exit 2
fi

for f in "${FILES[@]}"; do
    if [[ ! -f "$HOOK_DIR/$f" ]]; then
        echo "!! missing $HOOK_DIR/$f" >&2
        exit 1
    fi
done

# Both are interpolated into a command line the remote shell parses, so they
# are restricted here rather than escaped there.
case "$DEST" in
    *[\ \'\"\`\;\&\|\(\)\<\>]*)
        echo "!! --dest must not contain spaces, quotes or shell metacharacters" >&2
        exit 2 ;;
esac

case "$URL" in
    *[\ \'\"\`\;\&\|\(\)\<\>]*)
        echo "!! --url must not contain spaces, quotes or shell metacharacters" >&2
        exit 2 ;;
esac

# The far side of every ssh call. $1 dest, $2 url ("" to leave the default),
# $3 dry-run flag. Reads nothing from stdin, so it composes with -n.
remote_script() {
    cat <<'REMOTE'
set -eu
#  An empty argument that reached ssh unquoted would arrive as no argument at
#  all, so say so rather than failing later on an unbound variable.
[ $# -eq 3 ] || { echo "   !! expected 3 arguments, got $#" >&2; exit 2; }
dest_raw=$1; url=$2; dry=$3
eval "dest=$dest_raw"
settings="$HOME/.claude/settings.json"
rc=0

fail() { echo "   !! $*" >&2; exit 1; }

#  claude is required, not optional: without the CLI the MCP server cannot be
#  registered, and hooks without tools are a half-deployed surface. A
#  non-interactive ssh shell may also have a shorter PATH than a login one.
missing=""
for bin in curl jq base64 claude; do
    command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
done
[ -z "$missing" ] || fail "missing on this surface:$missing"

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
REMOTE
}

failed=()

# This machine wires to the checkout, not to a copy: the working tree is the
# live hook path here, and a copy would silently detach it from git.
if [[ $LOCAL -eq 1 ]]; then
    echo "== local"
    local_dest="$HOOK_DIR"
    if [[ $DEST_SET -eq 1 ]]; then
        eval "local_dest=$DEST"
        if [[ $DRY -eq 1 ]]; then
            echo "   would copy ${FILES[*]} -> $local_dest"
        else
            mkdir -p "$local_dest"
            for f in "${FILES[@]}"; do cp "$HOOK_DIR/$f" "$local_dest/$f"; done
        fi
    fi
    remote_script | bash -s -- "$local_dest" "$URL" "$DRY" || failed+=("local")
fi

for host in "${HOSTS[@]:-}"; do
    [[ -n "$host" ]] || continue
    echo "== $host"

    if [[ $DRY -eq 1 ]]; then
        echo "   would copy ${FILES[*]} -> $host:$DEST"
    elif ! tar -C "$HOOK_DIR" -cf - "${FILES[@]}" \
         | ssh "$host" "mkdir -p $DEST && tar -C $DEST -xf -"; then
        echo "   !! copy failed" >&2
        failed+=("$host")
        continue
    fi

    #  ssh joins its command words and the remote shell splits them again, so
    #  the arguments are quoted for that shell rather than passed as argv. DEST
    #  stays single-quoted: the remote side evals it, which is what expands
    #  $HOME there instead of here.
    if ! remote_script \
         | ssh "$host" "bash -s -- '$DEST' '$URL' '$DRY'"; then
        failed+=("$host")
    fi
done

targets=()
[[ $LOCAL -eq 1 ]] && targets+=("local")
[[ ${#HOSTS[@]} -gt 0 ]] && targets+=("${HOSTS[@]}")

echo
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "!! failed: ${failed[*]}" >&2
    exit 1
fi
echo "ok: ${targets[*]}"
