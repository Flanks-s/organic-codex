#!/bin/zsh
# Build verified assets in an external content-addressed cache and package the selected layout.
set -eu
root="$1"
app="$2"
python3 "$root/scripts/build-body-assets.py" "$root" "$app"
