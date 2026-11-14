#!/bin/zsh
# Windowless production-component checks. A private debug/per-file-O cache stays under OUT/.package.
# The package is a dot directory on purpose: it holds the staged body sprites (about 180 MB, reached twice through
# the resource link), and CI uploads everything under OUT except hidden files. Logs and images stay in OUT itself.
set -eu
root="${0:A:h:h:h}"
out="${1:-/tmp/organic-m11-1-check}"
mkdir -p "$out"
out="${out:A}"
package="${M11_CHECK_PACKAGE:-$out/.package}"
prepare=(python3 "$root/tools/m11/check_package.py" --root "$root" --package "$package"
    --name M111Check --define M11_MODE_SELFTEST --define CHECK_PACKAGE_WHOLE_TREE
    --add tools/m11/m11-1-check.swift --add tools/m11/ModeRegressionChecks.swift)
"${prepare[@]}" --list > "$out/sources.txt"
"${prepare[@]}"
swift build --package-path "$package" -c debug -j "${M11_BUILD_JOBS:-4}" > "$out/build.log" 2>&1
if [[ "${M11_COMPILE_ONLY:-0}" == 1 ]]; then exit 0; fi
bin="$(swift build --package-path "$package" -c debug --show-bin-path)/Check"
"$bin" "$out" > "$out/check.log" 2>&1
cat "$out/check.log"
