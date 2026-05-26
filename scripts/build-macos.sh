#!/usr/bin/env bash
# Cascade macOS build: patches → overlay → tauri build (DMG + .app).
# Requires:
#   - Rust toolchain matching vendor/screenpipe/rust-toolchain.toml
#   - bun >= 1.3
#   - Tauri CLI v2.x (installed via `bun add -D @tauri-apps/cli@=2.10.0` in screenpipe-app-tauri)
#   - For SIGNED builds: APPLE_SIGNING_IDENTITY env var + APPLE_NOTARIZE_* secrets
#   - For UNSIGNED dev builds: leave APPLE_SIGNING_IDENTITY unset

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/vendor/screenpipe/apps/screenpipe-app-tauri"

echo "==> applying patches"
"$REPO_ROOT/scripts/apply-patches.sh"

echo "==> overlaying Cascade files"
"$REPO_ROOT/scripts/overlay.sh"

cd "$APP_DIR"

echo "==> installing bun deps"
bun install --frozen-lockfile

if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  echo "==> signed build (identity: $APPLE_SIGNING_IDENTITY)"
  bun run tauri:build
else
  echo "==> unsigned dev build (set APPLE_SIGNING_IDENTITY for production)"
  bun run tauri build --no-bundle || bun run tauri build
fi

echo "==> build artifacts:"
find src-tauri/target/release/bundle -maxdepth 3 -name '*.dmg' -o -name '*.app' 2>/dev/null | sort
