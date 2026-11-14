#!/bin/zsh
# M11.20: Cmd+N with no window, sent through System Events, so it comes from the window server like a key press and not from NSApp.postEvent.
# keep-app-syskey.sh NAME   Env: APP (default build/OrganicShell.app). The mock's own record. Takes the focus: only after five idle minutes.
H=${0:A:h}; cd "$H/../.." || exit 1
if ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = Yes'; then echo "lid closed: no built-in screen"; exit 1; fi
name=${1:?name}; app=${APP:-build/OrganicShell.app}; exe=$app/Contents/MacOS/OrganicShell
pgrep -f "build/OrganicShell[^/]*.app/Contents/MacOS/OrganicShell" >/dev/null && { echo "instance running"; exit 1; }
R=$PWD/runs/$name-$(date +%H%M%S); mkdir -p $R
ORGANIC_PERSIST=1 INPUT_KEEP=syskey open -n $app --args --display Built-in --mock --size 1280x820 --quit-after 40 --demo-input keep-app --output $R/app
sleep 9
front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>&1)
osascript -e 'tell application "System Events" to keystroke "n" using command down' > $R/osascript.txt 2>&1; rc=$?
echo "front: $front; osascript rc $rc: $(cut -c1-120 $R/osascript.txt)"
i=0; while pgrep -f "$exe" >/dev/null && (( i < 40 )); do sleep 1; (( i++ )); done
python3 - $R/app/receipt.json <<'PY'
import json, sys
for e in json.load(open(sys.argv[1]))["composeLog"]:
    print({k: e.get(k) for k in ("step", "windows", "visible", "active", "enabled", "target") if k in e}, e.get("record", "")[:110])
PY
