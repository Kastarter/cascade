#!/usr/bin/env bash
# Refresh the Cascade fork from upstream Screenpipe:
#   1. Pop all currently-applied patches
#   2. Fetch + checkout the requested upstream SHA (or main HEAD) in the submodule
#   3. Re-apply patches one at a time; on conflict, drop into quilt for manual fixup
#   4. Refresh each patch file to reflect post-merge state
# Usage:  ./scripts/refresh-from-upstream.sh [<sha-or-ref>]
# Default ref: origin/main

set -euo pipefail

TARGET_REF="${1:-origin/main}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export QUILT_PATCHES="$REPO_ROOT/patches"
export QUILT_SERIES="$QUILT_PATCHES/series"

cd vendor/screenpipe

echo "==> popping applied patches"
quilt pop -a || true

echo "==> fetching upstream + checking out $TARGET_REF"
git fetch origin
git checkout "$TARGET_REF"

cd "$REPO_ROOT/vendor/screenpipe"

echo "==> re-applying patch series"
if ! quilt push -a; then
  echo
  echo "patch conflict. drop into a shell, run:" >&2
  echo "  cd vendor/screenpipe" >&2
  echo "  # fix conflicts in failing patch file" >&2
  echo "  quilt refresh" >&2
  echo "  quilt push -a" >&2
  exit 1
fi

echo "==> refreshing all patches to current upstream"
while quilt top >/dev/null 2>&1; do
  quilt refresh
  quilt pop || break
done
quilt push -a

echo "==> remember to commit the submodule SHA bump + any refreshed patches"
