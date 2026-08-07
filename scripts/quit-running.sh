#!/bin/bash
set -euo pipefail

APP_NAME="${1:-Argus}"
PGREP_COMMAND="${ARGUS_PGREP_COMMAND:-pgrep}"
OSASCRIPT_COMMAND="${ARGUS_OSASCRIPT_COMMAND:-osascript}"
KILL_COMMAND="${ARGUS_KILL_COMMAND:-kill}"
SLEEP_COMMAND="${ARGUS_SLEEP_COMMAND:-sleep}"
SEQ_COMMAND="${ARGUS_SEQ_COMMAND:-seq}"

pids="$(${PGREP_COMMAND} -x "${APP_NAME}" || true)"
[[ -n "${pids}" ]] || exit 0

while IFS= read -r pid; do
    # Target the process that was already running. A name-based AppleScript
    # quit may launch another registered bundle after the app is replaced.
    "${OSASCRIPT_COMMAND}" \
        -l JavaScript \
        -e 'ObjC.import("AppKit")' \
        -e "const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(${pid});" \
        -e 'if (app) app.terminate;' \
        > /dev/null 2>&1 || true
done <<< "${pids}"

for _ in $(${SEQ_COMMAND} 1 5); do
    any_running=0
    while IFS= read -r pid; do
        if "${KILL_COMMAND}" -0 "${pid}" 2>/dev/null; then
            any_running=1
            break
        fi
    done <<< "${pids}"
    [[ ${any_running} -eq 0 ]] && exit 0
    "${SLEEP_COMMAND}" 1
done

while IFS= read -r pid; do
    "${KILL_COMMAND}" -9 "${pid}" 2>/dev/null || true
done <<< "${pids}"
"${SLEEP_COMMAND}" 0.5
