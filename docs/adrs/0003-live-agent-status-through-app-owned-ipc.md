# ADR 0003: Live Agent Status through app-owned IPC

- Status: Accepted
- Date: 2026-08-06

## Context

Argus already owns ephemeral Agent Status Entries and renders them in the
Workspace sidebar and Top-level Tab bar. An external Agent Integration runs in
the shell process, so it cannot update the in-process `AgentStatusStore`
directly. Pi exposes public lifecycle events that can translate its current
activity into Argus states.

## Decision

The existing app-owned Unix Domain Socket Server accepts two additional,
agent-neutral methods:

- `agent.statusChanged`, which sets an Agent Status Entry;
- `agent.statusCleared`, which removes the exact entry reported by one session
  and scope.

Status requests use the existing version-one bounded newline-delimited JSON
transport. They identify an Agent Key, Workspace ID, optional Terminal Surface
ID, reporting session ID, and positive sequence number. Argus validates current
Workspace and Terminal Surface ownership on the MainActor. Duplicate or older
updates from one reporting session are acknowledged without changing state.

The Pi integration is an Argus-owned public Pi extension installed explicitly
from Settings under the effective `PI_CODING_AGENT_DIR`. It maps
`agent_start` to running, `agent_settled` to idle or error, and
`session_shutdown` to status-cleared. It reports idle while waiting for the
next prompt because Pi has no generic public `needsInput` lifecycle event.
Delivery failures are silent and must not change Pi behavior.

Agent Status Entries, ordering state, and socket connections remain ephemeral.
Argus does not track agent PIDs or run a background stale-process sweeper.

## Consequences

- Pi and future integrations can use one semantic status protocol without
  adding agent-specific lifecycle fields to Argus.
- The existing Agent Status UI requires no agent-specific rendering changes.
- A process that exits abnormally may leave no clear request; the status store
  remains runtime-only and is cleared when the Terminal Surface or Workspace
  closes.
- Session IDs and sequence numbers prevent normal duplicate, retry, and
  out-of-order delivery from regressing a status.
- Installing or removing Pi support is user-controlled and does not modify
  unrelated Pi resources.

## References

- `docs/SPEC.md`
- `CONTEXT.md`
- `docs/adrs/0002-agent-turn-completion-through-app-owned-ipc.md`
- `Argus/Services/AgentSocketServer.swift`
- `Argus/Services/AgentStatusRuntime.swift`
- `Argus/Resources/ArgusPiAgentStatusPlugin.js`
