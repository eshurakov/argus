#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app="$project_root/.build/Build/Products/Release/Argus.app"
plist="$app/Contents/Info.plist"
cli="$app/Contents/Resources/bin/argus"
version="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$project_root/VERSION")"
build="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["build"])' "$project_root/VERSION")"

[[ -d "$app" ]] || { echo "error: Release app not found: $app" >&2; exit 1; }
[[ -x "$cli" ]] || { echo "error: bundled Companion CLI not found: $cli" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$build" ]]
[[ "$($cli --version)" == "argus $version" ]]
codesign --verify --deep --strict "$app"

echo "Release app and bundled Companion CLI match $version ($build)"
