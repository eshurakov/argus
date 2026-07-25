# ADR 0002: Agent turn completion through app-owned IPC

- Status: Accepted
- Date: 2026-07-24

## Context

Argus needs to receive successful coding-agent turn completions without coupling application behavior to one agent's lifecycle schema. The first integration is Kilo, whose public TUI extension API can identify successful root turns and known synthetic or compaction-generated input but cannot prove human provenance for every ordinary user message. Installing the integration also requires editing user-owned JSON or JSONC configuration without losing comments or unrelated settings.

## Decision

The Argus Application owns a process-local Unix Domain Socket Server at `~/.argus/argus.sock`. Its first and only method is the agent-agnostic `agent.turnCompleted` request. The server validates bounded newline-delimited JSON, protocol version, current Workspace and Terminal Surface ownership, and process-lifetime event identity before updating runtime-only Turn Completion Attention.

Turn Completion Attention is separate from Agent Status and is stored at Top-level Tab scope. Views only present it; Workspace navigation and main-window key-state lifecycle acknowledge it.

Kilo translation remains in an Argus-owned public TUI plugin. The plugin filters Kilo lifecycle events and sends only the semantic Argus request. Settings explicitly installs or removes the plugin through locked, token-aware JSON/JSONC edits that preserve unrelated configuration. Argus owns only its plugin file and exact declaration.

## Consequences

- Future coding agents can emit the same semantic request without adding agent-specific fields to Argus.
- Socket input cannot create Workspace or Panel state, activate Argus, or change selection and focus.
- Attention remains ephemeral and independent of live Agent Status telemetry.
- Kilo delivery is conservative and may omit a completion when root-session state cannot be verified.
- Ordinary programmatic, non-synthetic Kilo user messages remain indistinguishable from interactive human prompts through current public APIs.
- The Companion CLI remains unrelated to this method and continues as a scaffold.

## References

- `docs/SPEC.md`
- `docs/proposals/turn-completed-notification/spec.md`
- `docs/UI_DESIGN_PRINCIPLES.md`
