#!/bin/zsh
# Real-path press checks (DECISIONS #81): runs `--demo-input` on the built-in screen, then lists what each path left.
# input-run.sh NAME [SPEC] [EXTRA_APP_ARGS...]    SPEC defaults to all. Env: REC_SECONDS=<n> also records the window
#   (WINREC_SCALE=2 stores it at 2× pixels instead of one pixel per point, for close looks at glass);
# keep it shorter than the run (INPUT_TAIL adds time at the end), or the recording never finalizes.
# LOW_RES=1: the same build opened in low resolution (NSHighResolutionCapable false), so its windows really back at 1×
# on the 2× built-in screen. The user's external screen is 1×, and some bugs only show there.
# The app comes to the front (it must be key for orbs to be draggable), so run it only while nobody is using this Mac.
# INPUT_INACTIVE=1 keeps it from taking the focus, for paths that don't need the window key (switch-seq, long-*).
H=${0:A:h}
cd "$H/../.." || exit 1
# The test screen is the built-in one (HP is the user's). With the lid closed `--display Built-in` lands on the HP without saying so.
if [[ -z "${ALLOW_NO_BUILTIN:-}" ]] && ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = Yes'; then
  echo "lid closed: no built-in screen, this would open on the HP. ALLOW_NO_BUILTIN=1 to do it anyway."; exit 1
fi
name=$1 spec=${2:-all}; shift; (( $# )) && shift
R=$PWD/runs/$name-$(date +%H%M%S); mkdir -p $R
# INPUT_APP: a copy under build/ to run instead, so a long matrix keeps its build while the next one compiles.
source_app=${INPUT_APP:-build/OrganicShell.app}
app=$source_app
if [[ -n "${LOW_RES:-}" ]]; then
  app=${source_app:r}-1x.app
  rm -rf $app; cp -R $source_app $app
  /usr/libexec/PlistBuddy -c "Set :NSHighResolutionCapable false" $app/Contents/Info.plist
  codesign --force --sign - $app >/dev/null 2>&1
fi
exe=$app/Contents/MacOS/OrganicShell
pgrep -f "build/OrganicShell[^/]*.app/Contents/MacOS/OrganicShell" >/dev/null && { echo "instance running"; exit 1; }
sysctl -n vm.loadavg > $R/load.txt
open ${INPUT_INACTIVE:+-g} -n $app --args --display Built-in --mock ${INPUT_INACTIVE:+--inactive} --size 1280x820 --quit-after ${QUIT_AFTER:-420} --demo-input "$spec" "$@" --output $R/app
if [[ -n "${REC_SECONDS:-}" ]]; then
  sleep 2.2
  open -g -n tools/winrec/build/WinRec.app --args --bundle local.organic-shell.app --seconds $REC_SECONDS --fps 120 --scale ${WINREC_SCALE:-1} --out $R/rec.mov
fi
sleep 1
for i in {1..$(( ${QUIT_AFTER:-420} + 30 ))}; do pgrep -f "$exe" >/dev/null || break; sleep 1; done
pgrep -f "$exe" >/dev/null && echo "still running after the wait"
echo $R
python3 "$H/input-check.py" $R/app/receipt.json ${INPUT_ALL:+--all} ${INPUT_INACTIVE:+--inactive}
