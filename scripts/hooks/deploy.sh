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

REMOTE="$HOOK_DIR/deploy_remote.sh"
#  Streamed to a shell on the surface rather than copied, so it stays out of
#  FILES and off the far side's disk.

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
        -h|--help) sed -n '3,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*)        echo "!! unknown option $1" >&2; exit 2 ;;
        *)         HOSTS+=("$1"); shift ;;
    esac
done

if [[ ${#HOSTS[@]} -eq 0 && $LOCAL -eq 0 ]]; then
    echo "!! nothing to do: give --local, a host, or both; try --help" >&2
    exit 2
fi

for f in "${FILES[@]}" "$(basename "$REMOTE")"; do
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
    bash -s -- "$local_dest" "$URL" "$DRY" <"$REMOTE" || failed+=("local")
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
    if ! ssh "$host" "bash -s -- '$DEST' '$URL' '$DRY'" <"$REMOTE"; then
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
