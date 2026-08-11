# Argus

Argus is a personal macOS terminal workspace manager built on Ghostty. It keeps terminals, browser pages, files, Git previews, Projects, and Git worktrees in one native application.

The current repository is the stable v1 baseline used for day-to-day development. It is a personal tool, not a distributed product.

test

## Current scope

V1 includes:

- Ghostty-backed terminal tabs and split panes;
- Projects, Standalone Workspaces, and Managed Worktrees;
- a Files View with File Tabs;
- a Changes View with Git mutations, diff, and blame previews;
- Browser Panels;
- global Settings;
- session restore for Projects, Workspaces, and Terminal Panels;
- process-local Agent Status presentation.

Named Projects can also create Worktree Workspaces from GitHub Pull Request
URLs or numbers through the active `gh` authentication context. The GitHub CLI
is optional and is needed only for that intake flow.

The Companion CLI is a scaffold and has no socket-backed commands. Argus supports Kilo turn-completion attention and Pi live Agent Status through an app-owned local socket and explicitly installed extensions. V1 does not include agent PID tracking, notification history, macOS notifications, or TTS. Future work is kept under `docs/proposals/`.

## Requirements

- macOS 14 or later
- Xcode 16 or later
- Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [SwiftLint](https://github.com/realm/SwiftLint) for repository validation
- the vendored `Frameworks/GhosttyKit.xcframework`

Node.js is needed only when rebuilding the committed Pierre diff renderer bundle.

The GitHub CLI is an optional runtime requirement for Pull Request Workspaces.
Install and authenticate it with `brew install gh` and `gh auth login` when
using that flow.

Install the development tools with Homebrew:

```sh
brew install xcodegen swiftlint
```

## Build and run

```sh
./scripts/build.sh run
```

Run the complete validation suite with:

```sh
./scripts/test.sh
```

See `docs/DEVELOPMENT.md` for setup, build commands, generated assets, and test organization.

## Documentation

Documents have distinct roles:

1. `docs/SPEC.md` defines current stable behavior.
2. `docs/UI_DESIGN_PRINCIPLES.md` defines UI interaction and presentation rules.
3. `CONTEXT.md` defines canonical domain language and ownership boundaries.
4. `docs/adrs/` records accepted architecture decisions and their consequences; its README defines the record format.
5. `docs/proposals/` contains future changes. Proposals do not describe current behavior until implemented and promoted into the spec.
6. `docs/DEVELOPMENT.md` and `docs/RELEASING.md` contain operational instructions.
7. `AGENTS.md` contains repository instructions for coding agents.

## Repository layout

```text
Argus/          macOS application source
ArgusCLI/       Companion CLI scaffold
ArgusWeb/       Build-time source for the committed diff renderer bundle
Frameworks/     Vendored GhosttyKit framework
Tests/          Swift Testing suites grouped by product domain
docs/           Product, UI, development, release, proposal, and architecture docs
scripts/        Build, test, formatting, lint, and asset scripts
project.yml     XcodeGen project definition
Package.swift   SwiftPM definition for the CLI target
```

## Local data

- Session Snapshot: `~/Library/Application Support/Argus/session.json`
- Managed Worktrees: `~/.argus/worktrees/<project-uuid>/<branch-slug>/`
- Reserved socket path: `~/.argus/argus.sock`

The app-owned Socket Server listens on this path and accepts the implemented agent turn-completion and live Agent Status methods. It does not provide Companion CLI commands.
