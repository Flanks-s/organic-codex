#!/bin/sh
set -eu
capture_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
capture_output=${1:-"${ORGANIC_CORE_DATA_DIR:-$HOME/Library/Application Support/Organic Codex/Core}/helpers"}
mkdir -p "$capture_output"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc "$capture_source/HotkeyHelper.swift" -o "$capture_output/HotkeyHelper" -framework AppKit -framework Carbon
