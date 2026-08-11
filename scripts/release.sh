#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
runner="$project_root/scripts/run-with-timeout.py"

usage() {
  cat <<EOF
Usage: $(basename "$0") prepare <minor|patch>
       $(basename "$0") verify

Commands:
  prepare minor  Increment the minor version, reset patch to zero, increment the build
                 number, synchronize consumers, regenerate the Xcode project, and verify.
  prepare patch  Increment the patch version and build number, synchronize consumers,
                 regenerate the Xcode project, and verify version consistency.
  verify         Run bounded release verification stages and retain diagnostics.
EOF
}

run_stage() {
  local name="$1"
  local timeout="$2"
  shift 2
  local log="$diagnostics_dir/${name}.log"

  printf '==> %-24s' "$name"
  set +e
  python3 "$runner" --timeout "$timeout" --log "$log" -- "$@"
  local status=$?
  set -e

  if [[ $status -eq 0 ]]; then
    printf 'passed\n'
    return 0
  fi

  if [[ $status -eq 124 ]]; then
    printf 'timed out after %ss\n' "$timeout" >&2
  else
    printf 'failed (exit %s)\n' "$status" >&2
  fi
  echo "Diagnostics: $log" >&2
  return "$status"
}

command="${1:-}"
case "$command" in
  prepare)
    increment="${2:-}"
    [[ "$increment" == "minor" || "$increment" == "patch" ]] && [[ $# -eq 2 ]] || {
      usage >&2
      exit 2
    }
    exec python3 "$project_root/scripts/version.py" prepare "$increment"
    ;;
  verify)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

timestamp="$(date +%Y%m%d-%H%M%S)-$$"
diagnostics_dir="${ARGUS_RELEASE_DIAGNOSTICS_DIR:-$project_root/.build/release-diagnostics/$timestamp}"
mkdir -p "$diagnostics_dir"
host_arch="$(uname -m)"
result_bundle="$diagnostics_dir/ArgusTests.xcresult"

echo "Release diagnostics: $diagnostics_dir"
run_stage version-consistency 30 python3 "$project_root/scripts/version.py" verify
run_stage lint 300 "$project_root/scripts/lint.sh"
run_stage app-tests 300 xcodebuild test \
  -project "$project_root/Argus.xcodeproj" \
  -scheme Argus \
  -destination "platform=macOS,arch=${host_arch}" \
  -resultBundlePath "$result_bundle" \
  CODE_SIGNING_ALLOWED=NO
run_stage companion-cli 600 "$project_root/scripts/verify-cli.sh"
run_stage diff-check 30 git -C "$project_root" diff --check
run_stage release-build 600 "$project_root/scripts/build.sh" build --release --no-open
run_stage release-artifacts 60 "$project_root/scripts/verify-release-artifacts.sh"

echo "Release verification passed"
