#!/usr/bin/env bash
#
# Vendor the C sources sqlite_vec_spark binds to: the SQLite amalgamation and
# the sqlite-vec extension amalgamation. Both are compiled straight into the
# Ada library by this crate's GPR (Languages => ("Ada", "C")) -- there is no
# system libsqlite3 dependency and no separate build system.
#
# The fetched sources are version- and sha256-PINNED (below) and .gitignore'd,
# mirroring candle_spark/scripts/install-model.sh: the repo stays light,
# the build is reproducible, and a supply-chain swap trips the checksum. Run
# once before the first `alr build`; it is a no-op when the files are present.
#
# Usage:  scripts/fetch-deps.sh
# Requires: curl, shasum, unzip, tar. No system SQLite, no package manager.

set -euo pipefail

# --- pinned versions + checksums -------------------------------------------
# SQLite amalgamation 3.53.3 (2026-06-26). Path year is the release year.
SQLITE_URL="https://www.sqlite.org/2026/sqlite-amalgamation-3530300.zip"
SQLITE_SHA256="646421e12aac110282ef8cc68f1a62d4bb15fc7b8f09da0b53e29ee690500431"
SQLITE_SUBDIR="sqlite-amalgamation-3530300"

# sqlite-vec 0.1.9 amalgamation (asg017/sqlite-vec).
VEC_URL="https://github.com/asg017/sqlite-vec/releases/download/v0.1.9/sqlite-vec-0.1.9-amalgamation.tar.gz"
VEC_SHA256="3acd67cb4aff080c7050926fd3cf8227905fe5b7ee3829d8ee5024ab1283cf61"
# ---------------------------------------------------------------------------

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${HERE}/csrc"
mkdir -p "${DEST}"

# verify SHA <file> <expected>: fail loudly on mismatch.
verify() {
  local got
  got="$(shasum -a 256 "$1" | awk '{print $1}')"
  if [[ "${got}" != "$2" ]]; then
    echo "  ! checksum mismatch for $1" >&2
    echo "    expected $2" >&2
    echo "    got      ${got}" >&2
    exit 1
  fi
}

if [[ -s "${DEST}/sqlite3.c" && -s "${DEST}/sqlite3.h" ]]; then
  echo "= sqlite3 amalgamation (already present, skipping)"
else
  echo "+ sqlite3 amalgamation ${SQLITE_SUBDIR}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  curl -sSL --fail -o "${tmp}/sqlite.zip" "${SQLITE_URL}"
  verify "${tmp}/sqlite.zip" "${SQLITE_SHA256}"
  unzip -q "${tmp}/sqlite.zip" -d "${tmp}"
  cp "${tmp}/${SQLITE_SUBDIR}/sqlite3.c" "${tmp}/${SQLITE_SUBDIR}/sqlite3.h" "${DEST}/"
  rm -rf "${tmp}"
  trap - EXIT
fi

if [[ -s "${DEST}/sqlite-vec.c" && -s "${DEST}/sqlite-vec.h" ]]; then
  echo "= sqlite-vec amalgamation (already present, skipping)"
else
  echo "+ sqlite-vec amalgamation v0.1.9"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  curl -sSL --fail -o "${tmp}/vec.tar.gz" "${VEC_URL}"
  verify "${tmp}/vec.tar.gz" "${VEC_SHA256}"
  tar xzf "${tmp}/vec.tar.gz" -C "${tmp}"
  cp "${tmp}/sqlite-vec.c" "${tmp}/sqlite-vec.h" "${DEST}/"
  rm -rf "${tmp}"
  trap - EXIT
fi

echo "Done. Vendored C sources are in ${DEST} (git-ignored). Now: alr build"
