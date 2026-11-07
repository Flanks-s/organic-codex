#!/bin/sh
set -eu
capture_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
capture_output=${1:-"${ORGANIC_CORE_DATA_DIR:-$HOME/Library/Application Support/Organic Codex/Core}/helpers"}
mkdir -p "$capture_output/Organic Capture.app/Contents/MacOS"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -parse-as-library "$capture_source/CaptureHelper.swift" -o "$capture_output/CaptureHelper" -framework AppKit -framework ScreenCaptureKit -framework ApplicationServices
cp "$capture_output/CaptureHelper" "$capture_output/Organic Capture.app/Contents/MacOS/OrganicCapture"
cp "$capture_source/Info.plist" "$capture_output/Organic Capture.app/Contents/Info.plist"
codesign --force --sign - "$capture_output/Organic Capture.app"
echo "Built $capture_output/Organic Capture.app. macOS Screen Recording permission must be approved normally for this build."
