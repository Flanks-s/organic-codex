#!/bin/zsh
# M11.20 in real windows, on the mock's own record (ORGANIC_PERSIST=1, the Core's record is not touched): close the last window, the app stays;
# back from the Dock; ⌘Q with no window, then a relaunch; ⌘N; the draft back. keep-app-run.sh NAME   Env: APP (default build/OrganicShell.app),
# INPUT_SCHEME=focused|split, INPUT_KEEP_CYCLES=1 (no-window CPU, then 20 close and reopen cycles), REC_SECONDS (records the built-in screen).
H=${0:A:h}; cd "$H/../.." || exit 1
if ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = Yes'; then echo "lid closed: no built-in screen"; exit 1; fi
name=${1:?name}; app=${APP:-build/OrganicShell.app}; exe=$app/Contents/MacOS/OrganicShell
pgrep -f "build/OrganicShell[^/]*.app/Contents/MacOS/OrganicShell" >/dev/null && { echo "instance running"; exit 1; }
R=$PWD/runs/$name-$(date +%H%M%S); mkdir -p $R
export ORGANIC_PERSIST=1
# Starts from a known record: a mock window on its own screen, nothing left from an earlier run.
defaults delete local.organic-shell.app organic.windows.mock 2>/dev/null
run() { local phase=$1 q=$2
  INPUT_KEEP=$phase open -n $app --args --display Built-in --mock --size 1280x820 --quit-after $q --demo-input keep-app --output $R/$phase
  local i=0; sleep 1; while pgrep -f "$exe" >/dev/null && (( i < q + 20 )); do sleep 1; (( i++ )); done
  sleep 1
}
[[ -n "${REC_SECONDS:-}" ]] && tools/m11/display-rec --seconds $REC_SECONDS --fps 60 --scale 1 --out $R/screen.mov >/dev/null 2>&1 &
stamp=$R/start-stamp; touch $stamp
run first 40
run relaunch $(( ${INPUT_KEEP_CYCLES:+150} + 40 ))
wait
pgrep -f "$exe" >/dev/null && echo "still running"
# A crash of the app during the run, with the signature the 13:11 run had (EXC_GUARD in AppKit's accessibility notification, 11-02).
crashes=(~/Library/Logs/DiagnosticReports/OrganicShell*.ips(N.e:'[[ $REPLY -nt $stamp ]]':))
print "crash reports: ${#crashes}"; for c in $crashes; do cp "$c" $R/; grep -q EXC_GUARD "$c" && print "  EXC_GUARD: ${c:t}" || print "  other: ${c:t}"; done
python3 "$H/keep-app-check.py" $R
