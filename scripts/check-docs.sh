#!/usr/bin/env bash
#
# GNATdoc generation + the documentation gate (issue #22).
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# `gnatdoc --warnings` reports every undocumented entity -- and then exits 0
# regardless. It is a report, not a check. So a "no undocumented entities" gate
# cannot be a bare gnatdoc invocation: something has to read the report and set
# the exit status. That is this script, and it is the same split the Makefile
# already draws between `make prove` (informational) and `make prove-check`
# (the gate, scripts/check-proof.sh).
#
# It also does two things a bare invocation cannot:
#
#   * Runs EVERY project root. memcp.gpr's closure (src + the three binding
#     crates, via config/memcp_config.gpr) is not the whole repo: the proof
#     harness and the four test/smoke drivers are separate roots.
#   * Verifies each run actually produced its entry-point index.html. A run can
#     exit 0, emit no warnings, and still have generated nothing.
#
# STYLE: --style=gnat, i.e. doc comments sit BELOW the declaration they
# describe, and @param/@return/@enum are mandatory (that is what --warnings
# checks). There is no GPR attribute for the style, so this script is the
# durable record of it.
#
# This gate cannot check PLACEMENT, and must not be read as doing so. A block on
# the wrong side of a declaration is attributed to the declaration above it, so
# the entity below reads as undocumented while the entity above silently acquires
# someone else's description -- and --warnings is per entity, not per
# declaration, so a misplaced block that happens to satisfy its new owner is
# invisible here. That is how issue #22's orphaned block survived a clean gate.
# scripts/check-doc-placement.sh is the source-level lint that does check it.
#
# SCOPE: --generate=private, so private-part representations -- which in SPARK
# carry real design content (full views of the ownership handles, the
# reclamation predicate completions) -- are documented too.
#
# Usage:
#   scripts/check-docs.sh            generate, report, and FAIL on any
#                                    undocumented entity in our own sources
#   scripts/check-docs.sh --no-gate  generate and report only (never fails)
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
readonly ROOT_DIR="$PWD"
readonly OUT_DIR="$ROOT_DIR/docs/api"
readonly LOG="$ROOT_DIR/gnatdoc-run.txt"

GATE=1
case "${1-}" in
  --no-gate) GATE=0 ;;
  "") ;;
  *) echo "usage: $0 [--no-gate]" >&2; exit 2 ;;
esac

# gnatdoc is a tool, not something memcp links against, so it is NOT a crate
# dependency: putting it in alire.toml would make every job and every fresh
# checkout fetch a binary crate it never uses, because alr materializes the
# whole solution before building. Installed explicitly instead, exactly as
# prove.yml installs gnatprove -- and pinned, for the same reason: the set of
# warnings IS the gate, so a silent version bump must not be able to change
# what CI accepts.
#
# 26.0.0 specifically: gnatdoc historically shipped with GNAT Studio / GNAT Pro
# rather than the FSF toolchain, and the move to FSF GNAT 16.1.0 left `make
# docs` with no gnatdoc at all (issue #22). The `gnatdoc` *source* crate does
# not build here -- it drags in libadalang/libgpr2/vss, exactly where a
# toolchain mismatch bites -- but the binary crate does, and 26.x is the
# generation that pairs with gnat_native 16.1.0.
readonly GNATDOC_PIN="gnatdoc_bin=26.0.0"
if ! command -v gnatdoc >/dev/null 2>&1; then
  cat >&2 <<EOF
error: gnatdoc is not on PATH.

Install the pinned version and put Alire's bin directory on your PATH:

    alr -n install $GNATDOC_PIN
    export PATH="\$HOME/.alire/bin:\$PATH"
EOF
  exit 2
fi

# Every project root. All of them are driven from the repo root: memcp is a
# single Alire crate, and the binding crates under crates/ are path
# dependencies inside the same workspace, so one `alr exec` environment covers
# the lot (unlike the microbit repo, whose test crate is its own crate).
#
# The four test/smoke roots contribute no entities of their own at
# --generate=private -- their only sources are driver bodies -- so today every
# warning they report is a duplicate of memcp.gpr's closure. They are still
# driven here rather than dropped: the cost is a couple of seconds each, and
# the moment a driver grows a spec the gate should already cover it.
readonly ROOTS=(
  "memcp.gpr"
  "crates/spark_mcp/spark_mcp_prove.gpr"
  "tests/memcp_tests.gpr"
  "crates/spark_mcp/tests/spark_mcp_tests.gpr"
  "crates/spark_mcp/tests/http_smoke.gpr"
  "crates/sqlite_vec_spark/tests/sqlite_smoke.gpr"
)

