#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/.build"
APP_NAME="Argus"
CLI_NAME="argus"
BUILD_CLI=1

# --------------------------------------------------------------------------
# Usage
# --------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  build       Build the app and CLI, then bundle the CLI into the app (default)
  web         Rebuild the committed Pierre diff renderer bundle
  cli         Build only the CLI
  run         Build app+CLI, then launch the app
  install     Build app+CLI, install to /Applications, and launch
  clean       Remove build artifacts
  generate    Regenerate Argus.xcodeproj from project.yml

Options:
  --debug     Use Debug configuration (default)
  --release   Use Release configuration
  --no-cli    Build the app without building/bundling the CLI
  --no-open   Don't launch the app after run/install

Examples:
  ./scripts/build.sh build
  ./scripts/build.sh web
  ./scripts/build.sh cli
  ./scripts/build.sh run
  ./scripts/build.sh run --release
  ./scripts/build.sh install
  ./scripts/build.sh clean
EOF
    exit 0
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
COMMAND=""
CONFIGURATION="Debug"
OPEN_APP=1

while [[ $# -gt 0 ]]; do
    case $1 in
        build|web|cli|run|install|clean|generate) COMMAND="$1"; shift ;;
        --debug)    CONFIGURATION="Debug";   shift ;;
        --release)  CONFIGURATION="Release"; shift ;;
        --no-cli)   BUILD_CLI=0;             shift ;;
        --no-open)  OPEN_APP=0;              shift ;;
        -h|--help)  usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Default command
COMMAND="${COMMAND:-build}"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
log()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m==>\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m==>\033[0m %s\n" "$*" >&2; }
time_start() { _t_start=$(date +%s); }
time_end()   { local elapsed=$(( $(date +%s) - _t_start )); log "Completed in ${elapsed}s"; }

ensure_xcode_project() {
    if [[ ! -d "${PROJECT_DIR}/Argus.xcodeproj" ]]; then
        log "Argus.xcodeproj not found — generating..."
        do_generate
    fi
}

find_app() {
    find "${BUILD_DIR}/Build/Products/${CONFIGURATION}" -name "${APP_NAME}.app" -type d 2>/dev/null | head -1
}

swiftpm_configuration() {
    case "${CONFIGURATION}" in
        Debug)   echo "debug" ;;
        Release) echo "release" ;;
        *)       echo "${CONFIGURATION}" | tr '[:upper:]' '[:lower:]' ;;
    esac
}

cli_build_path() {
    local swift_config
    swift_config="$(swiftpm_configuration)"
    echo "${BUILD_DIR}/SwiftPM/${swift_config}/${CLI_NAME}"
}

quit_running() {
    "${SCRIPT_DIR}/quit-running.sh" "${APP_NAME}"
}

launch_app() {
    local app_path="$1"
    if [[ $OPEN_APP -eq 1 ]]; then
        log "Launching ${APP_NAME}..."
        local launch_output
        if launch_output="$(
            unset ARGUS_SOCKET_PATH ARGUS_WORKSPACE_ID ARGUS_SURFACE_ID
            open -n "$app_path" 2>&1
        )"; then
            return 0
        fi

        if [[ "$launch_output" != *"error -600"* ]]; then
            printf '%s\n' "$launch_output" >&2
            return 1
        fi

        log "Launch Services was still releasing ${APP_NAME}; retrying..."
        sleep 1
        (
            unset ARGUS_SOCKET_PATH ARGUS_WORKSPACE_ID ARGUS_SURFACE_ID
            open -n "$app_path"
        )
    fi
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------
do_generate() {
    log "Regenerating Xcode project from project.yml..."
    if ! command -v xcodegen &> /dev/null; then
        err "xcodegen not found. Install with: brew install xcodegen"
        exit 1
    fi
    (cd "$PROJECT_DIR" && xcodegen generate)
    ok "Xcode project generated"
}

