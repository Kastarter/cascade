#!/usr/bin/env bash
# Cascade macOS build: patches → overlay → tauri build (DMG + .app).
# Requires:
#   - Rust toolchain matching vendor/screenpipe/rust-toolchain.toml
#   - bun >= 1.3
#   - Tauri CLI v2.x (installed via `bun add -D @tauri-apps/cli@=2.10.0` in screenpipe-app-tauri)
#   - For signed builds: CASCADE_SIGNING_IDENTITY or APPLE_SIGNING_IDENTITY.
#   - If unset, the script auto-detects Developer ID Application or Apple Development.

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

IDENTITY="${CASCADE_SIGNING_IDENTITY:-${APPLE_SIGNING_IDENTITY:-}}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(bash scripts/cascade_codesign_macos_app.sh --detect-identity || true)"
fi

if [[ -n "$IDENTITY" ]]; then
  echo "==> signed build (identity: $IDENTITY)"
  CASCADE_SIGNING_IDENTITY="$IDENTITY" bun run tauri:build
else
  echo "==> unsigned build (set CASCADE_SIGNING_IDENTITY for stable macOS permissions)"
  bun run tauri build --bundles app --no-sign
fi

echo "==> build artifacts:"
find src-tauri/target/release/bundle -maxdepth 3 -name '*.dmg' -o -name '*.app' 2>/dev/null | sort
