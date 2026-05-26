#!/usr/bin/env bash
# Copy files from app-overlays/ into the vendored Screenpipe tree so the
# Tauri app picks up our Cascade components, lib helpers, and Rust commands.
# Runs AFTER apply-patches.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/app-overlays/screenpipe-app-tauri"
DST="$REPO_ROOT/vendor/screenpipe/apps/screenpipe-app-tauri"

if [[ ! -d "$DST" ]]; then
  echo "error: $DST not found. run: git submodule update --init --recursive" >&2
  exit 1
fi

if [[ ! -d "$SRC" ]]; then
  echo "nothing to overlay (no app-overlays/screenpipe-app-tauri/)"
  exit 0
fi

# rsync -a preserves perms/times and is idempotent.
rsync -a --info=NAME "$SRC/" "$DST/"

# Pipe bundle: copy our pipes into the user-local pipes dir on install (handled by
# Tauri postinstall). For dev, drop into the vendored runtime pipes dir if it exists.
PIPES_SRC="$REPO_ROOT/pipes"
if [[ -d "$PIPES_SRC" ]]; then
  mkdir -p "$DST/src-tauri/cascade_bundled_pipes"
  rsync -a --info=NAME "$PIPES_SRC/" "$DST/src-tauri/cascade_bundled_pipes/"
fi

echo "overlay applied"
