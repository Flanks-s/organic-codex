#!/bin/zsh
# Animation Hitches over one --demo-input path on the built-in screen, mock, without taking the focus. Exports the hitches table to a
# small XML in runs/NAME-*, then deletes the .trace and the instruments*.ktrace this run left in $TMPDIR (about 340 MB and 3-4 GiB; `--output`
# does not move the ktrace, 17 of them were left behind on 10-31). Prints the count of hitches and what is left in $TMPDIR.
# hitch-run.sh NAME APP SPEC SECONDS [LEAD]    APP under build/, e.g. build/OrganicShell-b.app. LEAD: seconds from launch to attach, default 3.
H=${0:A:h}; cd "$H/../.." || exit 1
# The test screen is the built-in one (HP is the user's). With the lid closed `--display Built-in` lands on the HP without saying so.
if [[ -z "${ALLOW_NO_BUILTIN:-}" ]] && ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = Yes'; then
  echo "lid closed: no built-in screen, this would open on the HP. ALLOW_NO_BUILTIN=1 to do it anyway."; exit 1
fi
name=$1 app=$2 spec=$3 secs=$4 lead=${5:-3}
pgrep -f "build/OrganicShell[^/]*.app/Contents/MacOS/OrganicShell" >/dev/null && { echo "instance running"; exit 1; }
R=$PWD/runs/$name-$(date +%H%M%S); mkdir -p $R; before=(${TMPDIR}instruments*.ktrace(N)); sysctl -n vm.loadavg > $R/load.txt
# HITCH_ACTIVE=1: the app comes to the front and takes the focus, for paths that need the window key (drags, the scheme key).
if [[ -n ${HITCH_ACTIVE:-} ]]; then front=() inactive=(); else front=(-g) inactive=(--inactive); export INPUT_INACTIVE=1; fi
# The app must outlive the trace: xctrace has hung for hours on a target that quit first (10-31, 11-05). A spec this build
# doesn't know runs nothing and would quit after INPUT_TAIL, so the default tail covers the whole trace. HITCH_TAIL overrides.
INPUT_TAIL=${HITCH_TAIL:-$(( secs + lead + 5 ))} open $front -n $app --args --display Built-in --mock $inactive --size 1280x820 --quit-after $(( 2 * secs + 2 * lead + 40 )) --demo-input "$spec" --output $R/app
sleep $lead
pid=$(pgrep -n -f "$app/Contents/MacOS/OrganicShell")
T=$R/t.trace
# Watchdog: xctrace not back HITCH_WATCHDOG s (default 240) after its time limit is killed and the run fails (after the same
# cleanup), so a hang can't stall a queue. 60 s was too short: finishing a 4 GB ktrace under load 5-7 took longer (11-05).
xcrun xctrace record --quiet --template "Animation Hitches" --attach $pid --time-limit ${secs}s --output $T > $R/xctrace.log 2>&1 &
xp=$! waited=0 hung=0
while kill -0 $xp 2>/dev/null; do
  if (( waited >= secs + ${HITCH_WATCHDOG:-240} )); then
    hung=1; echo "watchdog: xctrace (pid $xp) not done ${waited} s after start, killed" >> $R/xctrace.log
    kill -INT $xp 2>/dev/null; sleep 5; kill -0 $xp 2>/dev/null && kill -KILL $xp 2>/dev/null; break
  fi
  sleep 1; waited=$(( waited + 1 ))
done
wait $xp 2>/dev/null
(( hung )) || xcrun xctrace export --input $T --xpath '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]' > $R/hitches.xml 2>/dev/null
size=$(du -sm $T | cut -f1); rm -rf $T
freed=0; for f in ${TMPDIR}instruments*.ktrace(N); do (( ${before[(Ie)$f]} )) || { freed=$(( freed + $(du -sm "$f" | cut -f1) )); rm -f "$f"; }; done
while pgrep -f "$app/Contents/MacOS/OrganicShell" >/dev/null; do sleep 1; done
if (( hung )); then echo "hitches FAILED: xctrace hung and was killed; $R; deleted trace $size MB, ktrace $freed MB"; exit 1; fi
python3 - "$R/hitches.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot(); ids = {}; rows = []
for row in root.iter("row"):
    vals = []
    for e in list(row):
        for sub in e.iter():
            if "id" in sub.attrib: ids[sub.attrib["id"]] = sub
        if "ref" in e.attrib: e = ids.get(e.attrib["ref"], e)
        vals.append(e.text)
    rows.append(vals)
d = [int(r[1]) / 1e6 for r in rows if r and r[1]]
print(f"hitches {len(d)}, total {sum(d):.0f} ms, worst {max(d, default=0):.1f} ms")
PY
echo "$R load $(cat $R/load.txt); deleted trace $size MB, ktrace $freed MB; ktrace left in TMPDIR: ${#${(@f)$(print -l ${TMPDIR}instruments*.ktrace(N))}}"
