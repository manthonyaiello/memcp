#!/usr/bin/env bash
#
# check-proof.sh — run GNATprove and gate the result against an allowlist.
#
# The whole memcp crate proves to SPARK Silver (AoRTE, --level=2) with nothing
# unproved anywhere in the closure, SPARKlib included. The allowlist
# (scripts/proof-xfail.txt) is therefore empty and the gate demands a fully
# clean proof: any unproved check at all is a regression.
#
# The allowlist holds substring patterns rather than exact check identities,
# because an upstream gap need not present identically on every platform — the
# provers can clear on a fast arm64 dev machine what they miss on the x86_64 CI
# runner. So if a gap does resurface, one vetted pattern covers it everywhere.
# The gate is:
#
#   * an unproved check is ACCEPTED if its identity matches any allowlist pattern;
#   * FAIL if any unproved check matches NO pattern.
#
# Usage:
#   scripts/check-proof.sh          # prove, then gate  (exit 1 on regression)
#   scripts/check-proof.sh --list   # prove, then just list the unproved checks
#                                   # (use it to craft allowlist patterns)
#
# Env:
#   ALR             path to the alr binary (default: alr)
#   GNATPROVE_EXTRA extra flags appended to the gnatprove invocation (default
#                   none). CI sets this to "--timeout=10": --level timeouts are
#                   wall-clock, not step-bounded, so checks that clear on a fast
#                   dev machine can time out on the slower CI runner. The extra
#                   wall-clock reduces that flakiness without weakening --level.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ALR="${ALR:-alr}"
XFAIL="scripts/proof-xfail.txt"
OUT="obj/development/gnatprove/gnatprove.out"

LIST=0
case "${1:-}" in
  --list|--update) LIST=1 ;;
esac

# Unquoted on the command line below so it word-splits into flags when set and
# expands to nothing when empty (safe under `set -u`).
EXTRA="${GNATPROVE_EXTRA:-}"

echo ">> alr gnatprove -P memcp.gpr -j0 --level=2 $EXTRA"
# GNATprove exits non-zero when checks are unproved. We do our own gating from
# gnatprove.out below, so don't let its exit status abort the script here.
# $EXTRA is intentionally unquoted so it splits into separate flags (or
# disappears when empty).
# shellcheck disable=SC2086
"$ALR" gnatprove -P memcp.gpr -j0 --level=2 $EXTRA || true

[ -f "$OUT" ] || { echo "!! no GNATprove output at $OUT" >&2; exit 2; }

# --- parse gnatprove.out ------------------------------------------------------

# Identity (subprogram @ location) of every unit with an unproved check. The
# detailed unit listing reports these as ".. and not proved, N out of M proved";
# keep the part before " flow analyzed" as a stable, whitespace-normal key.
extract_failures() {
  # grep exits 1 when there are no unproved checks; tolerate that so `set -o
  # pipefail` doesn't abort the script.
  { grep -F ' and not proved' "$OUT" || true; } \
    | sed -E 's/^[[:space:]]+//; s/ flow analyzed.*$//' \
    | sort -u
}

ACTUAL_FAILS="$(extract_failures)"

# --- --list: just show what is unproved and exit ------------------------------

if [ "$LIST" -eq 1 ]; then
  if [ -z "$ACTUAL_FAILS" ]; then
    echo ">> no unproved checks."
  else
    echo ">> unproved checks (add a substring of each acceptable one to $XFAIL):"
    printf '%s\n' "$ACTUAL_FAILS" | sed 's/^/     /'
  fi
  exit 0
fi

[ -f "$XFAIL" ] || { echo "!! missing allowlist $XFAIL" >&2; exit 2; }

# --- gate: every unproved check must match an allowlist pattern ---------------

# Allowlist = non-comment, non-blank lines, each a fixed substring pattern.
PATTERNS="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$XFAIL" || true)"

allowed()  {  # $1 = failure identity; true if it matches any allowlist pattern
  local fail="$1" p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$fail" in *"$p"*) return 0 ;; esac
  done <<< "$PATTERNS"
  return 1
}

regressions=""
allowed_n=0
while IFS= read -r fail; do
  [ -z "$fail" ] && continue
  if allowed "$fail"; then
    allowed_n=$((allowed_n + 1))
  else
    regressions="${regressions}${fail}"$'\n'
  fi
done <<< "$ACTUAL_FAILS"

if [ -n "$regressions" ]; then
  echo ""
  echo "!! PROOF REGRESSION — unproved check(s) not covered by $XFAIL:" >&2
  printf '%s' "$regressions" | sed 's/^/     /' >&2
  echo "" >&2
  echo "   If this is a newly-vetted upstream gap, add a substring pattern to" >&2
  echo "   $XFAIL (see it with: $0 --list). Otherwise it is a real regression." >&2
  exit 1
fi

echo ""
if [ "$allowed_n" -eq 0 ]; then
  echo ">> PROOF OK — no unproved checks."
else
  echo ">> PROOF OK — ${allowed_n} unproved check(s), all allowed by $XFAIL."
fi
exit 0
