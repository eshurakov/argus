# ADR 0004: Report successful Pi turn completion for workspace attention

- Status: Superseded by ADR 0010 (`0010-pi-main-agent-completion-with-delegated-work.md`)
- Date: 2026-08-08

## Context

Argus already uses the agent-agnostic `agent.turnCompleted` event to create
runtime-only Turn Completion Attention for an unviewed Top-level Tab and its
Workspace row. The Pi integration currently reports live Agent Status, so a
completed successful turn becomes the idle pause icon without identifying the
Workspace as needing attention.

## Decision

The Argus-owned Pi extension emits `agent.turnCompleted` after a successful
`agent_settled` lifecycle event, after it reports the idle Agent Status. It does
not emit completion for a settled turn with a final Agent error. The event uses
the same Workspace ID and Terminal Surface ID as the status updates and a
process-local, session-scoped event ID.

The existing Turn Completion runtime remains responsible for viewed-state
checks, visual attention, sound preferences, deduplication, and clearing
attention when the affected Top-level Tab is viewed.

## Consequences

- A successful Pi turn in an unviewed Top-level Tab replaces the idle pause icon
  with Turn Completion Attention and summarizes that attention in the Workspace
  row.
- A successful turn already viewed in the key Argus main window creates no
  attention.
- Error, interrupted, and session-start idle states do not create completion
  attention.
- Pi delivery failures remain silent and do not change Pi lifecycle behavior.

## References

- `docs/SPEC.md`
- `docs/adrs/0003-live-agent-status-through-app-owned-ipc.md`
- `Argus/Resources/ArgusPiAgentStatusPlugin.js`
- `Argus/Services/TurnCompletionAttentionStore.swift`
