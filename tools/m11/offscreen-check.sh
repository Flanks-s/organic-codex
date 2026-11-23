#!/bin/zsh
# Run in a private HEAD export with the M11 files overlaid. No app launch, window, recording, or Core connection.
set -eu
root="${0:A:h:h:h}"
out="${1:-/tmp/organic-m11-offscreen}"
scratch="${M11_BUILD_DIR:-$root/.build-m11-debug}"
mkdir -p "$out"
python3 "$root/tools/m11/test-mode-latency.py" > "$out/reader.log" 2>&1
swiftc -swift-version 6 -parse-as-library -Onone \
  "$root/Sources/OrganicShell/Debug/ModeSignposts.swift" "$root/tools/m11/probe-check.swift" \
  -o "$out/probe-check" > "$out/probe-build.log" 2>&1
"$out/probe-check" "$out/synthetic-receipt.json" > "$out/probe.log" 2>&1
M11_MODE_SIGNPOSTS=0 "$out/probe-check" "$out/receipt-only-synthetic.json" > "$out/probe-disabled.log" 2>&1
python3 "$root/tools/m11/mode-latency.py" --receipt "$out/synthetic-receipt.json" \
  --json "$out/synthetic-timeline.json" > "$out/synthetic-timeline.txt"
# Debug configuration, per-file -O, no release whole-module build. Cache stays in the private directory.
swift build --package-path "$root" -c debug --scratch-path "$scratch" -Xswiftc -O > "$out/build.log" 2>&1
bin="$(swift build --package-path "$root" -c debug --scratch-path "$scratch" -Xswiftc -O --show-bin-path)/OrganicShell"
# Main returns into the existing offscreen selftest before creating NSApplication / the AppController.
SELFTEST_BIN="$bin" "$root/scripts/selftest.sh" "$out/selftest" > "$out/selftest.log" 2>&1
# M10-A exposure gates: the whole product tree under M10_MODE_SELFTEST (debt #65, decision #181),
# instead of a hand-kept file list that drifts from the product.
python3 "$root/tools/m11/playback-gates.py" m10 "$out/m10-mode" \
  --cache "${M11_GATE_CACHE:-$root/.build-m11-gates}" > "$out/m10.log" 2>&1
cat "$out/reader.log" "$out/probe.log" "$out/probe-disabled.log" "$out/selftest.log" "$out/m10.log"
echo "Offscreen evidence: $out"
