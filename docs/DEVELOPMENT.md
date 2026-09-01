# Developing Argus

## Requirements

Argus targets macOS 26 and Swift 6. The Xcode project is generated from `project.yml` for Xcode 26.

Required tools:

- Xcode 26 or later;
- Xcode command-line tools;
- XcodeGen;
- SwiftLint;
- the vendored `Frameworks/GhosttyKit.xcframework`.

Swift 6 toolchains include `swift-format`. Install the other command-line tools with:

```sh
brew install xcodegen swiftlint
```

The GitHub CLI is also optional. It is used only when creating a Worktree
Workspace from a Pull Request in a Named Project's New Workspace sheet. Argus
uses the active `gh` authentication context and never stores GitHub
credentials.

Install and authenticate it with:

```sh
brew install gh
gh auth login
```

For a bare Pull Request number, run `gh repo set-default <remote>` from the
Project Repository Root if GitHub CLI reports that the repository is ambiguous
or unavailable. For GitHub Enterprise, authenticate the matching host with
`gh auth login --hostname <host>`.

## Local Stack grouping

Argus groups open Workspaces from locally recorded parent relationships in:

- `branch.<branch>.base` Git configuration;
- Graphite `refs/branch-metadata/<branch>` JSON objects with `parentBranchName`;
- the official [`github/gh-stack`](https://github.com/github/gh-stack)
  extension's schema-v1 `<git-dir>/gh-stack` files.

The same reader supplies Against Base. A valid explicit config value overrides
tool metadata; matching tool parents coalesce, and conflicting parents are
reported rather than guessed. A group requires at least two open Workspaces
in one connected recorded-parent component. Forks retain their shared parent,
while independent branches merely based on the unparented Project main branch
remain separate. Argus never initializes, repairs, restacks, or merges Stacks.

The gh-stack format was audited against v0.1.0 and revision
`2bd699a544a09cb5c45a013d03416e0894b0454e`. Linked worktrees have separate
tracking files, so Argus inspects common and linked administration and binds
verified current checkouts. It does not invoke `gh stack view`, which can
contact GitHub and rewrite tracking even with `--json`. Unknown future schemas
produce diagnostics rather than a guessed interpretation.

The Project context menu provides **Refresh Stacks**. Missing metadata leaves
ordinary rows unchanged; malformed or conflicting sources do not erase valid
unrelated relationships. A current-branch conflict makes only Against Base
unavailable, preserving Working Changes. Repository/common and linked metadata
changes refresh automatically, including configuration and packed Graphite
refs; configuration outside those watched roots is reread on explicit or other
refresh. Metadata files and combined command output are bounded to 1 MiB, and
branch/parent names to 4096 UTF-8 bytes.

With a separate Git directory, a linked checkout may not have enough Git
registration data to recover the physical main checkout. Argus leaves that
unknown binding unbound rather than mistaking metadata storage for a Workspace;
starting from the actual Project Repository Root provides the verified binding.
See [ADR 0009](adrs/0009-share-tool-agnostic-recorded-parents.md).

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

## Native diff rendering

Argus renders structured diffs with the native `SwiftDiffs` package. Git Preview
Tabs keep Split and Unified layout controls; long lines scroll horizontally.
Blame previews remain ANSI text. See
`docs/adrs/0002-render-structured-diffs-with-native-swift-diffs.md` for ownership
and runtime boundaries.

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