do_build_cli() {
    if [[ ! -f "${PROJECT_DIR}/Package.swift" ]]; then
        err "Package.swift not found; cannot build ${CLI_NAME} CLI"
        exit 1
    fi

    local swift_config
    swift_config="$(swiftpm_configuration)"

    log "Building ${CLI_NAME} CLI (${CONFIGURATION})..."
    (cd "${PROJECT_DIR}" && swift build \
        --product "${CLI_NAME}" \
        --configuration "${swift_config}" \
        --build-path "${BUILD_DIR}/SwiftPM")

    local cli_path
    cli_path="$(cli_build_path)"
    if [[ ! -x "${cli_path}" ]]; then
        err "CLI build product not found: ${cli_path}"
        exit 1
    fi

    ok "CLI build succeeded: ${cli_path}"
}

do_build_web() {
    if [[ ! -f "${PROJECT_DIR}/ArgusWeb/package.json" ]]; then
        err "ArgusWeb/package.json not found; cannot build Pierre bundle"
        exit 1
    fi
    if ! command -v npm &> /dev/null; then
        err "npm not found; install Node.js to rebuild the Pierre bundle"
        exit 1
    fi

    log "Building Pierre diff renderer bundle..."
    (cd "${PROJECT_DIR}" && npm ci --prefix ArgusWeb && npm run build --prefix ArgusWeb)
    ok "Pierre bundle rebuilt"
}

bundle_cli() {
    local app_path="$1"
    local cli_path
    cli_path="$(cli_build_path)"

    if [[ ! -x "${cli_path}" ]]; then
        err "CLI build product not found: ${cli_path}"
        exit 1
    fi

    # Do not place the lowercase `argus` binary next to the app executable
    # (`Argus`) because the default macOS filesystem is case-insensitive and
    # that would overwrite the app's launcher. Keep bundled tools separate.
    local tools_dir="${app_path}/Contents/Resources/bin"
    mkdir -p "${tools_dir}"

    log "Bundling ${CLI_NAME} CLI into ${APP_NAME}.app..."
    install -m 755 "${cli_path}" "${tools_dir}/${CLI_NAME}"
    ok "Bundled CLI: ${tools_dir}/${CLI_NAME}"
}

do_build() {
    ensure_xcode_project
    log "Building ${APP_NAME} (${CONFIGURATION})..."
    time_start

    # The script mutates the built .app when bundling the CLI. Remove the
    # previous product first so Xcode never treats externally modified app
    # contents as up-to-date incremental output.
    rm -rf "${BUILD_DIR}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"

    xcodebuild \
        -project "${PROJECT_DIR}/Argus.xcodeproj" \
        -scheme Argus \
        -configuration "${CONFIGURATION}" \
        -derivedDataPath "${BUILD_DIR}" \
        build

    local app_path
    app_path="$(find_app)"
    if [[ -z "$app_path" ]]; then
        err "Build product not found"
        exit 1
    fi

    if [[ ${BUILD_CLI} -eq 1 ]]; then
        do_build_cli
        bundle_cli "${app_path}"
    fi

    # Ad-hoc codesign after bundling the CLI.
    codesign --force --deep --sign - "${app_path}" 2>/dev/null || true

    time_end
    ok "Build succeeded: ${app_path}"
}

do_run() {
    quit_running
    do_build
    launch_app "$(find_app)"
}

do_install() {
    quit_running
    do_build

    local app_path
    app_path="$(find_app)"
    local dest="/Applications/${APP_NAME}.app"

    log "Installing to ${dest}..."
    rm -rf "$dest"
    cp -R "$app_path" "$dest"
    ok "Installed to ${dest}"

    launch_app "$dest"
}

do_clean() {
    log "Cleaning build artifacts..."
    rm -rf "${BUILD_DIR}"
    ok "Clean complete"
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
case "$COMMAND" in
    build)    do_build     ;;
    web)      do_build_web ;;
    cli)      do_build_cli ;;
    run)      do_run       ;;
    install)  do_install   ;;
    clean)    do_clean     ;;
    generate) do_generate  ;;
    *)        usage       ;;
esac
