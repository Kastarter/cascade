#!/usr/bin/env bash
# test-by-seq.sh — run the swift-testing tests associated with each SEQ, one SEQ at a time.
#
# There are no per-SEQ test targets; tests live in 9 module test targets and use swift-testing
# (@Test / @Suite). This script maps each SEQ to the test files its `feat(seq-NN …)` commit
# touched, extracts the @Test function names from those files (at current HEAD), and runs them
# via `swift test --filter`. Shared suites touched by several SEQs will run under each.
#
# Usage:
#   scripts/test-by-seq.sh            # all SEQ-01..31, in order
#   scripts/test-by-seq.sh 13         # just SEQ-13
#   scripts/test-by-seq.sh 16 17 18   # a subset
#
# Exit code is non-zero if any SEQ had a failing test.

# (no `set -u`: macOS ships bash 3.2, whose empty-array handling trips on it)
cd "$(dirname "$0")/.." || exit 2
REPO="$(pwd)"

# Which SEQs to run (zero-padded 01..31).
if [ "$#" -gt 0 ]; then
  SEQS=()
  for n in "$@"; do SEQS+=("$(printf '%02d' "$((10#$n))")"); done
else
  SEQS=($(seq -w 1 31))
fi

# Warm the build once so per-SEQ filtered runs are fast (and compile errors surface up front).
echo "▶ Building test bundle once (this is the slow part)…"
if ! swift build --build-tests 2>&1 | tail -3; then
  echo "✘ Test build failed — fix compilation before running per-SEQ tests."; exit 2
fi
echo

# Extract @Test function names from a file: arm on any line containing @Test, then grab the
# next `func <name>(`. Handles `@Test\nfunc x()`, `@Test func x()`, and `@Test(arguments:…)`.
seq_test_funcs() {
  awk '
    /@Test/ { armed=1 }
    armed && match($0, /func[ \t]+[A-Za-z0-9_]+/) {
      s=substr($0, RSTART, RLENGTH); sub(/^func[ \t]+/, "", s); print s; armed=0
    }
  ' "$1"
}

declare -a SUMMARY
overall_rc=0

for s in "${SEQS[@]}"; do
  tag="seq-$s"
  sha=$(git log --format='%H %s' -300 | grep -iE "feat\($tag " | head -1 | awk '{print $1}')
  if [ -z "$sha" ]; then
    echo "── SEQ-$s: no feat($tag …) commit found — SKIP"; SUMMARY+=("SEQ-$s  SKIP  (no commit)"); echo; continue
  fi

  # Test files this SEQ's commit touched, that still exist at HEAD.
  files=()
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(git show --name-only --format= "$sha" -- 'Tests/' | grep '\.swift$' | while read -r p; do [ -f "$p" ] && echo "$p"; done)
  if [ "${#files[@]}" -eq 0 ]; then
    echo "── SEQ-$s: commit touched no surviving test files — SKIP"; SUMMARY+=("SEQ-$s  SKIP  (no test files)"); echo; continue
  fi

  # Collect @Test function names across those files.
  funcs=$(for f in "${files[@]}"; do seq_test_funcs "$f"; done | sort -u)
  if [ -z "$funcs" ]; then
    echo "── SEQ-$s: touched test files have no @Test funcs — SKIP"; SUMMARY+=("SEQ-$s  SKIP  (no @Test funcs)"); echo; continue
  fi

  regex=$(echo "$funcs" | paste -sd '|' -)
  nfuncs=$(echo "$funcs" | wc -l | tr -d ' ')
  echo "── SEQ-$s ($(git log --format=%s -1 "$sha" | sed 's/feat([^)]*): *//'))"
  echo "   files: ${#files[@]} | @Test funcs: $nfuncs"

  out=$(swift test --filter "($regex)" 2>&1)
  summary_line=$(echo "$out" | grep -E 'Test run with' | tail -1)
  fails=$(echo "$out" | grep -cE '✘|❌|: error:|recorded a failure|Test .* failed')

  if echo "$summary_line" | grep -q 'passed'; then
    echo "   ✅ ${summary_line#*↳ }"; SUMMARY+=("SEQ-$s  PASS  ${summary_line##*with }")
  elif [ -z "$summary_line" ]; then
    echo "   ⚠️  no tests matched the filter"; SUMMARY+=("SEQ-$s  SKIP  (0 matched)")
  else
    echo "   ✘ FAILED — ${summary_line#*↳ }"; echo "$out" | grep -E '✘|: error:|Test .* failed' | head -10 | sed 's/^/      /'
    SUMMARY+=("SEQ-$s  FAIL  ${summary_line##*with }"); overall_rc=1
  fi
  echo
done

echo "════════════════════ SUMMARY ════════════════════"
printf '%s\n' "${SUMMARY[@]}"
exit $overall_rc
