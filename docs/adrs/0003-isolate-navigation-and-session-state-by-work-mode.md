# ADR 0003: Isolate navigation and session state by Work Mode

- Status: Accepted
- Date: 2026-07-26

## Context

Argus currently has one Workspace-centered environment. The Selected Workspace
owns the visible center tabs and supplies context to the Right Sidebar. Pull
Request review needs a different navigation hierarchy and content lifecycle.

Treating Review as a filter over the current environment would couple Pull
Request selection to Code Workspace selection. Treating each Pull Request as a
Code Workspace would also force local-checkout and terminal concepts into a
workflow that can operate without a clone.

Users need to move between coding and review without losing either task's tabs,
selection, layout, or drafts.

## Decision

Argus introduces an application-level Work Mode boundary.

- Code Work Mode contains the current Project, Workspace, Panel, Files, and
  Changes environment.
- Review Work Mode contains Project and Pull Request navigation and Pull Request
  Review Tabs.
- Each Work Mode independently owns its sidebar hierarchy and selection, center
  tabs, Active Tab, Right Sidebar state, layout, and restoration state.
- Switching Work Modes restores the destination state without mutating the
  source state.
- Global Settings and Project identity remain application-wide.
- Review Session State is persisted independently from the Code Work Mode
  Session Snapshot. User-authored review drafts use a stronger autosave boundary.
- Background work in one Work Mode cannot select, activate, or focus content in
  another Work Mode.

## Consequences

- Review can use provider-backed Projects and Pull Requests without pretending
  they are Workspaces or requiring local clones.
- Code Workspace shortcuts and lifecycle rules remain scoped to Code Work Mode.
- Main-window routing, commands, focus restoration, and persistence need an
  explicit Work Mode owner above the current Workspace manager.
- Shared Project identity must support a hosted Repository Identity before a
  local Project Repository Root exists.
- Cross-mode operations use stable identity and service APIs rather than shared
  view selection.
- Adding another Work Mode requires an independent environment contract; a Work
  Mode is not a lightweight feature flag or view filter.

## References

- `docs/proposals/work-modes-review/spec.md`
- `docs/SPEC.md`
- `CONTEXT.md`
- `docs/UI_DESIGN_PRINCIPLES.md`
