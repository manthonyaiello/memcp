#!/usr/bin/env bash
#
# check-hook-version.sh — gate the hook release string.
#
# A surface learns it is behind by reporting its hook version to the server and
# being told the version the server shipped with. That only works while the two
# copies of the string agree, and while a change to the hooks is accompanied by
# a change to the string. Neither is enforceable by a compiler: the hooks are
# bash and the server is Ada, and "did this change matter" is not decidable. So
# both halves are checked here.
#
#   1. Agreement. MEMCP_HOOK_VERSION in scripts/hooks/hook_common.sh must equal
#      Memcp.Hooks.Hook_Version in src/memcp-hooks.ads. Disagreement makes the
#      server report a version nothing runs, so every surface looks stale at
#      once -- loud, but useless.
#
#   2. The bump. With --since REF, any change since REF to a file that lands on
#      a surface must come with a change to MEMCP_HOOK_VERSION. Strict: the
#      digest a hook reports covers every byte of hook_common.sh and the hook,
#      so after a comment-only change a deployed surface genuinely no longer
#      matches the repository, and the version is the only thing that can say
#      so. Over-reporting costs a redeploy; under-reporting is the silent drift
#      this gate exists to prevent.
#
#      deploy.sh and deploy_remote.sh are excluded by name: they run on the
#      machine holding the checkout, reach no surface and are covered by no
#      digest, so a bump for them reports a staleness redeploying cannot
#      resolve. Everything else under scripts/hooks/ is watched, including
#      files added later -- under-reporting is the costlier mistake.
#
# Usage:
#   scripts/check-hook-version.sh                  # agreement only
#   scripts/check-hook-version.sh --since origin/main
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SHELL_SRC="scripts/hooks/hook_common.sh"
ADA_SRC="src/memcp-hooks.ads"
HOOK_PATHSPEC=(scripts/hooks
               ':(exclude)scripts/hooks/deploy.sh'
               ':(exclude)scripts/hooks/deploy_remote.sh')

SINCE=""
case "${1:-}" in
  --since) SINCE="${2:?--since needs a ref}" ;;
  "")      ;;
  *)       echo "!! unknown option $1; try --since REF" >&2; exit 2 ;;
esac

fail() { echo "!! $*" >&2; exit 1; }

# The MEMCP_HOOK_VERSION assignment, read out of file $1 rather than sourced: a
# gate must not run the thing it is gating.
shell_version() {
    sed -n 's/^MEMCP_HOOK_VERSION="\([^"]*\)".*/\1/p' "$1" | head -n 1
}

# The Hook_Version constant, read out of file $1.
ada_version() {
    sed -n 's/.*Hook_Version[[:space:]]*:[[:space:]]*constant[[:space:]]*String[[:space:]]*:=[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$1" | head -n 1
}

# --- 1. the two constants agree ---------------------------------------------

shell_v=$(shell_version "$SHELL_SRC")
ada_v=$(ada_version "$ADA_SRC")

[[ -n "$shell_v" ]] || fail "no MEMCP_HOOK_VERSION found in $SHELL_SRC"
[[ -n "$ada_v"   ]] || fail "no Hook_Version found in $ADA_SRC"

if [[ "$shell_v" != "$ada_v" ]]; then
    fail "hook version disagrees: $SHELL_SRC says $shell_v, $ADA_SRC says $ada_v"
fi

echo "ok: hook version $shell_v agrees across $SHELL_SRC and $ADA_SRC"

# --- 2. a hook change came with a bump --------------------------------------

[[ -n "$SINCE" ]] || exit 0

if ! git rev-parse --verify --quiet "$SINCE" >/dev/null; then
    fail "cannot resolve $SINCE; fetch it before running with --since"
fi

changed=$(git diff --name-only "$SINCE" -- "${HOOK_PATHSPEC[@]}")
if [[ -z "$changed" ]]; then
    echo "ok: no hook changes since $SINCE"
    exit 0
fi

# Read the old value out of the ref rather than diffing the line, so a
# reformatted assignment does not read as a bump.
was=$(git show "$SINCE:$SHELL_SRC" 2>/dev/null | shell_version /dev/stdin || true)

if [[ -z "$was" ]]; then
    echo "ok: $SHELL_SRC carried no version at $SINCE; nothing to compare"
    exit 0
fi

if [[ "$was" == "$shell_v" ]]; then
    echo "!! these files changed since $SINCE:" >&2
    while IFS= read -r f; do printf '     %s\n' "$f" >&2; done <<<"$changed"
    fail "MEMCP_HOOK_VERSION is still $shell_v; bump it (and $ADA_SRC) so deployed surfaces are told they are behind"
fi

echo "ok: hook version moved $was -> $shell_v alongside the hook changes"
