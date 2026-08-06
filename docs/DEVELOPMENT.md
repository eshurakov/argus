# Developing Argus

## Requirements

Argus targets macOS 14 and Swift 6. The Xcode project is generated from `project.yml` for Xcode 16.

Required tools:

- Xcode 16 or later;
- Xcode command-line tools;
- XcodeGen;
- SwiftLint;
- the vendored `Frameworks/GhosttyKit.xcframework`.

Swift 6 toolchains include `swift-format`. Install the other command-line tools with:

```sh
brew install xcodegen swiftlint
```

Node.js and npm are optional. They are used only to rebuild the committed Pierre diff renderer bundle.

## Generate the Xcode project

`project.yml` is the source of truth for Xcode project configuration.

```sh
./scripts/build.sh generate
```

The build script generates `Argus.xcodeproj` automatically if it is missing.

## Build commands

Build the Debug application and CLI scaffold:

```sh
./scripts/build.sh build
```

Build and launch:

```sh
./scripts/build.sh run
```

Build a Release configuration:

```sh
./scripts/build.sh build --release
```

Install a local build in `/Applications` and launch it:

```sh
./scripts/build.sh install --release
```

Other supported commands:

```sh
./scripts/build.sh cli
./scripts/build.sh clean
./scripts/build.sh web
```

Pass `--no-cli` to omit the CLI scaffold or `--no-open` to build or install without launching Argus.

Build products are written under `.build/Build/Products/<configuration>/`. Within the built application, the CLI is bundled at `Argus.app/Contents/Resources/bin/argus`. It currently exposes version and help output only; socket-backed commands are future work.

## Tests and formatting

Run the complete app and CLI validation suite:

```sh
./scripts/test.sh
```

The script runs formatting checks and SwiftLint, executes the macOS `ArgusTests` target, builds the CLI, and verifies its version and help output.

Run linting by itself:

```sh
./scripts/lint.sh
```

Format Swift sources:

```sh
./scripts/format.sh
```

Set `SWIFT_FORMAT_BIN` or `SWIFTLINT_BIN` when the executables are outside the active Swift toolchain and standard Homebrew paths.

Tests are grouped by product domain:

- `WorkspaceTests`: window, sidebar, tab, Panel, Browser, Settings, and Agent Status behavior;
- `WorktreeTests`: Projects, repositories, branches, and worktrees;
- `SessionTests`: Session Snapshot and restore behavior;
- `GitStatusTests`: status parsing, Files and Changes behavior, operations, and previews;
- `TestSupport`: shared native test helpers.

Prefer behavioral tests through `@testable import Argus`. Source-contract tests are reserved for SwiftUI and AppKit wiring that cannot be observed through a stable boundary without a full UI test.

## Diff renderer bundle

Argus renders structured diffs through a small WebKit bridge around `@pierre/diffs`. The generated `Argus/Resources/pierre-diffs-bundle.js` is committed so normal Xcode builds do not need Node.js or network access.

When `ArgusWeb` dependencies or bridge source change, rebuild the bundle with:

```sh
./scripts/build.sh web
```

Commit the updated bundle with its source or dependency change. See
`docs/adrs/0001-render-structured-diffs-with-an-argus-owned-webkit-bridge.md`
for ownership and runtime boundaries.

## GhosttyKit

Normal builds use the vendored `Frameworks/GhosttyKit.xcframework`. Rebuilding the framework is a maintainer task and is separate from the normal application workflow. See `Frameworks/README.md` and `scripts/build-ghosttykit.sh` before changing it.

## Agent integrations

Argus installs integrations only when enabled from Settings. Kilo owns its
managed JSON/JSONC declaration and completion extension. Pi owns
`extensions/argus-agent-status.js` under the effective `PI_CODING_AGENT_DIR`
(or `~/.pi/agent` when the variable is unset). Existing files owned by another
program are never replaced or removed.

Restart Kilo sessions after changing the Kilo integration. Restart Pi or use
`/reload` after changing the Pi integration. Both integrations send requests to
the app-owned `~/.argus/argus.sock` endpoint. The socket accepts
`agent.turnCompleted`, `agent.statusChanged`, and `agent.statusCleared`; it is
not a Companion CLI command transport.

## Local state

Argus writes user state outside the repository:

- Session Snapshot: `~/Library/Application Support/Argus/session.json`
- Managed Worktrees: `~/.argus/worktrees/<project-uuid>/<branch-slug>/`
- App-owned socket: `~/.argus/argus.sock`

Set `ARGUS_DISABLE_SESSION_RESTORE=1` to launch without restoring the previous Session Snapshot.
