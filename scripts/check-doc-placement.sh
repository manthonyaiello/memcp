#!/usr/bin/env bash
#
# check-doc-placement.sh -- find doc comments attached to the wrong entity.
#
# Under gnatdoc --style=gnat, which the AdaCore LSP plugins follow, a comment
# block documents the declaration ABOVE it. So a block placed *before* a
# declaration is not merely dropped: it becomes the hover text of the preceding
# entity, shown against the wrong name. This script reports those.
#
# Exceptions, both real:
#   * A block above a package or generic declaration IS read, which is what
#     makes a file header work. `package` and `generic` are not flagged.
#   * A banner (`-- Open --` between rules) is not documentation.
#
# Specs and bodies alike: hover works in both.
#
# The tree is clean, so this gates: `make docs-check` runs it after check-docs.sh
# and CI fails on a regression. It needs no toolchain -- awk over `git ls-files`
# -- so it runs on a bare checkout, before anything is built.
#
# One gotcha if you edit the rules below: opens() fires on any line ENDING in
# `is`, `declare`, `private` or `record`, and it does not know a comment from
# code. A doc block whose prose happens to end a line with one of those words
# makes the NEXT comment line look block-initial, which reports a finding
# against whatever declaration follows. The fix is to reword the prose.
#
# Usage:
#   scripts/check-doc-placement.sh            report and FAIL on any finding
#   scripts/check-doc-placement.sh --no-gate  report only (never fails)
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
readonly ROOT_DIR="$PWD"

GATE=1
case "${1-}" in
  --no-gate) GATE=0 ;;
  "")        ;;
  *)         echo "usage: $0 [--no-gate]" >&2; exit 2 ;;
esac
readonly GATE

# git ls-files already excludes the dependency closure and Alire's untracked
# *_config.ads.
sources="$(git -C "$ROOT_DIR" ls-files '*.ads' '*.adb')"

# Vendored or generated Ada we do not author, as a path regex. Empty here; it
# stays as the one knob a port has to set (microbit, for instance, tracks
# SVD-generated register bindings whose per-field leading comments its own docs
# gate already excludes).
readonly NOT_OURS=''
if [ -n "$NOT_OURS" ]; then
  sources="$(printf '%s\n' "$sources" | grep -vE "$NOT_OURS" || true)"
fi

if [ -z "$sources" ]; then
  echo "error: no tracked Ada sources found -- wrong directory?" >&2
  exit 1
fi

findings="$(printf '%s\n' "$sources" | while IFS= read -r f; do
  awk -v F="$f" '
    function is_comment(s) { return s ~ /^[[:space:]]*--/ }
    function is_blank(s)   { return s ~ /^[[:space:]]*$/ }

    # A comment line of nothing but dashes: the rule above or below a banner.
    function is_rule(s)    { return s ~ /^[[:space:]]*-+[[:space:]]*$/ }

    # Lines that open a declarative region, so a comment block starting right
    # after one is block-initial, exactly as after a blank line.
    function opens(s) {
      return s ~ /(^|[[:space:]])(is|declare|private|record)[[:space:]]*$/
    }

    # Declarations whose doc is read from BELOW. `package` and `generic` are
    # deliberately absent (see the header). The second alternative is an object
    # declaration -- `Length : constant Natural :=`, a record component -- which
    # is where the subtlest misattributions live. `pragma` is absent: it is not
    # a declaration, which keeps a justification comment above one from reading
    # as a finding.
    function is_decl(s) {
      return s ~ /^[[:space:]]*(type|subtype|function|procedure|task|protected|entry)[[:space:]]/ \
          || s ~ /^[[:space:]]*[A-Za-z][A-Za-z0-9_]*([[:space:]]*,[[:space:]]*[A-Za-z][A-Za-z0-9_]*)*[[:space:]]*:[[:space:]]/
    }

    { L[NR] = $0 }

    END {
      for (i = 1; i <= NR; i++) {
        if (!is_comment(L[i]))                                    continue
        if (!(i == 1 || is_blank(L[i-1]) || opens(L[i-1])))        continue

        # Extent of this comment block, then the line it sits above.
        for (j = i; j < NR && is_comment(L[j+1]); j++) { }

        # A banner is not documentation.
        if (is_rule(L[i]) && is_rule(L[j])) { i = j; continue }

        if (is_decl(L[j+1])) {
          decl = L[j+1]
          sub(/^[[:space:]]+/, "", decl)
          print F ":" i ": leading block of " (j-i+1) " line(s) documents the" \
                " PRECEDING entity under --style=gnat; move it below: " decl
        }
        i = j
      }
    }
  ' "$ROOT_DIR/$f"
done)"

if [ -z "$findings" ]; then
  echo "Doc placement: no misattributed comment blocks."
  exit 0
fi

total="$(printf '%s\n' "$findings" | wc -l | tr -d ' ')"
inventory="$(printf '%s\n' "$findings" | sed 's/:.*//' | sort | uniq -c | sort -rn)"

echo "Doc placement: $total misattributed comment block(s)."
echo
printf '%s\n' "$findings"
echo
echo "Per file:"
printf '%s\n' "$inventory"
echo
echo "Each block is shown in the IDE against the declaration above it. Move it"
echo "below the declaration it describes (packages and generics are the"
echo "exception -- see $0)."

if [ -n "${GITHUB_STEP_SUMMARY-}" ]; then
  {
    echo "### Doc placement: $total misattributed comment block(s)"
    echo
    echo '```'
    printf '%s\n' "$inventory"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

[ "$GATE" -eq 0 ] || exit 1
