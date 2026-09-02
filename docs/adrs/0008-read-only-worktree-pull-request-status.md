# ADR 0008: Read-only Worktree Pull Request Status

- Status: Accepted
- Date: 2026-08-30
- Supersedes: only the no-automatic-refresh consequence of [ADR 0005](0005-pull-request-workspace-through-active-github-cli.md).

## Context

Worktree Workspaces need current Pull Request lifecycle, review/check summaries,
and freshness without requiring Pull Request intake or a review environment.
The currently checked-out branch can differ from the branch originally opened;
provider association therefore cannot be inferred from stored Workspace labels.

## Decision

Extend the existing active GitHub CLI boundary with optional, read-only status
queries. Verify the CLI-selected Repository Identity against Project fetch URLs
and associate candidates conservatively using observed branch/HEAD and upstream
identity. Do not introduce credentials, provider mutations, or automatic Git
fetches/checkouts as part of status refresh.

Own one Workspace-scoped, MainActor runtime in `MainWindowView`, above conditional
sidebars. A single due-work scheduler, bounded provider concurrency, and separate
Project/Workspace retry scopes keep refresh independent of row rendering and
local Git Status work. Revalidate request context before publishing and keep
matching cached data visibly stale when it cannot be refreshed safely.

Only ADR 0005's statement that the Worktree Workspace "does not refresh
automatically" is superseded. Its active-CLI credential boundary, explicit
intake, fetch-remote validation, authoritative fetched head, collision/reuse
protections, and absence of durable provider association remain unchanged.

## Consequences

- The inline badge and popover (design A) work independently of the Right
  Sidebar; neither a Changes View module nor Review Work Mode is introduced.
- Optional foreground provider reads add cache and lifecycle management, but
  missing CLI/authentication and provider failures never block local work.
- Conservative matching may leave a Pull Request unassociated; incomplete
  checks and stale data must not imply success or merge readiness.
- Provider status stays process-local. No Session Snapshot schema change or
  credential store is needed; restored Workspaces must be rediscovered.

## References

- `docs/SPEC.md`
- `docs/UI_DESIGN_PRINCIPLES.md`
- `CONTEXT.md`
- `Argus/Services/GitHubPullRequestService+Status.swift`
- `Argus/Services/WorkspacePullRequestStatusModel.swift`
