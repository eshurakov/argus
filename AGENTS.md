# Argus — Agent Instructions

## First Thing: Read the Spec

**Before any work, read `docs/SPEC.md`**. It is the authoritative contract for the current stable application. Documents under `docs/proposals/` describe future work and do not override the spec until implemented and promoted.

## Domain Context

Before changing domain behavior, read `CONTEXT.md`.
Use canonical terms from `CONTEXT.md` in code, docs, task descriptions, tests, and agent outputs.
Do not introduce synonyms for existing concepts unless updating `CONTEXT.md` first.
Do not duplicate the full context contract inside `AGENTS.md`.

## UI Design

Before creating or materially changing UI, read `docs/UI_DESIGN_PRINCIPLES.md`.
Follow its UI behavior contract. The application spec remains authoritative for product behavior.

## Architecture Decisions

Record accepted cross-cutting architecture decisions in `docs/adrs/` using the
format in `docs/adrs/README.md`. Keep current product behavior in `docs/SPEC.md`
and operational instructions in `docs/DEVELOPMENT.md` or `docs/RELEASING.md`.
When changing a recorded decision, add a superseding ADR instead of rewriting
the original record.

## Changelog

Before pushing code to origin, add an entry to `CHANGELOG.md` for the changes being pushed.
Use the date as the heading in `YYYY-MM-DD` format, without a version number. Describe each
change in simple English and link to the commit or commits for that change.

## Releases

Follow `RELEASE.md` when releasing a feature, including versioning, verification, changelog,
commit, tag, and push steps. `docs/RELEASING.md` covers optional local installation.

## What This Is

Argus is a **personal macOS terminal workspace manager** built on libghostty. Single user, single machine, not distributed. Simplicity and correctness are the priorities — do not over-engineer.

Human-facing setup and repository orientation live in `README.md` and `docs/DEVELOPMENT.md`.

## Tech Stack

- **Swift 6 + SwiftUI** for the app, **AppKit** for window/NSView management
- **GhosttyKit.xcframework** (pre-built, vendored in `Frameworks/`) for GPU-accelerated Metal terminal rendering
- **WKWebView** for embedded browser panels
- **Swift Argument Parser** for the Companion CLI scaffold
- **FSEvents API** (`FSEventStreamCreate`) for filesystem watching — NOT `DispatchSource.makeFileSystemObjectSource`
- **Process spawning** (`git` CLI) for all git operations — no libgit2
- **JSON (Codable)** for persistence at `~/Library/Application Support/Argus/`

## Architecture

Single-process app with two build targets:

1. **Argus** (app) — Xcode project target with Obj-C bridging header for GhosttyKit and a process-wide Socket Server implementing agent turn-completion and live Agent Status methods
2. **argus** (Companion CLI) — SwiftPM-based scaffold; it has no socket-backed commands

```
Argus/
  App/          ArgusApp.swift, AppDelegate.swift
  Views/        MainWindowView, Sidebar/, Content/, GitSidebar/, Titlebar/
  Models/       Project, Workspace, Terminal/Browser/File/Git Preview Panels
  Services/     WorkspaceManager, WorktreeService, GitStatus services,
                AgentStatusStore, AgentStatusRuntime, AgentSocketServer,
                KiloIntegrationService, PiIntegrationService
  Ghostty/      GhosttyApp, TerminalSurface, TerminalView, GhosttyConfig
  Browser/      BrowserPanel, BrowserView
ArgusCLI/
  main.swift    CLI scaffold
```

## Key Domain Concepts

- **Project** — UUID-keyed collection of workspaces tied to a git repo. One catch-all project (non-removable) holds unassigned workspaces.
- **Workspace** — User work context with one Workspace Root and ordered Top-level Tabs. A Standalone Workspace need not be a git repository.
- **Panel** — Content model for Terminal, Browser, File, or Git Preview content. Only Terminal Panels own a Surface ID.
- **Worktrees** stored at `~/.argus/worktrees/<project-uuid>/<branch-slug>/`
- **Socket Server** — process-wide, app-owned listener at `~/.argus/argus.sock`; it implements `agent.turnCompleted`, `agent.statusChanged`, and `agent.statusCleared`
- **Kilo integration** — explicitly installed or removed through Settings; the Companion CLI remains independent and scaffolded
- **Environment variables** injected into shells: `ARGUS_SOCKET_PATH`, `ARGUS_WORKSPACE_ID`, `ARGUS_SURFACE_ID`
