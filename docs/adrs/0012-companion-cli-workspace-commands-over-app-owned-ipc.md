# ADR 0012: Companion CLI Workspace Commands over app-owned IPC

- Status: Accepted
- Date: 2026-09-04

## Context

The Companion CLI shipped as a versioned scaffold with no commands. Listing
Workspaces and creating a Worktree Workspace from a terminal — including a
Workspace stacked on another Workspace's branch — needs live state that only the
running application has: Project membership, Workspace Numbers in left-sidebar
order, Stack Groups derived from recorded branch parents, the Selected
Workspace, and the branch names already taken in a repository.

Two shapes were available. The CLI could read `session.json` and run `git`
itself, or it could ask the application. Reading the Session Snapshot would give
the CLI a second, always-stale copy of durable state, would miss runtime-only
state such as Stack snapshots entirely, and would let two processes create
worktrees in one repository with no shared validation. The application already
owns a Unix Domain Socket Server with bounded version-one JSON framing.

## Decision

The app-owned Socket Server accepts a second method family for the Companion
CLI: `workspace.list` and `workspace.create`. `AgentSocketServer` remains the
implementing type; its dispatch decodes method-independent request fields first,
so each family decodes its own typed parameters and an unrecognized method still
answers `unknown_method`.

The CLI stays transport-only. It encodes one request, reads one response, and
renders it. It sends unresolved references — a Project or Workspace ID, name,
branch, or `.` for the calling terminal's context — plus `ARGUS_WORKSPACE_ID`
and the working directory. `WorkspaceCommandRuntime` resolves them on the
MainActor, refuses ambiguity with its candidates, generates branch names through
`WorktreeService`, and reuses `addWorkspaceToProject` so socket-initiated
creation inherits the in-app path's revalidation of Project identity and
repository root across the Git suspension, plus its immediate Session Snapshot
checkpoint.

The wire contract lives in `ArgusIPC/`, compiled directly into the application
target and consumed as a module by the CLI, so framing, method names, and
failure codes have one definition.

The bundled CLI is reachable by name. Argus already injects `ARGUS_SOCKET_PATH`,
`ARGUS_WORKSPACE_ID`, and `ARGUS_SURFACE_ID` into every spawned shell, so the
same mechanism puts `Contents/Resources/bin` first on that shell's `PATH`.
Ghostty applies caller-supplied variables after its own environment work, so
that value is composed from the inherited `PATH` plus the application binary
directory Ghostty appends — replacing it outright would silently drop that
directory. A build that skipped CLI bundling changes nothing.

Workspace Commands do not select. `addWorkspaceToProject` takes a
`selectsNewWorkspace` flag; the CLI passes false and Argus refreshes the
Project's Stack grouping instead of revealing the new Workspace. Nothing
activates the application or moves the Selected Workspace, Active Tab, or
Focused Pane.

## Consequences

- The CLI can never disagree with the application about identity, ordering, or
  branch availability, because it decides none of them.
- One socket, one framing, and one failure-code enum serve agents and the CLI;
  a third method family adds a dispatch case rather than a transport.
- A CLI built against an older contract still reports an unfamiliar failure
  code, because the wire carries codes as strings.
- Creating a Workspace from a terminal is silent in the UI: it appears in the
  sidebar without stealing the user's place. Users who expect the in-app
  behavior of jumping to the new Workspace will not get it.
- Creation holds the client connection for the length of the Git work, so the
  CLI uses a long response timeout while list uses a short one.
- `argus` works without setup in an Argus terminal, where `.` and the working
  directory resolve a context. From an ordinary terminal it needs its bundled
  path or a user-made symlink, and `.` has no Workspace to resolve.
- Argus now owns one more piece of the spawned shell's environment. A shell
  configuration that rebuilds `PATH` from scratch rather than extending it
  drops the bundled directory again.
- Commands that would move selection, close Workspaces, or take Pull Request
  intake remain in-app actions and are not part of this decision.

## References

- `docs/SPEC.md` (§Companion CLI)
- `CONTEXT.md`
- `docs/adrs/0002-agent-turn-completion-through-app-owned-ipc.md`
- `docs/adrs/0003-live-agent-status-through-app-owned-ipc.md`
- `docs/adrs/0013-record-branch-parents-for-argus-created-branches.md`
- `Argus/Services/WorkspaceCommandRuntime.swift`
- `Argus/Services/WorkspaceCommandProtocol.swift`
- `ArgusIPC/ArgusSocketProtocol.swift`