# Entities we do not author, and therefore do not document. gnatdoc walks the
# full dependency graph and reports on all of it; the whole SPARKlib +
# json-spark closure is roughly 5,100 warnings against our own few dozen.
# Documentation'Excluded_Project_Files cannot help: it needs paths to project
# files that live in machine-specific Alire cache locations. Warning lines
# carry only a basename, so the scope filter is by unit name:
#
#   spark.ads, spark-*   SPARKlib (containers, lemmas, pointers, C strings)
#   json*                json-spark, developed in its own repo and session
#   *_config.ads         Alire-generated, gitignored crate config
#
# Note `spark[-.]` and not `spark*`: our own spark_mcp crate must stay in
# scope, and an underscore is not a hyphen or a dot.
#
# Deliberately NOT filtered: warnings on .gpr files. Those are project
# problems (a missing object directory, say), not documentation debt, and a
# real one should fail the gate rather than hide. They do mean the gate needs a
# provisioned tree -- `make docs`/`docs-check` depend on that, see the Makefile.
readonly NOT_OURS='^(spark[-.]|json[-.]|json\.ads)|_config\.ads:'

# A GNATdoc 26.0.0 limitation, not documentation debt: the generic formal of a
# generic *subprogram* can be documented in no way the tool credits. Probed
# every spelling against Spark_Mcp.Http.Serve (`with procedure On_Request`),
# each time re-running gnatdoc over spark_mcp_prove.gpr:
#
#   * `@formal On_Request ...` in the unit's trailing block (where the tag
#     belongs, and where the SAME tag works for the generic *package*
#     Spark_Mcp.Server -- which reports zero warnings) is rejected outright:
#     "tag `@formal` is not allowed".
#   * The same tag in a leading block above `generic` is accepted -- the "not
#     allowed" warning goes away -- but the formal is still reported
#     undocumented, so the tag is parsed and then dropped.
#   * A plain comment block on the formal declaration itself, leading or
#     trailing, is likewise never credited.
#   * `@param On_Request ...` in the unit block is accepted and also ignored:
#     a formal is not a parameter.
#
# So the source keeps the form a human should read -- a trailing comment on the
# formal, matching --style=gnat -- and the gate carries this one exception. It
# is written as an exact message match, not a per-unit filter: any OTHER
# undocumented entity in that unit still fails, and the day gnatdoc learns to
# associate the formal this line simply stops matching. Reported below rather
# than silently dropped, so it cannot rot unnoticed.
readonly TOOL_LIMITS='^spark_mcp-http-serve\.ads:[0-9]+:[0-9]+: warning: generic formal `On_Request` is not documented$'

# gnatdoc does not create a project's object or exec directory, and warns
# ("object directory ... not found") when one is missing -- which it is for the
# proof harness and the four test drivers, whose obj/ and bin/ are gitignored
# and only ever created by a build the doc gate does not run. Since .gpr
# warnings are deliberately in scope (above), create the directories instead of
# filtering their absence. The Makefile's order-only prerequisite covers the
# root closure's dirs; these five roots are not in it.
mkdir -p "$ROOT_DIR/crates/spark_mcp/obj/prove" \
         "$ROOT_DIR/crates/spark_mcp/tests/obj" \
         "$ROOT_DIR/crates/spark_mcp/tests/bin" \
         "$ROOT_DIR/crates/sqlite_vec_spark/tests/obj" \
         "$ROOT_DIR/tests/obj" \
         "$ROOT_DIR/tests/bin"

: > "$LOG"
mkdir -p "$OUT_DIR"

for gpr in "${ROOTS[@]}"; do
  slug="$(basename "$gpr" .gpr)"

  # memcp.gpr carries `Documentation'Output_Dir` and so lands in docs/api/ with
  # no -O at all -- that is the doc site a human actually reads, and leaving it
  # to the attribute keeps a bare `gnatdoc -P memcp.gpr` (from an IDE, say)
  # landing in the same place. The auxiliary roots exist to make the gate
  # complete, not to be browsed, so they are steered to subdirectories with -O.
  if [ "$gpr" = "memcp.gpr" ]; then
    out="$OUT_DIR"
    explicit_out=""
  else
    out="$OUT_DIR/$slug"
    explicit_out="$out"
  fi

  # Two spellings rather than an optional array element: an empty "${a[@]}" is
  # an unbound-variable error under `set -u` in bash 3.2, which is what macOS
  # ships, so this has to stay array-free to run on a dev machine.
  echo "== $gpr" | tee -a "$LOG"
  if [ -n "$explicit_out" ]; then
    alr exec -- gnatdoc --style=gnat --generate=private --warnings \
      -P "$gpr" -O "$explicit_out" 2>&1 | tee -a "$LOG"
  else
    alr exec -- gnatdoc --style=gnat --generate=private --warnings \
      -P "$gpr" 2>&1 | tee -a "$LOG"
  fi

  if [ ! -f "$out/index.html" ]; then
    echo "error: $gpr produced no ${out#"$ROOT_DIR"/}/index.html" >&2
    exit 1
  fi
