# Frameworks/

## GhosttyKit.xcframework

`GhosttyKit.xcframework` is **not committed to git** — it's ~150MB+ and
machine-specific. `Frameworks/GhosttyKit.xcframework` is a symlink
(gitignored — never commit it) pointing at a locally-built copy outside the
repo, e.g.:

```
Frameworks/GhosttyKit.xcframework -> ~/.cache/argus/ghosttykit/artifacts/<input-hash>/GhosttyKit.xcframework
```

The cache records the resolved Ghostty commit, local patch hash, Zig version,
architecture, and build mode. The script rebuilds when those inputs change,
serializes builds shared by multiple worktrees, validates output before
publication, and links each worktree directly to its immutable matching artifact.

If that symlink is missing or broken (fresh clone, new machine, or the cache
was cleared), `xcodebuild` fails immediately with:

```
fatal error: 'ghostty.h' file not found
```

because the bridging header (`Argus/Resources/Argus-Bridging-Header.h`)
imports it, and `HEADER_SEARCH_PATHS` / `LIBRARY_SEARCH_PATHS` in
`project.yml` point into the (missing) framework. Run
`scripts/build-ghosttykit.sh` to (re)build it — it automates everything
below end-to-end, pinned to a known-good ghostty commit. The manual
walkthrough is kept for troubleshooting and for understanding what the script
is doing.

**New git worktree?** The symlink is gitignored, so a fresh worktree won't
have it — but the built framework lives in `CACHE_DIR`
(`~/.cache/argus/ghosttykit/`), *outside* the repo and shared across all
worktrees. Just run `scripts/build-ghosttykit.sh`: if the cache already holds
a complete framework built from the same inputs, it skips the build and only
(re)creates the symlink (a fraction of a second). Pass `--force` to rebuild the
same inputs.

### Building GhosttyKit from source

