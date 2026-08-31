#!/usr/bin/env bash
set -euo pipefail

# Maintainer-only: builds GhosttyKit.xcframework from pinned ghostty-org/ghostty
# and symlinks it into Frameworks/GhosttyKit.xcframework. This automates the
# manual walkthrough in Frameworks/README.md — read that file for the "why"
# behind each step (SDK/Zig workarounds, ReleaseFast, etc).
#
# Most contributors don't need to run this: only when bootstrapping a fresh
# machine (no cached build yet) or deliberately bumping the pinned Ghostty/Zig
# version below.
#
# IMPORTANT: build a recent ghostty *main*, NOT the v1.3.1 tag. Two things that
# matter here only exist after v1.3.1:
#   1. The exported `ghostty_*` C API carries GHOSTTY_API visibility annotations
#      (`__attribute__((visibility("default")))`), so the symbols survive
#      ReleaseFast/ReleaseSmall dead-code elimination. On v1.3.1 a ReleaseFast
#      xcframework build silently drops every ghostty_* symbol.
#   2. GhosttyLib.zig combines the dependency archives via CombineArchivesStep.
#      A v1.3.1 arm64-only build produced a static lib missing large chunks of
#      the bundled deps (FreeType, spirv-cross, oniguruma, ...).
# Building the pinned main commit below sidesteps both. Verified: the resulting
# libghostty-internal-fat.a defines _ghostty_app_new AND _spvc_context_create /
# _FT_Done_Face, and Argus links against it cleanly.

# Pinned to a known-good ghostty main commit (1.3.2-dev). This is the API that
# Argus/Ghostty/*.swift is currently written against — bump deliberately, and
# re-check the C API drift notes in Frameworks/README.md if you do.
GHOSTTY_REF="${GHOSTTY_REF:-88b4cd047fa627cdca6781bc7e7dc8b75a2cecb9}"
ZIG_PINNED_VERSION="0.15.2"
ZIG_VERSION="${ZIG_VERSION:-$ZIG_PINNED_VERSION}"
# SHA-256 of the official Zig ${ZIG_PINNED_VERSION} macOS tarballs, from
# https://ziglang.org/download/index.json. Pinned so a corrupted or tampered
# download fails loudly instead of being run as the build toolchain. These
# apply to ZIG_PINNED_VERSION only — bump them in lockstep when you bump it,
# or set ZIG_SHA256 to override for a one-off version.
ZIG_SHA256_AARCH64="3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/argus/ghosttykit}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--force]

Builds GhosttyKit.xcframework from ghostty-org/ghostty and symlinks it into
Frameworks/GhosttyKit.xcframework.

The built framework is vendored OUTSIDE the repo (in CACHE_DIR), and the repo
just gets a gitignored symlink pointing at it. That cache is shared across all
git worktrees. A cached framework is reused only when its recorded Ghostty
commit, local patch, Zig version, build mode, and architecture match this invocation.

Options:
  -f, --force   Rebuild even if a complete framework is already cached

Environment overrides:
  GHOSTTY_REF   Ghostty commit/tag/branch to build (default: ${GHOSTTY_REF});
                use a recent main commit — see the note at the top of this file
  ZIG_VERSION   Zig version to build with (default: ${ZIG_VERSION});
                must match the ref's build.zig.zon minimum_zig_version
  ZIG_SHA256    Expected sha256 of the Zig tarball; required when ZIG_VERSION
                is overridden (the built-in checksums cover ${ZIG_PINNED_VERSION} only)
  CACHE_DIR     Where to vendor the built framework (default: ${CACHE_DIR})
EOF
    exit 0
}

FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)  usage ;;
        -f|--force) FORCE=1; shift ;;
        *) printf "Unknown argument: %s\n\n" "$1" >&2; usage ;;
    esac
done

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY_PATCH="${PROJECT_DIR}/scripts/patches/ghostty-unique-archive-members.patch"
GHOSTTY_PATCH_SHA256="$(shasum -a 256 "${GHOSTTY_PATCH}" | awk '{print $1}')"