done

# One entity reported by several roots is one piece of work, so dedupe before
# counting: every auxiliary root re-reports memcp.gpr's whole closure.
#
# `internal error` belongs in this pattern. gnatdoc writes it, with a traceback,
# when it gives up on a declaration -- and that is the one severity meaning an
# entity was neither documented NOR reported, so a pattern matching only
# warning|error scores a skipped declaration as a clean one. Only the single
# `internal error:` line per site matches; the `raised ...`, `Load address:` and
# traceback lines that follow carry no severity word.
ours="$(grep -E ':[0-9]+:[0-9]+: (warning|error|internal error):' "$LOG" \
        | grep -vE "$NOT_OURS" | sort -u || true)"
crashes="$(printf '%s\n' "$ours" | grep -E ': internal error:' | sed '/^$/d' || true)"
ours="$(printf '%s\n' "$ours" | grep -vE ': internal error:' | sed '/^$/d' || true)"
findings="$(printf '%s\n' "$ours" | grep -vE "$TOOL_LIMITS" | sed '/^$/d' || true)"
limits="$(printf '%s\n' "$ours" | grep -E "$TOOL_LIMITS" || true)"

# Output that is neither a diagnostic nor framing, so that a tool inventing a new
# output shape cannot hide behind a pattern written for the old one. 26.0.0
# prints a bare AST node for a package renaming declaration -- our own
# `package MS renames Memcp.Store;` among them -- with no file:line prefix, no
# severity, and no "not documented". The renamed package is never reported
# either way, so no pattern over diagnostics can reach it; only noticing the
# unexplained line can.
unaccounted="$(grep -vE '^(==|[A-Za-z0-9_.-]+:[0-9]+:[0-9]+:|Note:|Success:|error:|warning:)' "$LOG" \
               | sed '/^$/d' | sort -u || true)"

if [ -n "$limits" ]; then
  echo
  echo "GNATdoc: known tool limitations, not gated (see TOOL_LIMITS in $0):"
  printf '%s\n' "$limits"
fi

# Not gated: a gnatdoc crash is not fixable from here. Stated every run, because
# each line is a declaration that silently did NOT reach docs/api/.
if [ -n "$crashes" ]; then
  n="$(printf '%s\n' "$crashes" | wc -l | tr -d ' ')"
  echo
  echo "GNATdoc: $n declaration(s) CRASHED the tool and were skipped entirely --"
  echo "not documented, not reported, absent from docs/api/:"
  printf '%s\n' "$crashes"
fi

# Not gated either, for the same reason, and equally deliberate: these carry no
# severity at all, so the findings pattern above is blind to them by construction.
if [ -n "$unaccounted" ]; then
  n="$(printf '%s\n' "$unaccounted" | wc -l | tr -d ' ')"
  echo
  echo "GNATdoc: $n line(s) of output matching no known diagnostic shape."
  echo "Each is a declaration the tool neither documented nor reported:"
  printf '%s\n' "$unaccounted"
fi

if [ -z "$findings" ]; then
  echo
  echo "GNATdoc: no undocumented entities in our sources. HTML in docs/api/."
  exit 0
fi

total="$(printf '%s\n' "$findings" | wc -l | tr -d ' ')"
inventory="$(printf '%s\n' "$findings" | sed 's/:.*//' | sort | uniq -c | sort -rn)"

echo
echo "GNATdoc: $total undocumented entities (deduped across roots)."
echo
echo "Per unit:"
printf '%s\n' "$inventory"
echo
echo "Full report: ${LOG#"$ROOT_DIR"/}"

# CI: same inventory in the job summary, so a failure is readable without
# opening the log.
if [ -n "${GITHUB_STEP_SUMMARY-}" ]; then
  {
    echo "### GNATdoc: $total undocumented entities"
    echo
    echo '```'
    printf '%s\n' "$inventory"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

[ "$GATE" -eq 0 ] || exit 1
