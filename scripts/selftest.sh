#!/bin/zsh
# Self-test at 1× and 2× in two processes at once (SELFTEST_SCALES), into DIR/1x and DIR/2x. Exit status is
# non-zero if either found anything. SELFTEST_ONLY=<scenario,…> narrows a look into a finding; commits run all.
set -u
root="${0:A:h:h}"
dir="${1:-$root/runs/selftest-$(date +%H%M%S)}"
bin="${SELFTEST_BIN:-$root/build/OrganicShell.app/Contents/MacOS/OrganicShell}"
# The gate before a commit is the release build; a FAST (debug) app is far slower here and is not that build.
if [[ -z "${SELFTEST_BIN:-}" ]] && grep -q debug "$root/build/OrganicShell.app/Contents/Resources/BuildMode" 2>/dev/null; then
  echo "build/OrganicShell.app is a FAST (debug) build: run scripts/claude-build.sh first"; exit 2
fi
mkdir -p "$dir"
SELFTEST_SCALES=1 "$bin" --selftest "$dir" > "$dir/1x.log" 2>&1 & one=$!
SELFTEST_SCALES=2 "$bin" --selftest "$dir" > "$dir/2x.log" 2>&1 & two=$!
wait $one; a=$?
wait $two; b=$?
grep -h "^selftest\|^  " "$dir/1x.log" "$dir/2x.log"
exit $(( a | b ))
