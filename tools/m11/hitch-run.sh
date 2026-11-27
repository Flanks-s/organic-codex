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
# Watchdog: a hung xctrace is killed and the run fails (after the same cleanup), so a hang can't stall a queue. After its time
# limit xctrace still turns the ktrace into the .trace, and that takes long: a 4 GB ktrace under load 5-7 outlasted 60 s (11-05),
# and long-seq's 10-11 GB ktrace took 150-190 s, so a fixed limit+180 s killed two healthy runs mid-way (11-15, #247). Hence:
#  - from HITCH_WATCHDOG s (default 240) past the limit, kill only a stalled xctrace: no CPU time, .trace or ktrace growth
#    in the last HITCH_STALL s (default 60). A real hang (target gone, 10-31/11-05) sat idle for hours.
#  - HITCH_WATCHDOG_MAX s (default 900) past the limit: kill regardless.
#  - from the limit on: a new ktrace over HITCH_KTRACE_MAX_MB (default 16384, ~1.4x the largest seen, 11444 MB) or under
#    HITCH_MIN_FREE_GB (default 10) free on the TMPDIR volume: kill at once, before one run fills the disk.
# xctrace.log ends with one line on how it ended (seconds, CPU, ktrace peak), for the next time the margins need checking.
xcrun xctrace record --quiet --template "Animation Hitches" --attach $pid --time-limit ${secs}s --output $T > $R/xctrace.log 2>&1 &
xp=$! waited=0 hung=0 why="" last_sig="" last_move=0 kpeak=0
# CPU seconds of xp and all its descendants (xcrun may run xctrace as a child).
tree_cpu() { ps -A -o pid=,ppid=,time= | awk -v r=$1 '{ p[$1] = $2; n = split($3, a, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + a[i]; c[$1] = s }
  END { t = 0; for (x in p) { y = x; for (d = 0; d < 64 && y > 1; d++) { if (y == r) { t += c[x]; break }; y = p[y] } }; printf "%d\n", t }'; }
new_ktrace_mb() { local f m=0; for f in ${TMPDIR}instruments*.ktrace(N); do (( ${before[(Ie)$f]} )) || m=$(( m + $(du -sm "$f" | cut -f1) )); done; echo $m; }
while kill -0 $xp 2>/dev/null; do
  # No checks inside the recorded window: ps and du there would be part of what is measured.
  if (( waited >= secs && waited % 5 == 0 )); then
    kmb=$(new_ktrace_mb); (( kmb > kpeak )) && kpeak=$kmb
    free_gb=$(( $(df -k $TMPDIR | awk 'NR==2 { print $4 }') / 1048576 ))
    tmb=0; [[ -e $T ]] && tmb=$(du -sm $T | cut -f1)
    sig="$(tree_cpu $xp) $tmb $kmb"; [[ $sig != $last_sig ]] && { last_sig=$sig last_move=$waited; }
    if (( kmb > ${HITCH_KTRACE_MAX_MB:-16384} )); then why="ktrace $kmb MB over ${HITCH_KTRACE_MAX_MB:-16384} MB"
    elif (( free_gb < ${HITCH_MIN_FREE_GB:-10} )); then why="$free_gb GB free, under ${HITCH_MIN_FREE_GB:-10} GB"
    elif (( waited >= secs + ${HITCH_WATCHDOG_MAX:-900} )); then why="not done ${HITCH_WATCHDOG_MAX:-900} s past its limit"
    elif (( waited >= secs + ${HITCH_WATCHDOG:-240} && waited - last_move >= ${HITCH_STALL:-60} )); then
      why="stalled: no CPU, .trace or ktrace growth for $(( waited - last_move )) s"
    fi
    if [[ -n $why ]]; then
      hung=1; echo "watchdog: xctrace (pid $xp) killed ${waited} s after start: $why (cpu/trace MB/ktrace MB: $sig)" >> $R/xctrace.log
      kill -INT $xp 2>/dev/null; sleep 5; kill -0 $xp 2>/dev/null && kill -KILL $xp 2>/dev/null; break
    fi
  fi
  sleep 1; waited=$(( waited + 1 ))
done
wait $xp 2>/dev/null
(( hung )) || echo "xctrace: done ${waited} s after start (limit ${secs} s), cpu/trace MB/ktrace MB at last check: $last_sig, ktrace peak $kpeak MB" >> $R/xctrace.log
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
