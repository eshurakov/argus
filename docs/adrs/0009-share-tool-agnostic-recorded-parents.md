# ADR 0009: Share tool-agnostic recorded parents across grouping and Against Base

- Status: Accepted
- Date: 2026-08-30
- Supersedes: ADR 0007's source precedence and ADR 0008's gh-stack-only grouping and separation from Against Base. Their offline, reference-preference, lifecycle, and persistence constraints remain applicable.

## Context

Users may record branch parents with `branch.<branch>.base`, Graphite's `refs/branch-metadata/<branch>` objects, or the official GitHub `gh-stack` extension. Supporting one source for navigation and different sources for Against Base makes the two surfaces disagree. The user requested one tool-agnostic interpretation, including forks and missing parents, rather than grouping only official gh-stack containers.

## Decision

Introduce one synchronous, Foundation-only local metadata reader and an immutable snapshot of current worktree bindings, recorded parents, trunk hints, and diagnostics. Against Base calls the reader on its existing background worker. The asynchronous Stack service adapts the same reader off MainActor, with cancellation propagation. No provider registry, network access, stack-management CLI invocation, metadata repair, or new production dependency is required.

The reader consumes only relevant Git configuration keys, Graphite parent blobs, and schema-v1 gh-stack files in common and linked-worktree Git directories. Configuration follows effective Git settings, including checked-out worktrees' applicable overrides; neither consumer guesses from cached Workspace branch labels. GitHub tracking arrays contribute direct parent edges, not exclusive container membership. Matching observations coalesce, including consistent partial chains and forks.

A valid, nonempty, non-self explicit `branch.<branch>.base` overrides tool records. Without it, differing recorded tool parents are a conflict, including disagreement between gh-stack files. Cycles are invalid. Conflicted/cyclic incoming edges are excluded and diagnosed rather than arbitrarily selected. Unrelated valid relationships remain usable. Unreadable or malformed provider data produces a diagnostic without erasing a valid explicit parent or unrelated source data; missing/empty records mean no declaration. Branch names are validated independently of local ref existence.

Stack Groups project the resulting parent forest. Unparented configured Project main branches and unparented explicitly declared gh-stack trunks are boundaries, so independent branches do not merge merely through main. A trunk that itself has a recorded parent participates in that relationship. Parents precede children; sibling subtrees keep stable manual ordering. Missing intermediates and shared parents are represented once, with distinct fork connectors, never a fabricated chain. Group identity remains based on recorded root/parent references, not source or title; compatible existing collapsed keys are retained.

Against Base uses the same chosen recorded parent, still resolving local refs before origin-tracking refs. Its existing configured/detected fallback and merge-base-to-HEAD comparison remain unchanged when no usable recorded parent exists. A conflict for the current branch makes only Against Base unavailable; Working Changes remain loaded and actionable. Provider diagnostics for unrelated branches do not block a usable current-branch parent.

Both refresh paths observe repository/common Git metadata, including config, config.worktree, Graphite refs/packed refs, and gh-stack files in linked-worktree administration. Relevant metadata events received during cooldown are deferred, not dropped. No Git query is introduced onto MainActor to configure watches. Configuration outside repository metadata is reread on explicit/other refresh; this change does not install broad home-directory watchers.

## Consequences

One precedence/conflict policy serves all supported sources and both consumers. Pure parent data remains independent of Workspace identity and native rendering. Forks now require plural dependent descriptions and separate connector lanes, but no arbitrary Git commit graph is introduced.

Partial diagnostics can coexist with valid groups. Missing branch refs may still describe a grouping relationship, whereas Against Base must resolve a commit before comparing. Metadata reads remain bounded, and unknown gh-stack schemas remain visibly unsupported. The format is still a public-preview compatibility boundary documented in DEVELOPMENT.

## References

- `docs/adrs/0007-resolve-base-branch-from-recorded-stack-metadata.md`
- `docs/adrs/0008-read-local-gh-stack-metadata-for-workspace-grouping.md`
- `docs/proposals/stacked-workspaces-plan.md`
- `docs/SPEC.md`, Stack Groups and Base Branch and Against Base
