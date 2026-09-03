# ADR 0011: Non-owning Project Collections

- Status: Accepted
- Date: 2026-09-02

## Context

Users need a single-level way to organize Named Projects without adding another
repository or content owner. Project identity, Workspace lifecycle, worktree
storage, and live Terminal resources already have owners. Sidebar grouping must
not change those boundaries or make Workspace shortcuts depend on disclosure.

## Decision

Store each Collection as one UUID-keyed record containing its name, ordered
Project IDs, and disclosure state. The ordered Collection array owns Collection
order. Do not add a second membership property to Project. Keep the existing
Project array as the registry and source of ungrouped Project order.

Project a single fully expanded order: ordered Collection members, ungrouped
Named Projects, then the Catch-all Project. Feed that order to the sidebar,
Workspace Number shortcuts, adjacent navigation, and selection after closure.
Stack projection remains within each Project. Stack and Pull Request Status
runtimes do not depend on Collection disclosure. Drag payloads use separate
Project and Collection types. Capture destination membership and order before
loading a payload asynchronously, then revalidate both source and destination
before applying it.

A Collection can be empty. Removal ungroups its members as an ordered block at
the end of Other Projects, without changing Project, Workspace, Panel, process,
or worktree lifecycle. Explicit selection reveals every ancestor; disclosure
alone does not select or acknowledge attention.

Persist Collection records as an additive optional Session Snapshot field, with
no schema-version change. Legacy snapshots restore without Collections. Bound
records and membership to 128 entries and names to 4096 UTF-8 bytes. Reconcile
stale, duplicate, and Catch-all membership, keeping the first valid occurrence.
Consume optional records and member IDs independently so malformed entries do
not discard valid siblings or the core session. A malformed top-level Collection
field restores as no Collections; core Project/Workspace validation is unchanged.
Synchronously checkpoint user Collection mutations using the existing atomic
Session Snapshot writer.

## Consequences

There is one membership authority and one navigation order. Moving a Project
changes only navigation state, and removing an organizer cannot destroy work.
Empty organizers make creation and removal usable without a separate staging
workflow. Existing snapshots remain readable; no migration or future Work Mode
persistence redesign is required.

The Project registry's order is not the complete navigation order when
Collections exist. Navigation consumers must use the shared projection rather
than iterate the registry directly. Collection disclosure and pending Stack
reveal must cooperate so a delayed discovery result cannot undo a user collapse.

## References

- `../SPEC.md`: Collections and Session persistence
- `../../CONTEXT.md`: Collection ownership and canonical terms
- `../UI_DESIGN_PRINCIPLES.md`: Sidebar hierarchy