log()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m==>\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m==>\033[0m %s\n" "$*" >&2; }

HOST_ARCH="$(uname -m)"
if [[ "${HOST_ARCH}" != "arm64" ]]; then
    err "Unsupported architecture: ${HOST_ARCH}. Argus and its GhosttyKit build are arm64-only."
    exit 1
fi

CACHE_ARTIFACTS="${CACHE_DIR}/artifacts"
CACHE_LOCK="${CACHE_DIR}/build.lock"
BUILD_MODE="ReleaseFast"
BUILD_TARGET="native"
CACHE_FORMAT_VERSION="1"
zig_tarball="zig-aarch64-macos-${ZIG_VERSION}.tar.xz"
zig_sha256="${ZIG_SHA256:-$ZIG_SHA256_AARCH64}"
artifact_dir=""
artifact_framework=""
macos_slice=""
LOCK_HELD=0
WORK_DIR=""
staging_dir=""

cleanup() {
    if [[ -n "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
    if [[ -n "${staging_dir}" ]]; then
        rm -rf "${staging_dir}"
    fi
    if [[ "${LOCK_HELD}" -eq 1 ]]; then
        rm -f "${CACHE_LOCK}"
    fi
}
trap cleanup EXIT

mkdir -p "${CACHE_DIR}"
lock_deadline=$((SECONDS + 300))
until shlock -f "${CACHE_LOCK}" -p "$$"; do
    if (( SECONDS >= lock_deadline )); then
        err "Timed out waiting for another GhosttyKit build to release ${CACHE_LOCK}"
        exit 1
    fi
    sleep 1
done
LOCK_HELD=1

# The lock proves no live invocation owns cache staging paths. Clear leftovers
# from interrupted runs before inspecting or publishing artifacts.
mkdir -p "${CACHE_ARTIFACTS}"
rm -rf "${CACHE_ARTIFACTS}"/.staging.*

# Resolve moving branch/tag overrides before checking the cache. The default is
# already an immutable commit, so normal cached setup remains network-free.
if [[ "${GHOSTTY_REF}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    GHOSTTY_COMMIT="$(printf '%s' "${GHOSTTY_REF}" | tr '[:upper:]' '[:lower:]')"
else
    log "Resolving ghostty-org/ghostty@${GHOSTTY_REF}"
    GHOSTTY_COMMIT="$(
        git ls-remote https://github.com/ghostty-org/ghostty.git \
            "${GHOSTTY_REF}" "${GHOSTTY_REF}^{}" \
            | awk '/\^\{\}$/ { peeled=$1 } NR == 1 { first=$1 } END { print peeled ? peeled : first }'
    )"
    if [[ ! "${GHOSTTY_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
        err "Could not resolve Ghostty ref: ${GHOSTTY_REF}"
        exit 1
    fi
fi

CACHE_KEY="$(printf '%s\n' \
    "cache_format_version=${CACHE_FORMAT_VERSION}" \
    "ghostty_commit=${GHOSTTY_COMMIT}" \
    "ghostty_patch_sha256=${GHOSTTY_PATCH_SHA256}" \
    "zig_version=${ZIG_VERSION}" \
    "zig_sha256=${zig_sha256}" \
    "host_arch=${HOST_ARCH}" \
    "build_mode=${BUILD_MODE}" \
    "build_target=${BUILD_TARGET}" \
    | shasum -a 256 | awk '{print $1}')"
artifact_dir="${CACHE_ARTIFACTS}/${CACHE_KEY}"
artifact_framework="${artifact_dir}/GhosttyKit.xcframework"
macos_slice="${artifact_framework}/macos-arm64"

cache_provenance_ok() {
    local metadata="${artifact_framework}/argus-build-info"
    [[ -f "${metadata}" ]] || return 1
    grep -qxF "cache_key=${CACHE_KEY}" "${metadata}" \
        && grep -qxF "cache_format_version=${CACHE_FORMAT_VERSION}" "${metadata}" \
        && grep -qxF "ghostty_commit=${GHOSTTY_COMMIT}" "${metadata}" \
        && grep -qxF "ghostty_patch_sha256=${GHOSTTY_PATCH_SHA256}" "${metadata}" \
        && grep -qxF "zig_version=${ZIG_VERSION}" "${metadata}" \
        && grep -qxF "zig_sha256=${zig_sha256}" "${metadata}" \
        && grep -qxF "host_arch=${HOST_ARCH}" "${metadata}" \
        && grep -qxF "build_mode=${BUILD_MODE}" "${metadata}" \
        && grep -qxF "build_target=${BUILD_TARGET}" "${metadata}"
}

# project.yml links \`-lghostty\`, which expects \`libghostty.a\`. A native
# (arm64-only) main build names the combined archive \`libghostty-internal-fat.a\`;
# alias it. Older refs/flag combos use other names — handle those too. Returns
# non-zero if no linkable archive is present.
alias_lib() {
    if [[ ! -e "${macos_slice}/libghostty.a" ]]; then
        local alt
        for alt in libghostty-internal-fat.a libghostty-fat.a ghostty-internal.a; do
            if [[ -e "${macos_slice}/${alt}" ]]; then
                ln -s "${alt}" "${macos_slice}/libghostty.a"
                break
            fi
        done
    fi
    [[ -e "${macos_slice}/libghostty.a" ]]
}

# Verify the archive actually contains the C API and a bundled-dep symbol, so a
# silently-incomplete build (see the note at the top) is caught instead of
# failing at Argus link time. Materialize \`nm\`'s (large) output once and grep a
# here-string — piping \`nm | grep -q\` under \`set -o pipefail\` is a false-
# negative trap: \`grep -q\` exits on first match, \`nm\` gets SIGPIPE mid-write,
# and pipefail then reports the whole pipeline as failed even though the symbol
# WAS found. Also reject duplicate member names that make dSYM lookup ambiguous.
sanity_ok() {
    local lib_real lib_syms sym duplicate_members
    lib_real="$(cd "${macos_slice}" && readlink libghostty.a || echo libghostty.a)"
    duplicate_members="$(ar -t "${macos_slice}/${lib_real}" | sort | uniq -d)" || return 1
    if [[ -n "${duplicate_members}" ]]; then
        err "Archive contains duplicate object names; dSYM lookup would be ambiguous: ${duplicate_members}"
        return 1
    fi
    lib_syms="$(nm "${macos_slice}/${lib_real}" 2>/dev/null || true)"
    for sym in _ghostty_app_new _spvc_context_create; do
        grep -qE " [TtSsDdBbC] ${sym}$" <<<"${lib_syms}" || return 1
    done
}

# (Re)create the gitignored repo symlink -> the shared cache copy.
link_into_repo() {
    rm -f "${PROJECT_DIR}/Frameworks/GhosttyKit.xcframework"
    ln -s "${artifact_framework}" "${PROJECT_DIR}/Frameworks/GhosttyKit.xcframework"
}

# Fast path: a complete framework is already cached (e.g. built in another
# worktree — the cache lives outside the repo and is shared). Skip the rebuild
# and just relink.
if [[ "${FORCE}" -eq 0 && -d "${artifact_framework}" ]] \
    && cache_provenance_ok && alias_lib && sanity_ok; then
    link_into_repo
    ok "Reused cached GhosttyKit.xcframework (${CACHE_DIR}) -> Frameworks/GhosttyKit.xcframework"
    log "Pass --force to rebuild (e.g. after bumping GHOSTTY_REF)."
    exit 0
fi

WORK_DIR="$(mktemp -d)"

# The pinned checksums are for ZIG_PINNED_VERSION only. If ZIG_VERSION was
# overridden, demand an explicit ZIG_SHA256 rather than verifying against the
# wrong (guaranteed-to-mismatch) hash — fail closed with a clear message.
if [[ "${ZIG_VERSION}" != "${ZIG_PINNED_VERSION}" && -z "${ZIG_SHA256:-}" ]]; then
    err "ZIG_VERSION was overridden to ${ZIG_VERSION}, but the pinned checksums are"
    err "for ${ZIG_PINNED_VERSION} only. Set ZIG_SHA256 to the sha256 of ${zig_tarball}"
    err "(see https://ziglang.org/download/index.json) and re-run."
    exit 1
fi

log "Fetching Zig ${ZIG_VERSION}"
curl -fsSL -o "${WORK_DIR}/zig.tar.xz" "https://ziglang.org/download/${ZIG_VERSION}/${zig_tarball}"
log "Verifying Zig tarball checksum"
if ! shasum -a 256 -c - <<<"${zig_sha256}  ${WORK_DIR}/zig.tar.xz" >/dev/null 2>&1; then
    err "Zig tarball checksum mismatch — expected ${zig_sha256}."
    err "Refusing to run an unverified toolchain. Got: $(shasum -a 256 "${WORK_DIR}/zig.tar.xz" | awk '{print $1}')"
    exit 1
fi
tar xf "${WORK_DIR}/zig.tar.xz" -C "${WORK_DIR}"
ZIG="${WORK_DIR}/${zig_tarball%.tar.xz}/zig"

log "Fetching ghostty-org/ghostty@${GHOSTTY_COMMIT}"
# --branch only accepts tags/branches; GHOSTTY_REF is a commit SHA, so fetch it
# explicitly (GitHub allows fetching an unadvertised SHA). Shallow is fine — the
# version comes from build.zig.zon, not `git describe`, and deps are fetched by
# the Zig package manager at build time (no git submodules).
mkdir -p "${WORK_DIR}/ghostty"
git -C "${WORK_DIR}/ghostty" init -q
git -C "${WORK_DIR}/ghostty" remote add origin https://github.com/ghostty-org/ghostty.git
git -C "${WORK_DIR}/ghostty" fetch -q --depth 1 origin "${GHOSTTY_COMMIT}"
git -C "${WORK_DIR}/ghostty" checkout -q FETCH_HEAD
if [[ "$(git -C "${WORK_DIR}/ghostty" rev-parse HEAD)" != "${GHOSTTY_COMMIT}" ]]; then
    err "Fetched Ghostty commit does not match resolved ref ${GHOSTTY_COMMIT}"
    exit 1
fi
# Patch only the disposable checkout, never an artifact another worktree uses.
# Its content hash is part of the cache identity so packaging changes rebuild.
log "Applying Ghostty archive naming fix"
git -C "${WORK_DIR}/ghostty" apply --check "${GHOSTTY_PATCH}"
git -C "${WORK_DIR}/ghostty" apply "${GHOSTTY_PATCH}"
cd "${WORK_DIR}/ghostty"

do_zig_build() {
    # Build only the arm64 library in an optimized mode. When the SDK workaround
    # is active, the xcrun shim affects this attempt and every later retry.
    if [[ "${USE_OLDER_SDK}" -eq 1 ]]; then
        PATH="${WORK_DIR}/fakebin:${PATH}" "${ZIG}" build \
            -Doptimize="${BUILD_MODE}" -Demit-xcframework=true \
            -Demit-macos-app=false -Dxcframework-target="${BUILD_TARGET}"
    else
        "${ZIG}" build -Doptimize="${BUILD_MODE}" -Demit-xcframework=true \
            -Demit-macos-app=false -Dxcframework-target="${BUILD_TARGET}"
    fi
}

log "Building xcframework (${BUILD_MODE}, arm64 — this takes a few minutes)"
USE_OLDER_SDK=0
INSTALLED_METAL_TOOLCHAIN=0
while ! do_zig_build 2>"${WORK_DIR}/build.log"; do
    if [[ "${USE_OLDER_SDK}" -eq 0 ]] \
        && grep -qE "undefined symbol: (_abort|__availability_version_check)" "${WORK_DIR}/build.log"; then
        log "Hit the Zig ${ZIG_VERSION} / new-SDK .tbd issue; retrying against an older SDK"
        # -type d excludes the MacOSX.sdk / MacOSXNN.sdk shortcut symlinks,
        # which point at the current (newest) SDK — the one causing this in
        # the first place. Only real, fully-versioned SDK directories count.
        older_sdk="$(find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -type d -name 'MacOSX*.sdk' 2>/dev/null | sort -V | head -1)"
        current_sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)"
        if [[ -z "$older_sdk" || "$older_sdk" -ef "$current_sdk" ]]; then
            err "No older MacOSX SDK found under CommandLineTools/SDKs to work around this."
            cat "${WORK_DIR}/build.log" >&2
            exit 1
        fi
        mkdir -p "${WORK_DIR}/fakebin"
        cat > "${WORK_DIR}/fakebin/xcrun" <<XCRUN
#!/bin/bash
if [[ "\$*" == *"--sdk macosx --show-sdk-path"* ]]; then
    echo "${older_sdk}"
    exit 0
fi
exec /usr/bin/xcrun "\$@"
XCRUN
        chmod +x "${WORK_DIR}/fakebin/xcrun"
        USE_OLDER_SDK=1
    elif [[ "${INSTALLED_METAL_TOOLCHAIN}" -eq 0 ]] \
        && grep -q "missing Metal Toolchain" "${WORK_DIR}/build.log"; then
        log "Installing the Metal Toolchain"
        xcodebuild -downloadComponent MetalToolchain
        INSTALLED_METAL_TOOLCHAIN=1
    else
        cat "${WORK_DIR}/build.log" >&2
        exit 1
    fi
done

framework_out="${WORK_DIR}/ghostty/macos/GhosttyKit.xcframework"
if [[ ! -d "$framework_out" ]]; then
    err "Build finished but ${framework_out} is missing"
    exit 1
fi

log "Validating and publishing into ${CACHE_DIR}"
mkdir -p "${CACHE_ARTIFACTS}"
staging_dir="${CACHE_ARTIFACTS}/.staging.${CACHE_KEY}.$$"
mkdir -p "${staging_dir}"
cp -R "${framework_out}" "${staging_dir}/GhosttyKit.xcframework"

macos_slice="${staging_dir}/GhosttyKit.xcframework/macos-arm64"
alias_lib || { err "No linkable archive found in built framework to alias as libghostty.a"; exit 1; }
sanity_ok || { err "Built archive failed symbol or unique-member validation; refusing to publish it."; exit 1; }
cat >"${staging_dir}/GhosttyKit.xcframework/argus-build-info" <<EOF
cache_key=${CACHE_KEY}
cache_format_version=${CACHE_FORMAT_VERSION}
ghostty_commit=${GHOSTTY_COMMIT}
ghostty_patch_sha256=${GHOSTTY_PATCH_SHA256}
zig_version=${ZIG_VERSION}
zig_sha256=${zig_sha256}
host_arch=${HOST_ARCH}
build_mode=${BUILD_MODE}
build_target=${BUILD_TARGET}
EOF

# Publish one immutable directory per input set. Worktrees link directly to it,
# so a new build never moves or replaces a valid artifact used elsewhere. A
# forced rebuild still validates fresh output, but retains an equivalent valid
# cached artifact rather than creating duplicate 150 MB copies.
macos_slice="${artifact_framework}/macos-arm64"
if [[ -d "${artifact_framework}" ]] && cache_provenance_ok && sanity_ok; then
    rm -rf "${staging_dir}"
    staging_dir=""
else
    rm -rf "${artifact_dir}"
    mv "${staging_dir}" "${artifact_dir}"
    staging_dir=""
fi
macos_slice="${artifact_framework}/macos-arm64"
if ! cache_provenance_ok || ! sanity_ok; then
    err "Published GhosttyKit cache failed final validation"
    exit 1
fi

log "Symlinking Frameworks/GhosttyKit.xcframework"
link_into_repo

ok "Built ghostty-org/ghostty@${GHOSTTY_COMMIT} -> ${PROJECT_DIR}/Frameworks/GhosttyKit.xcframework"
