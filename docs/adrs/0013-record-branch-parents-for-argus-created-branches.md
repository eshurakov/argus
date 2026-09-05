# ADR 0013: Record branch parents for Argus-created branches

- Status: Accepted
- Date: 2026-09-04

## Context

ADR 0009 made recorded branch parents a read-only, tool-agnostic input: Argus
reads `branch.<name>.base` configuration, Graphite parent objects, and
`gh-stack` edges, prefers explicit configuration, and diagnoses contradictions.
Stack Groups in the left sidebar are derived entirely from those records.

Creating a Workspace stacked on another Workspace needs more than a start point.
A branch created with `git worktree add -b child <path> parent` has the right
history, but nothing on disk says `parent` is its parent, so the two Workspaces
never group as a Stack and Against Base has no recorded base to compare with.
Argus cannot infer the relationship later: guessing a parent from history or
branch names is exactly what ADR 0009 rejected.

## Decision

When a Workspace Command creates a branch on an explicit base Workspace, Argus
writes that base branch to `branch.<new-branch>.base` in the repository's shared
local Git configuration — the same declaration the shared reader treats as
authoritative.

The write is deliberately narrow:

- only for a branch Argus has just created, and only at creation time;
- only when the request named a base Workspace, never inferred;
- only the one key for that one branch, through the shared
  `RecordedBaseBranchConfiguration` key format, with both branch names
  validated first;
- never over an existing declaration, because the branch did not exist a moment
  earlier.

This is not the metadata repair ADR 0009 declined: nothing existing is
corrected, migrated, or normalized. Argus declares a parent for a branch that
did not exist a moment earlier, then goes back to reading.

Recording follows worktree creation rather than gating it. The Managed Worktree
already exists by then, so a failed write is reported to the caller as an
unrecorded base instead of discarding the user's new Workspace. Every other
path — in-app creation, Pull Request intake, adoption — keeps writing nothing.

## Consequences

- A Workspace stacked from the Companion CLI appears inside a Stack Group
  immediately, and Against Base resolves its base branch, with no
  stack-management tool installed.
- Argus is now a writer of stack metadata, so its records can contradict a
  tool that later re-parents the same branch. Contradictions stay visible: the
  shared reader prefers explicit configuration and diagnoses conflicting tool
  records per branch.
- Graphite and `gh-stack` users get a declaration they did not author. It is
  the tool-agnostic key, one line per branch, removable with
  `git config --unset`.
- Stacking onto a Workspace whose branch is the Project's main branch records
  the base but forms no Stack Group, because grouping needs at least two open
  Workspaces above a trunk boundary.
- Reading and writing share one key format, so the spelling cannot drift.

## References

- `docs/SPEC.md` (§Companion CLI)
- `CONTEXT.md`
- `docs/adrs/0009-share-tool-agnostic-recorded-parents.md`
- `docs/adrs/0012-companion-cli-workspace-commands-over-app-owned-ipc.md`
- `Argus/Models/RecordedBaseBranch.swift`
- `Argus/Services/WorktreeService+Operations.swift`
