#!/usr/bin/env bash
#
# Pre-provision the all-MiniLM-L6-v2 model for candle_spark.
#
# The candle binding loads weights from a directory on disk -- it does NOT fetch
# from the network at runtime (decided 2026-07-13). This script is that fetch
# step: it downloads the three files candle needs (weights + tokenizer + config)
# from the Hugging Face Hub into a model directory you then point MEMCP_MODEL_PATH
# at.
#
# Usage:
#   scripts/install-model.sh [DEST_DIR]
#
# DEST_DIR defaults to $MEMCP_MODEL_PATH, else the conventional location the
# server looks in when MEMCP_MODEL_PATH is unset: ~/.memcp/models/all-MiniLM-L6-v2
# (working-directory independent, so `install-model.sh && (cd memcp && alr run)`
# works with no env var at all).
# Requires: curl. No Python, no huggingface_hub.

set -euo pipefail

REPO="sentence-transformers/all-MiniLM-L6-v2"
BASE="https://huggingface.co/${REPO}/resolve/main"
FILES=(config.json tokenizer.json model.safetensors)

DEST="${1:-${MEMCP_MODEL_PATH:-${HOME}/.memcp/models/all-MiniLM-L6-v2}}"

echo "Installing ${REPO} -> ${DEST}"
mkdir -p "${DEST}"

for f in "${FILES[@]}"; do
  out="${DEST}/${f}"
  if [[ -s "${out}" ]]; then
    echo "  = ${f} (already present, skipping)"
    continue
  fi
  echo "  + ${f}"
  # -L follows the CDN redirect; --fail turns an HTTP error into a nonzero exit.
  curl -sSL --fail -o "${out}.part" "${BASE}/${f}"
  mv "${out}.part" "${out}"
done

RESOLVED="$(cd "${DEST}" && pwd)"
DEFAULT="${HOME}/.memcp/models/all-MiniLM-L6-v2"
echo "Done."
if [[ "${RESOLVED}" == "${DEFAULT}" ]]; then
  echo "Installed at the conventional location -- the server finds it with no"
  echo "env var. (Override anytime with MEMCP_MODEL_PATH.)"
else
  echo "Point the server at it with:"
  echo "  export MEMCP_MODEL_PATH=\"${RESOLVED}\""
fi
