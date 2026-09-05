#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

version="$(
  python3 -c 'import json; print(json.load(open("VERSION"))["version"])'
)"

./scripts/lint.sh

host_arch="$(uname -m)"

xcodebuild test \
  -project Argus.xcodeproj \
  -scheme Argus \
  -destination "platform=macOS,arch=${host_arch}" \
  CODE_SIGNING_ALLOWED=NO

swift build --product argus
swift test
swift run argus --version | grep -Fq "argus ${version}"
swift run argus --help | grep -Fq "USAGE: argus"
swift run argus workspace --help | grep -Fq "USAGE: argus workspace"

echo "Argus tests passed"
