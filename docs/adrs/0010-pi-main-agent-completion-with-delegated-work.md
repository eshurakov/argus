# ADR 0010: Report Pi completion only from the main agent after delegated work

- Status: Accepted
- Date: 2026-09-01
- Supersedes: ADR 0004

## Context

The Pi extension reports Turn Completion Events at `agent_settled`. A child Pi
process can inherit both the extension and its parent's Argus Workspace ID and
Surface ID. Its completion then creates Turn Completion Attention while the
main agent is still working. Child Agent Status updates can also replace the
main agent's reporting session for that Terminal Surface.

Filtering child processes alone is insufficient. An interactive main agent can
settle while background subagents continue, then wake to consume their results.
Pi's settlement event describes that agent run, not all delegated work.

## Decision

The Argus-owned Pi extension does nothing in processes marked with
`PI_SUBAGENT_CHILD=1`. This marker belongs to the `pi-subagents` package; generic
Pi process markers, UI availability, and `PI_SUBAGENT_PARENT_SESSION` do not
identify children reliably.

The main extension listens for the public `subagents:rpc:v1:ready` advertisement.
At successful main-agent settlement, it requests `status` through the public
event bus and reads the version-one fleet's `totalActive`, including entries
omitted from its bounded display list. No package imports, filesystem scans,
model calls, or socket protocol changes are required.

If delegated work is active, Argus retains running Agent Status and receives no
Turn Completion Event. A later successful main-agent settlement with no active
work may report completion. Child completion itself never triggers it.

Once a package advertises its RPC, an unsupported API, invalid response, or
failed check cannot prove completion. Argus suppresses completion and leaves
the existing status unchanged. Requests time out after 1.5 seconds and remove
their listeners. A new turn or session shutdown cancels an outstanding check;
late results and queued completion deliveries must not outlive their turn.

Plain Pi sessions without an RPC advertisement keep lifecycle-based reporting.
Startup idle, duplicate settlement, final errors, and interrupted turns do not
create Turn Completion Attention. Integration installation remains explicit
through Settings, with exact historical extension digests accepted for upgrade.

## Consequences

- Subagents cannot create attention or take over main-agent status through the
  Argus extension.
- A main agent yielding to active delegated work does not announce completion.
- Pi remains usable without the `pi-subagents` package. Other launchers need
  their own explicit identity and work-status contract for equivalent filtering.
- If an advertised package cannot report status, completion may be missed
  rather than announced early. There is no polling or deferred child-driven
  notification; the next main-agent turn rechecks at settlement.
- Existing viewed-state checks, sound preferences, and attention clearing stay
  in the Argus Application.

## References

- `docs/SPEC.md`
- `docs/adrs/0004-pi-turn-completion-attention.md`
- `Argus/Resources/ArgusPiAgentStatusPlugin.js`
- `Tests/PiIntegrationTests/pi-plugin-events.mjs`
- Pi public extension lifecycle and event-bus API (`docs/extensions.md` in Pi)
- `pi-subagents` public event-bus RPC and fleet status (`docs/extension-api.md` in that package)
