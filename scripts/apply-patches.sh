#!/usr/bin/env bash
# Apply the Cascade quilt patch series on top of vendor/screenpipe/.
# Idempotent: skips patches already applied. Run from repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -d vendor/screenpipe ]]; then
  echo "error: vendor/screenpipe not initialized. run: git submodule update --init --recursive" >&2
  exit 1
fi

if ! command -v quilt >/dev/null 2>&1; then
  echo "error: quilt not installed. run: brew install quilt" >&2
  exit 1
fi

export QUILT_PATCHES="$REPO_ROOT/patches"
export QUILT_SERIES="$QUILT_PATCHES/series"

cd vendor/screenpipe

# quilt push -a applies every patch in series; harmless if none unapplied.
if quilt unapplied >/dev/null 2>&1; then
  quilt push -a
  echo "patches applied"
else
  echo "all patches already applied (or series empty)"
fi
