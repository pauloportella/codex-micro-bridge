#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(dirname "$script_dir")
app_path="$project_root/dist/Codex Micro Bridge.app"
contents_path="$app_path/Contents"

swift build --package-path "$project_root" -c release
bin_path=$(swift build --package-path "$project_root" -c release --show-bin-path)

rm -rf "$app_path"
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$bin_path/codex-micro-menu" "$contents_path/MacOS/"
cp "$bin_path/codex-ride" "$contents_path/MacOS/"
cp "$project_root/config/zwift-ride.example.json" "$contents_path/Resources/zwift-ride.json"
cp "$project_root/app/Info.plist" "$contents_path/Info.plist"
chmod 755 "$contents_path/MacOS/codex-micro-menu" "$contents_path/MacOS/codex-ride"
codesign --force --deep --sign - "$app_path"

echo "$app_path"
