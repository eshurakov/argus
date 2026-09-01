# ADR 0007: Resolve Base Branch from recorded stack metadata

- Status: Superseded
- Date: 2026-08-26
- Superseded by: [ADR 0009](0009-share-tool-agnostic-recorded-parents.md)

## Context

Base Branch resolution was repository-global. A Named Project used its
configured `Project.mainBranch`, and a Standalone Workspace detected
`origin/HEAD`, then local `main` or `master`. The current branch was only ever
used as a negative filter, so every Workspace in a Project resolved the same
Base Branch no matter where its branch actually forked.

That breaks stacked branches and stacked pull requests. A branch stacked on
another branch is still compared with `main`, and because Against Base is a
three-dot comparison, the merge base sits below the stack parent. The section
then shows the union of the branch's own commits and every commit its parent
added, which is precisely the view a stacked pull request does not want.

Git records no branch parentage: commits know their parents, a branch is a
moving pointer, and a rebase destroys the fork point. Nothing in Git itself can
answer "what did this branch fork from". Stacking tools answer it by recording
the parent, and Argus already creates worktree branches without capturing the
start point, so recorded metadata is the only source available today that is
both authoritative and local.

## Decision

Read a Recorded Base Branch for the current branch before applying the
configured and detected rules, from local Git data only:

1. `branch.<current-branch>.base` in Git configuration. Stacking tools write
   this key; Git never sets it.
2. A `parentBranchName` entry in the `refs/branch-metadata/<current-branch>`
   object, which is Graphite's recorded layout.

A recorded name is ignored, and resolution continues with the existing rules,
when it is empty, names the current branch itself, or resolves to no local or
`origin`-tracking reference. Reading a payload that is absent, not JSON, or
missing the expected key is a fallthrough, not a Base Branch failure, because
the layout belongs to another tool.

For a Recorded Base Branch alone, resolve `refs/heads/<parent>` before
`refs/remotes/origin/<parent>`. Configured and detected names keep their
existing origin-first preference.

Reading configuration keyed by the current branch is not inferring a Base
Branch from the branch name, which the spec forbids and this decision does not
change. The prohibition is on name heuristics — stripping a path segment,
parsing a `<child>-onto-<parent>` convention. A recorded value is data a tool
wrote down, not a guess derived from the name's spelling.

## Consequences

A stacked branch now shows only its own commits in Against Base, and its
section title names the parent, so the section matches what a stacked pull
request proposes to merge.

The inverted ref preference is load-bearing rather than cosmetic. A stack parent
is force-pushed on every restack, so `origin/<parent>` is routinely one restack
behind the local branch. Resolving the stale remote reference moves the merge
base backwards and pulls the parent's later commits back into Against Base — a
smaller version of the bug this decision fixes. The cost is that a Recorded Base
Branch whose local branch is itself stale resolves that stale branch; a restack
brings both sides forward, so the local side is the one worth trusting.

Precedence is deliberate. A recorded value describes one branch and the
configured value describes a whole repository, so the more specific value wins.
A Project's configured main branch remains the answer for every branch without
recorded metadata, which is most of them.

Resolution stays offline and read-only: two extra local Git reads per refresh
when the Against Base setting is on, no remote contact, no repository mutation.

The `branch.<name>.base` key is verified against a real stacking setup. The
`parentBranchName` layout is Graphite's documented shape but is not verified
against a real Graphite checkout, so its test asserts the shape this code reads
while a second test pins the more important property: an unreadable payload
falls through without failing.

Other routes were considered and not taken. Recording the start point at
worktree creation would cover Argus-created branches without any tool
dependency and remains the natural next step. Asking the forge with
`gh pr view --json baseRefName` is authoritative for what a pull request merges
into but needs the network and an open pull request, which Base Branch work must
not require. A nearest-ancestor heuristic — filter to branches whose tip is an
ancestor of `HEAD`, then minimize `git rev-list --count <branch>..HEAD` — needs
no metadata and is correct on clean stacks, but it returns nothing mid-restack
and can invert once merge commits enter, so it belongs behind recorded metadata
rather than in place of it.

## References

- `docs/SPEC.md`, "Base Branch and Against Base"
- `Argus/Services/GitStatusService+BaseComparison.swift`
- `Tests/GitStatusTests/GitBaseBranchMetadataTests.swift`
