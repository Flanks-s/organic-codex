#!/bin/zsh
# M11.30 in a real window: the mock held still, inactive so it takes no focus, captured by WindowServer, then tools/m11/dock-gap-check.swift.
# dock-gap-run.sh NAME separate|merged [APP]. Env: PARITY_STATE=focused|split… reaches that layout, LOW_RES=1 real 1×, and any env the build reads.
# The test screen is the built-in one; it refuses with the lid closed.
H=${0:A:h}
cd "$H/../.." || exit 1
if ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = Yes'; then echo "lid closed: no built-in screen"; exit 1; fi
name=$1 expect=$2 source_app=${3:-build/OrganicShell.app}; app=$source_app
pgrep -f "build/OrganicShell[^/]*.app/Contents/MacOS/OrganicShell" >/dev/null && { echo "instance running"; exit 1; }
if [[ -n "${LOW_RES:-}" ]]; then
  app=${source_app:r}-1x.app
  rm -rf $app; cp -R $source_app $app
  /usr/libexec/PlistBuddy -c "Set :NSHighResolutionCapable false" $app/Contents/Info.plist
  codesign --force --sign - $app >/dev/null 2>&1
fi
R=$PWD/runs/$name-$(date +%H%M%S); mkdir -p $R
settle=${GAP_SETTLE:-5}
open -g -n $app --args --display Built-in --inactive --mock-paused --size 1280x820 --quit-after $(( settle + 6 )) --output $R/app
sleep $settle
wid=$(swift - <<'SWIFT' 2>/dev/null
import CoreGraphics
let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let w = all.first { ($0[kCGWindowOwnerName as String] as? String)?.contains("Organic") == true && ($0[kCGWindowLayer as String] as? Int) == 0 && (($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0) >= 1200 }
print(w?[kCGWindowNumber as String] as? Int ?? 0)
SWIFT
)
screencapture -x -o -l $wid $R/dock.png; rc=$?
for i in {1..20}; do pgrep -f "$app/Contents/MacOS/OrganicShell" >/dev/null || break; sleep 1; done
echo "$R wid $wid capture rc $rc"
swift "$H/dock-gap-check.swift" $R/dock.png $expect
