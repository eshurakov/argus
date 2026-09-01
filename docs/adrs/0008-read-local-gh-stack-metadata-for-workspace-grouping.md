# ADR 0008: Read local gh-stack metadata for Workspace grouping

- Status: Superseded
- Date: 2026-08-29
- Superseded by: [ADR 0009](0009-share-tool-agnostic-recorded-parents.md)

## Context

The left sidebar needs to group Workspaces whose branches belong to the same GitHub CLI Stack and show dependency direction. Workspaces live in different worktrees and remain independently owned user contexts.

GitHub's official `gh-stack` is in public preview. In v0.1.0 and the audited August 27 main revision, `gh stack view --json` synchronizes Pull Request metadata against GitHub and saves the tracking file. It is therefore unsuitable as an automatic read-only sidebar query. There is no offline, repository-wide list command.

The CLI records schema-v1 JSON in `<git-dir>/gh-stack`, using `git rev-parse --git-dir`, not the common directory. A linked worktree has its own tracking file, although its branch references are shared. Git itself does not record branch parentage.

## Decision

Read schema-v1 tracking files directly through one isolated local adapter. Resolve the canonical common Git directory, inspect its main and linked-worktree administrative tracking files, and bind recorded branch names to the current Git worktree inventory. This includes tracking created in worktrees without an open Argus Workspace.

Each Stack retains its recorded trunk and linear branch order. The first branch follows the trunk; each later branch follows the previous recorded branch. Cached commit hashes and ordinary ancestry are not relationship evidence. Matching duplicate observations coalesce; incompatible or unsupported records produce an unavailable grouping state, never a guessed topology. Reads are bounded and partial JSON writes receive one narrow retry.

The application never invokes `gh stack`, authenticates, fetches, repairs tracking, restacks, or merges while discovering groups. Graphite metadata is not a source for this feature. Existing Against Base behavior remains independent and unchanged.

WorkspaceManager owns an ephemeral per-Project snapshot and one derived navigation projection. The sidebar, shortcut numbering, adjacent navigation, and block reordering consume that projection. The durable Project order remains the user's baseline; refreshes do not rewrite it. Stack Groups do not own Workspaces and have no cascading close operation.

Group keys combine the recorded trunk and first branch within a Project. These are branch references, not display titles. Local-only Stacks have no guaranteed upstream ID, and using this key also avoids changing disclosure identity when a Stack is first published. Only collapsed keys are persisted, with backward-compatible defaults; provider responses and observers are not.

## Consequences

Grouping works offline, before Pull Requests exist, and independently of the Selected Workspace and Right Sidebar. It requires local `gh-stack` tracking, not an installed or authenticated CLI inside the app. Remote-only Stacks are not discovered.

The adapter deliberately depends on a versioned internal format, whose compatibility GitHub does not promise. Unknown schemas fail visibly and leave normal Workspace navigation available. Source provenance, duplicate/conflict tests, and a documented audited revision keep this dependency narrow.

Root-branch renames or replacement may reset a group's disclosure preference. Missing or merged recorded branches do not automatically remove Workspaces; missing local Workspaces appear only as needed branch references. Displayed relationships describe locally recorded order, not current GitHub queue/review state or a guaranteed live Pull Request target.

## References

- [GitHub CLI stacked PR commands](https://docs.github.com/en/pull-requests/reference/stacked-prs-cli-commands)
- [gh-stack v0.1.0](https://github.com/github/gh-stack/releases/tag/v0.1.0)
- [Audited schema and implementation](https://github.com/github/gh-stack/tree/2bd699a544a09cb5c45a013d03416e0894b0454e/internal/stack)
- [View command](https://github.com/github/gh-stack/blob/2bd699a544a09cb5c45a013d03416e0894b0454e/cmd/view.go)
- `docs/proposals/stacked-workspaces-plan.md`
- `docs/SPEC.md`, Projects and Workspaces
