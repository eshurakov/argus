# Proposals

Proposals describe future changes and do not override `docs/SPEC.md` until their implementation is complete and the stable contract is updated.

Current proposals:

No current proposals.

Completed proposals:

- [Pull Request status for Worktree Workspaces](worktree-pull-request-status/spec.md) — design A and host-batched, quota-aware refresh implemented on 2026-08-30 and promoted into `docs/SPEC.md`; B and C remain design comparisons.
- [Pull Request Workspace creation](pull-request-workspace/spec.md) — implemented and promoted into the Projects and Workspaces and Git worktrees sections of `docs/SPEC.md`.

Use these lifecycle states:

- **Draft**: behavior is still being decided.
- **Accepted**: product behavior is agreed, but implementation has not started.
- **Implementing**: implementation is in progress.
- **Implemented**: code and verification are complete; the proposal must be promoted into the stable spec.
- **Superseded**: another document or decision replaced the proposal.

Each proposal should state its lifecycle status, last review date, implementation state, and promotion target. Once promoted, retain it only when its design rationale remains useful; otherwise Git history is enough.