Ghostty (https://github.com/ghostty-org/ghostty) is written in Zig and
exposes its terminal engine as a C API (`libghostty`). The macOS xcframework
is one of its own build targets.

> **Build a recent ghostty `main`, not the `v1.3.1` tag.** Two things matter
> here that only exist after v1.3.1:
> 1. The exported `ghostty_*` C API carries `GHOSTTY_API` visibility
>    annotations (`__attribute__((visibility("default")))`), so the symbols
>    survive `ReleaseFast` dead-code elimination. On v1.3.1 a `ReleaseFast`
>    xcframework build silently drops **every** `ghostty_*` symbol.
> 2. `src/build/GhosttyLib.zig` combines the bundled dependency archives via
>    `CombineArchivesStep`. A v1.3.1 arm64-only build produced a static lib
>    missing large chunks of the bundled deps (FreeType, spirv-cross,
>    oniguruma, ...), so Argus failed to link.
>
> The script pins `GHOSTTY_REF` to a known-good `main` commit (`1.3.2-dev`).
> That commit is also the API `Argus/Ghostty/*.swift` is written against —
> see "Keeping Argus in sync" below before bumping it.

**1. Get the exact Zig version Ghostty pins to.**

Check `build.zig.zon`'s `minimum_zig_version` in the Ghostty checkout — as
of the pinned commit this is `0.15.2`. Zig has no backwards compatibility
guarantees across minor versions, so it must match exactly; Homebrew's `zig`
formula is usually newer and will fail to even parse Ghostty's `build.zig`.

```bash
curl -fsSL -o zig.tar.xz \
  "https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz"
# Verify against the sha256 published in https://ziglang.org/download/index.json
# before running it as your build toolchain (build-ghosttykit.sh does this for you):
shasum -a 256 -c - <<<"3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b  zig.tar.xz"
tar xf zig.tar.xz
ZIG=./zig-aarch64-macos-0.15.2/zig
```

(Use `zig-x86_64-macos-0.15.2.tar.xz` on Intel — sha256
`375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f`.)

**2. Fetch the pinned Ghostty commit.**

`GHOSTTY_REF` is a commit SHA, so fetch it explicitly (shallow is fine — the
version comes from `build.zig.zon`, and deps are fetched by the Zig package
manager at build time, no git submodules):

```bash
REF=88b4cd047fa627cdca6781bc7e7dc8b75a2cecb9   # ghostty main, 1.3.2-dev
mkdir ghostty && cd ghostty
git init -q
git remote add origin https://github.com/ghostty-org/ghostty.git
git fetch --depth 1 origin "$REF"
git checkout FETCH_HEAD
```

Apply Argus's archive-naming patch before building:

```bash
git apply /path/to/argus/scripts/patches/ghostty-unique-archive-members.patch
```

The macOS and dcimgui packages both produce an `ext.o`. Once combined into
`libghostty.a`, those names make `dsymutil` look in the wrong object for ImGui
symbols. The patch gives the macOS object a unique basename without changing
its code. `scripts/build-ghosttykit.sh` applies the patch in its temporary
checkout and rejects duplicate archive member names before publishing. The
patch hash is part of the cache key, so existing artifacts remain untouched.

**3. Work around Zig 0.15.2 vs. new macOS SDKs.**

Zig 0.15.2's Mach-O linker can fail to parse the `.tbd` library stubs in
very new macOS SDKs, breaking *any* build (not just Ghostty's) with errors
like:

```
error: undefined symbol: _abort
error: undefined symbol: __availability_version_check
```

If you hit this, check whether an older SDK is available alongside your
current Xcode's Command Line Tools:

```bash
ls /Library/Developer/CommandLineTools/SDKs/
```

If there's an older `MacOSX*.sdk` there (e.g. `MacOSX15.4.sdk`), point Zig
at it — but pick an actual versioned directory, not one of the `MacOSX.sdk`
/ `MacOSX26.sdk` shortcut symlinks, which just point back at the newest SDK
(the one causing the problem). Zig always resolves the SDK via
`xcrun --sdk macosx --show-sdk-path` internally and doesn't honor
`SDKROOT`, so shim `xcrun` in `PATH`:

```bash
mkdir -p fakebin
cat > fakebin/xcrun <<'EOF'
#!/bin/bash
if [[ "$*" == *"--sdk macosx --show-sdk-path"* ]]; then
    echo "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
    exit 0
fi
exec /usr/bin/xcrun "$@"
EOF
chmod +x fakebin/xcrun
```

Prefix subsequent commands with `PATH="$(pwd)/fakebin:$PATH"`. Skip this
entirely if a plain `$ZIG build` links fine for you.

**4. Install the Metal Toolchain, if needed.**

Recent Xcode versions ship the Metal shader compiler as an optional
download. If the build fails with:

```
error: cannot execute tool 'metal' due to missing Metal Toolchain
```

run:

```bash
xcodebuild -downloadComponent MetalToolchain
```

**5. Build the xcframework (arm64-only, ReleaseFast).**

```bash
PATH="$(pwd)/fakebin:$PATH" "$ZIG" build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native
```

- `-Dxcframework-target=native` builds an **arm64-only** framework. Argus is
  arm64-only (see `project.yml`'s `ARCHS` and `AGENTS.md` — single machine,
  not distributed), so this skips the x86_64 slice and the lipo/universal
  path entirely. Drop this flag to build a universal `macos-arm64_x86_64`
  slice instead (and point `project.yml` back at that slice path).
- `-Demit-macos-app=false` skips the full `Ghostty.app` bundle — that also
  links an x86_64 app binary, which can fail for reasons unrelated to the
  library (e.g. no Rosetta toolchain). We only need `libghostty`.
- `-Doptimize=ReleaseFast`, **not `Debug`**: a Debug build keeps Ghostty's
  internal `Page.verifyIntegrity()` consistency checks and a
  stack-trace-capturing safety allocator on the hot path — every line op
  (erase, scroll, attribute set) re-verifies and re-hashes the page. That's
  invisible for occasional keystrokes but pegs a CPU core at 100% on any
  surface receiving a steady stream of redraws (a TUI spinner, a busy build
  log), because the `io-reader` thread never catches up. On this (post-1.3.1)
  ghostty the exported C API survives `ReleaseFast` thanks to the
  `GHOSTTY_API` annotations. `Argus.app` itself can still be built in Debug —
  the xcframework is a separate compiled artifact, so you keep Swift-side
  debuggability. Only fall back to `Debug` here if you need to debug a crash
  inside Ghostty's own Zig code.

Output lands at `macos/GhosttyKit.xcframework`, with the combined static lib
at `macos-arm64/libghostty-internal-fat.a`.

**6. Vendor it.** (`scripts/build-ghosttykit.sh` does steps 1-6 for you,
pinned to a known-good `GHOSTTY_REF`/`ZIG_VERSION` — override those env vars
to bump the pinned version.)

Copy the built framework somewhere outside the repo and symlink it in.

```bash
CACHE_DIR="$HOME/.cache/argus/ghosttykit"
mkdir -p "$CACHE_DIR"
rm -rf "$CACHE_DIR/GhosttyKit.xcframework"
cp -R macos/GhosttyKit.xcframework "$CACHE_DIR/GhosttyKit.xcframework"

# project.yml links `-lghostty`, which expects `libghostty.a`. A native
# arm64-only build names the combined archive `libghostty-internal-fat.a`;
# alias it:
macos_slice="$CACHE_DIR/GhosttyKit.xcframework/macos-arm64"
( cd "$macos_slice" && ln -sf libghostty-internal-fat.a libghostty.a )

cd /path/to/argus
rm -f Frameworks/GhosttyKit.xcframework
ln -s "$CACHE_DIR/GhosttyKit.xcframework" Frameworks/GhosttyKit.xcframework
```

**7. Sanity-check the archive is complete**, so a silently-incomplete build
fails here instead of at Argus link time:

```bash
LIB="$CACHE_DIR/GhosttyKit.xcframework/macos-arm64/libghostty-internal-fat.a"
nm "$LIB" | grep " _ghostty_app_new$"       # core C API
nm "$LIB" | grep " _spvc_context_create$"   # a bundled dependency symbol
```

Both must print a `T`/`D` (defined) line. If either is only `U` (undefined)
or missing, the build is incomplete — you're almost certainly on `v1.3.1`
instead of `main` (see the note at the top).

### Keeping Argus's Swift code in sync with Ghostty's C API

Argus's `Argus/Ghostty/*.swift` wrappers are written against the pinned
`GHOSTTY_REF` above. They were originally adapted from a cmux fork of Ghostty
to vanilla upstream; those drifts are **already applied** and are noted here
only as reference for anyone bumping `GHOSTTY_REF`:

- `ghostty_surface_config_s` has no `io_mode` field upstream (the
  `GHOSTTY_SURFACE_IO_EXEC` assignment was removed in `TerminalSurface.swift`
  — leaving `command` unset already gets Ghostty to exec the default shell).
- `ghostty_runtime_read_clipboard_cb` returns `Bool` upstream (`true` if the
  clipboard request was started; `GhosttyCallbacks.swift`'s
  `ghosttyReadClipboardCallback` returns a matching value).

Bumping `GHOSTTY_REF` may surface new C API drifts as Swift compile errors.
Diff `macos-arm64/Headers/ghostty.h` in the built framework against the
previous one, and cross-reference the failing symbol against
`macos/Sources/Ghostty/Ghostty.App.swift` in the Ghostty checkout — that's
Ghostty's own reference Swift integration and shows the current expected
usage.
