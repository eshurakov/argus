#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -n "${SWIFTLINT_BIN:-}" ]]; then
  swiftlint_bin="$SWIFTLINT_BIN"
elif command -v swiftlint >/dev/null 2>&1; then
  swiftlint_bin="$(command -v swiftlint)"
elif [[ -x /opt/homebrew/bin/swiftlint ]]; then
  swiftlint_bin="/opt/homebrew/bin/swiftlint"
elif [[ -x /usr/local/bin/swiftlint ]]; then
  swiftlint_bin="/usr/local/bin/swiftlint"
else
  echo "error: SwiftLint not found. Install it with: brew install swiftlint" >&2
  exit 1
fi

if [[ ! -x "$swiftlint_bin" ]]; then
  echo "error: SwiftLint is not executable: $swiftlint_bin" >&2
  exit 1
fi

if [[ -n "${SWIFTLINT_CACHE_PATH:-}" ]]; then
  swiftlint_cache_path="$SWIFTLINT_CACHE_PATH"
else
  swiftlint_cache_path="$project_root/.build/swiftlint-cache"
fi

if [[ -n "${SWIFT_FORMAT_BIN:-}" ]]; then
  swift_format_bin="$SWIFT_FORMAT_BIN"
elif command -v swift-format >/dev/null 2>&1; then
  swift_format_bin="$(command -v swift-format)"
elif swift_format_path="$(xcrun --find swift-format 2>/dev/null)"; then
  swift_format_bin="$swift_format_path"
else
  echo "error: swift-format not found. Use Swift 6 or install it with: brew install swift-format" >&2
  exit 1
fi

if [[ ! -x "$swift_format_bin" ]]; then
  echo "error: swift-format is not executable: $swift_format_bin" >&2
  exit 1
fi

cd "$project_root"
"$swift_format_bin" lint \
  --configuration "$project_root/.swift-format" \
  --recursive \
  --parallel \
  --strict \
  Argus ArgusCLI Tests Package.swift
"$swiftlint_bin" lint \
  --config "$project_root/.swiftlint.yml" \
  --cache-path "$swiftlint_cache_path"
