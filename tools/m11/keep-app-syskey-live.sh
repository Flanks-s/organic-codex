#!/bin/zsh
# M11.20: Cmd+N with no window on the live Core, sent through System Events (the window server), as a person's key press.
# keep-app-syskey-live.sh NAME   Env: INPUT_APP (default build/OrganicShell.app).
# Runs `long-real.sh run NAME keep-app` with INPUT_KEEP=syskey and REAL_KEY=1: read-only, the three threads, the app takes the focus.
# The driver closes the window; this script waits for zero windows, notes the front app and its menu title, then presses Cmd+N.
# Takes the focus: only after five idle minutes.
H=${0:A:h}; cd "$H/../.." || exit 1
name=${1:?name}
exe_pat="build/OrganicShell[^/]*.app/Contents/MacOS/OrganicShell"
pgrep -f "$exe_pat" >/dev/null && { echo "instance running"; exit 1; }
log=$(mktemp -t syskey-live)
(
  # Wait for the app, then for its restored window, then for none.
  for i in {1..120}; do pid=$(pgrep -f "$exe_pat" | head -1); [[ -n $pid ]] && break; sleep 0.5; done
  [[ -z $pid ]] && { echo "no app" >> $log; exit 0; }
  wins() { osascript -e "tell application \"System Events\" to count windows of (first process whose unix id is $pid)" 2>/dev/null || echo -1; }
  seen=0
  for i in {1..240}; do
    n=$(wins)
    (( n > 0 )) && seen=1
    (( seen == 1 && n == 0 )) && break
    sleep 0.5
  done
  echo "pid $pid windows before key: $n (seen $seen) at $(date +%H:%M:%S)" >> $log
  sleep 1
  front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>&1)
  menu=$(osascript -e "tell application \"System Events\" to get name of menu bar item 2 of menu bar 1 of (first process whose unix id is $pid)" 2>&1)
  osascript -e 'tell application "System Events" to keystroke "n" using command down' >> $log 2>&1; rc=$?
  sleep 2
  echo "front: $front; app menu: $menu; osascript rc $rc; windows 2 s after key: $(wins)" >> $log
) &
watcher=$!
INPUT_KEEP=syskey REAL_KEY=1 INPUT_KEEP_LEAD=${INPUT_KEEP_LEAD:-3} QUIT_AFTER=${QUIT_AFTER:-90} tools/m11/long-real.sh run $name keep-app > /dev/null 2>&1
wait $watcher
R=$(ls -dt runs/$name-* | head -1)
mv $log $R/syskey.txt
echo $R; cat $R/syskey.txt
python3 - $R/app/receipt.json <<'PY'
import json, sys
for e in json.load(open(sys.argv[1])).get("composeLog", []):
    print({k: e.get(k) for k in ("step", "windows", "visible", "active", "enabled", "target") if k in e}, str(e.get("record", ""))[:110])
PY
