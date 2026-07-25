#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$project_root/VERSION")"
build_path="$project_root/.build/release-verification/SwiftPM"
binary="$build_path/debug/argus"

swift build \
  --package-path "$project_root" \
  --product argus \
  --configuration debug \
  --build-path "$build_path"

[[ "$($binary --version)" == "argus $version" ]]
"$binary" --help | grep -Fq "USAGE: argus"

echo "Companion CLI reports version $version and provides help"
