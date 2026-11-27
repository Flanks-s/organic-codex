#!/bin/zsh
# Builds build/OrganicShell.app (release by default; CONFIG=debug for a debug build).
set -eu
root="${0:A:h:h}"
config="${CONFIG:-release}"
# Preserve Swift's status independently of the output filter.
build_log="$(mktemp "$root/.build-log.XXXXXX")"
trap 'rm -f "$build_log"' EXIT
build_status=0
swift build --package-path "$root" -c "$config" > "$build_log" 2>&1 || build_status=$?
grep -E "error|warning: unre|Compiling|Build complete" "$build_log" | grep -v "^\[" || true
if (( build_status != 0 )); then exit "$build_status"; fi
bin="$(swift build --package-path "$root" -c "$config" --show-bin-path)/OrganicShell"
test -x "$bin"
app="$root/build/OrganicShell.app"
rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/OrganicShell"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OrganicShell</string>
<key>CFBundleIdentifier</key><string>local.organic-shell.app</string>
<key>CFBundleName</key><string>Organic Shell</string>
<key>CFBundleDisplayName</key><string>Organic Shell v2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# The Live Core's Python runtime (Runtime/Core, copied from the product), where CoreLocalProcess looks for it.
mkdir -p "$app/Contents/Resources"
rsync -a --exclude __pycache__ --exclude '*.pyc' "$root/Runtime/Core/" "$app/Contents/Resources/OrganicCore/"
zsh "$root/scripts/package-bodies.sh" "$root" "$app"
codesign --force --sign - "$app" >/dev/null 2>&1
echo "built $app ($config)"
