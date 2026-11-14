#!/bin/zsh
# Time Profiler over one --demo-input path on the built-in screen, mock, app in front (keys and drags work), then
# tools/m11/main-busy.py on the exported samples: every stretch the main thread ran without a break longer than
# BUSY_MS (default 80) and the call stack it spent that time in. Deletes the .trace and the instruments*.ktrace this
# run left in $TMPDIR, as hitch-run.sh does. Keys: run it only while nobody is using this Mac.
# profile-run.sh NAME APP SPEC SECONDS [LEAD]    APP under build/; LEAD: seconds from launch to attach, default 4
H=${0:A:h}; cd "$H/../.." || exit 1
if [[ -z "${ALLOW_NO_BUILTIN:-}" ]] && ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = Yes'; then
  echo "lid closed: no built-in screen, this would open on the HP. ALLOW_NO_BUILTIN=1 to do it anyway."; exit 1
fi
name=$1 app=$2 spec=$3 secs=$4 lead=${5:-4}
pgrep -f "build/OrganicShell[^/]*.app/Contents/MacOS/OrganicShell" >/dev/null && { echo "instance running"; exit 1; }
R=$PWD/runs/$name-$(date +%H%M%S); mkdir -p $R; before=(${TMPDIR}instruments*.ktrace(N)); sysctl -n vm.loadavg > $R/load.txt
INPUT_TAIL=4 open -n $app --args --display Built-in --mock --size 1280x820 --quit-after $(( secs + lead + 20 )) --demo-input "$spec" --output $R/app
sleep $lead
pid=$(pgrep -n -f "$app/Contents/MacOS/OrganicShell")
T=$R/t.trace
xcrun xctrace record --quiet --template "Time Profiler" --attach $pid --time-limit ${secs}s --output $T > $R/xctrace.log 2>&1
xcrun xctrace export --input $T --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > $R/time-profile.xml 2>/dev/null
size=$(du -sm $T | cut -f1); rm -rf $T
freed=0; for f in ${TMPDIR}instruments*.ktrace(N); do (( ${before[(Ie)$f]} )) || { freed=$(( freed + $(du -sm "$f" | cut -f1) )); rm -f "$f"; }; done
while pgrep -f "$app/Contents/MacOS/OrganicShell" >/dev/null; do sleep 1; done
python3 "$H/main-busy.py" $R/time-profile.xml ${BUSY_MS:-80} > $R/main-busy.txt; gzip -f $R/time-profile.xml
head -c 4000 $R/main-busy.txt
echo "$R load $(cat $R/load.txt); deleted trace $size MB, ktrace $freed MB"
