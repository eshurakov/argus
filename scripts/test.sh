#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

./scripts/lint.sh

host_arch="$(uname -m)"

xcodebuild test \
  -project Argus.xcodeproj \
  -scheme Argus \
  -destination "platform=macOS,arch=${host_arch}" \
  CODE_SIGNING_ALLOWED=NO

swift build --product argus
swift run argus --version | grep -Fq "argus 1.2.0"
swift run argus --help | grep -Fq "USAGE: argus"

echo "Argus tests passed"
