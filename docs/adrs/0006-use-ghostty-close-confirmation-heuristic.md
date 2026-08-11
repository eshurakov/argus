# ADR 0006: Use Ghostty's close-confirmation heuristic

- Status: Accepted
- Date: 2026-08-11

## Context

Closing a Terminal Pane, Terminal Tab, Workspace, or the application can kill a
still-running child process. Argus needs one process-liveness signal that can
gate those user-initiated close paths without inventing a second process model.

Ghostty already exposes `ghostty_surface_needs_confirm_quit` and
`ghostty_app_needs_confirm_quit`. Those APIs honor the user's
`confirm-close-surface` setting and, in the default mode, treat a shell sitting
at a prompt as safe to close. GhosttyKit does not expose process-group
enumeration.

## Decision

Argus uses Ghostty's per-surface close-confirmation heuristic as the only
running-process signal. User-initiated close and quit paths query
`TerminalSurface.needsConfirmQuit`. Ghostty-initiated surface close forwards the
callback's `processAlive` value, which is the same heuristic.

Argus does not scan process groups, inspect foreground PIDs, or add a separate
Argus setting that duplicates `confirm-close-surface`.

## Consequences

Confirmation accuracy depends on Ghostty shell integration and the user's
Ghostty configuration. A shell without prompt reporting may look busy, and
`confirm-close-surface = false` disables the prompt. That is preferable to Argus
owning a second, incomplete process tree.

Close confirmation stays at the operation owner (`WorkspaceManager` and
application termination), not inside `Workspace.closeTab` or
`Workspace.closePane`, so automatic teardown and restore can still remove
surfaces without prompting.

## References

- `docs/SPEC.md` terminal close and quit rules
- `Argus/Ghostty/TerminalSurface.swift`
- Ghostty `confirm-close-surface`
