# Configurable empty Workspaces

## Status

- Lifecycle: Accepted
- Implementation: Implemented
- Last reviewed: 2026-08-07
- Stable-contract target: `docs/SPEC.md`

This proposal defines future behavior. `docs/SPEC.md` remains authoritative for
the shipped application until this proposal is implemented, verified, and
promoted.

## Summary

Argus will add a global preference that allows a Workspace to remain open after
its final Terminal Tab closes. When the preference is enabled, closing that tab
will close its Terminal Panels without asking to close the Workspace. The same
Workspace will remain selected with zero Top-level Tabs, and the center content
area will show a quiet empty state from which the user can create a new Terminal
Tab.

The preference will be disabled by default, preserving the current behavior for
existing users: attempting to close the final Terminal Tab asks whether to
close the Workspace. Worktree deletion choices remain available in that
confirmation when applicable.

Empty Workspaces will be valid durable state. When session restoration is
enabled, a Workspace saved with zero Terminal Panels will restore with zero
tabs instead of manufacturing a replacement Terminal Panel.

## Goals

- Let users close every terminal without losing the surrounding Workspace.
- Preserve the Workspace ID, Project membership, Workspace Root, worktree, and
  sidebar position while it has no tabs.
- Keep current final-terminal confirmation behavior as the default.
- Apply one predictable preference to Standalone, Main-checkout, and Worktree
  Workspaces.
- Make the zero-tab state actionable through the center content area, the
  existing tab-bar add menu, and Cmd+T.
- Restore an intentionally empty Workspace exactly after a normal application
  restart.
- Preserve existing snapshots and avoid a Session Snapshot schema reset.

## Non-goals

This proposal does not:

- change how a newly created Workspace starts; new Workspaces still begin with
  one Terminal Tab;
- change the explicit Close Workspace action in the left sidebar;
- change worktree deletion ownership or confirmation behavior;
- add a per-Workspace override;
- add a separate preference for each Workspace type;
- change what happens when the final remaining tab is a Browser, File, Git
  Preview, or Release Notes Tab;
- persist Browser, File, Git Preview, Release Notes, split layout, Active Tab,
  or Focused Pane state;
- add a sidebar badge or alternate icon for an empty Workspace;
- add automatic tab creation when an empty Workspace is selected; or
- add periodic Session Snapshot autosave.

## Terminology and model invariants

### Empty Workspace

For this proposal, an **Empty Workspace** is an existing Workspace with:

- an empty Top-level Tab order;
- an empty Panel registry;
- no Active Tab;
- no Focused Pane; and
- no live Terminal Surfaces.

The Workspace itself remains valid and retains:

- its Workspace ID;
- its Workspace type;
- its Project association;
- its Workspace Root;
- its Project Repository Root or worktree metadata when applicable;
- its display title;
- its left-sidebar order and selection; and
- its Files and Changes context.

This replaces the current terminology rule that uses “empty Workspace” to mean
a fresh Workspace containing one default Terminal Panel. A **fresh Workspace**
will continue to mean a newly created Workspace with one Terminal Tab.

### Optional Active Tab

A nonempty Workspace must continue to have one Active Tab and one Focused Pane
within a terminal split where applicable. An Empty Workspace has neither.
Existing optional model properties remain the representation of that state;
this proposal does not introduce placeholder Panel or Tab identities.

## Preference

### Public settings interface

`AppSettings` will expose:

```swift
@Published var keepWorkspaceOpenAfterLastTerminalCloses: Bool
```

The preference will use this `UserDefaults` key:

```text
Argus.settings.general.keepWorkspaceOpenAfterLastTerminalCloses
```

Its default value will be `false`. Missing stored values therefore preserve the
current application behavior. Both `true` and `false` must round-trip through
an isolated `UserDefaults` suite in tests.

The preference is global and takes effect immediately for all current and
future Workspaces. It is stored separately from the Session Snapshot.

### Settings UI

General Settings will add a native grouped section titled “Workspace
Lifecycle” containing:

- a Toggle labeled “Keep Workspace open after closing last Terminal Tab”; and
- secondary explanatory text: “Leaves the Workspace open with no tabs. New
  Workspaces still start with a Terminal Tab.”

The control must use the existing native `Form` and `Toggle` patterns. No
custom control, restart requirement, or Apply button is needed.

## Behavior

### Behavior matrix

| Event | Preference disabled | Preference enabled |
| --- | --- | --- |
| Close one Terminal Tab while another Top-level Tab remains | Close the requested tab | Close the requested tab |
| Close one Pane while another Pane remains in the same Terminal Tab | Close the Pane and collapse the split | Close the Pane and collapse the split |
| Close the sole remaining Terminal Tab through tab close or Cmd+W | Show the existing Workspace-close confirmation | Close the Terminal Tab and retain an Empty Workspace |
| Close a sole split Terminal Tab through its tab close action | Show the existing Workspace-close confirmation before closing any Pane | Close every Pane in the tab and retain an Empty Workspace |
| Final Terminal Surface closes itself | Preserve current behavior and remove the resulting empty Workspace | Retain the resulting Empty Workspace |
| Close the final nonterminal tab | Preserve current behavior | Preserve current behavior |
| Explicitly choose Close Workspace | Preserve current behavior | Preserve current behavior |
| Explicitly choose Delete Worktree and Close | Preserve current behavior | Preserve current behavior |

The setting governs only the transition caused by closing the final Terminal
Tab or its final Terminal Surface. It does not turn every Workspace-close path
into Workspace retention.

### User-requested final Terminal Tab closure

The central tab-close router must determine whether the requested Top-level Tab:

1. belongs to the supplied Workspace;
2. is the Workspace’s sole remaining Top-level Tab; and
3. contains Terminal Panels.

When all three conditions are true:

- if the preference is disabled, post the existing
  `showCloseWorkspaceConfirmation` notification and make no model changes;
- if the preference is enabled, do not post the confirmation and continue
  through normal tab cleanup and closure.

Normal cleanup includes:

- removing Turn Completion Attention for the Top-level Tab;
- removing Agent Status Entries for each Terminal Surface in its split layout;
- closing every Terminal Panel in the tab;
- clearing tab layout and terminal custom-title state; and
- leaving `activePanelId` and `activeTabId` as `nil`.

After the close, the generic “empty Workspace is equivalent to a closed
Workspace” fallback must not remove this Workspace when retention was selected
by the preference. The Selected Workspace ID must remain unchanged.

When the preference is disabled, the existing confirmation remains
authoritative:

- Cancel or Keep Terminal changes no model or runtime state;
- Close Workspace removes the Workspace without deleting its worktree;
- Delete Worktree and Close first removes the eligible worktree and only then
  removes the Workspace; and
- failure to remove a worktree leaves the Workspace open and surfaces the
  existing error.

### Terminal Surface closure

Ghostty can report a Terminal Surface closure independently of an explicit tab
close request. This path cannot keep a Terminal Panel alive because the
underlying surface has already closed.

The surface-close handler must continue to:

- resolve the owning Workspace and Top-level Tab;
- migrate or remove Turn Completion Attention as required by split collapse;
- remove the surface’s Agent Status Entry; and
- close the corresponding Pane or Top-level Tab.

If this leaves the Workspace empty:

- remove the Workspace when the preference is disabled, preserving current
  behavior; or
- retain the same Workspace when the preference is enabled.

This ensures that users who enable retention get the same result whether they
close a tab through Argus or exit the shell running in the final terminal.

### Split panes

The existing Pane-first Cmd+W behavior remains unchanged:

- with multiple Panes, Cmd+W closes only the Focused Pane;
- after collapse, a surviving Pane becomes focused;
- the preference is not consulted until closing the only remaining Pane would
  close the sole remaining Terminal Tab.

Closing a split Terminal Tab from its tab close control operates on the
complete split tree. The setting is evaluated before any Pane is closed so the
disabled preference can still cancel without changing the tab.

### Other tab types

The preference does not change final nonterminal-tab behavior. In particular,
closing a final Browser, File, Git Preview, or Release Notes Tab continues
through the current generic tab-close lifecycle.

This boundary keeps the setting aligned with the current final-Terminal
confirmation and avoids broadening this proposal into a redesign of all
Workspace-close semantics.

### Explicit Workspace closure

An Empty Workspace remains removable through the left-sidebar Close Workspace
action. Worktree Workspaces continue to offer Close Only and Delete Worktree
and Close according to the existing ownership checks.

If the user explicitly closes the last remaining Workspace, Argus continues to
create and select a fresh Standalone Workspace containing one Terminal Tab.
The new preference must not create an application state with zero Workspaces.

## Empty center content

The Selected Workspace remains the center content owner while it has no tabs.
The normal Workspace chrome remains visible:

- Center Content Area Titlebar;
- empty Top-level Tab bar;
- tab-bar add menu; and
- Right Sidebar context.

The tab content region will show an empty state containing:

- the existing restrained terminal symbol treatment;
- the title “No tabs open”; and
- a native button labeled “New Terminal Tab”.

The button must call the existing terminal-tab creation path rather than
duplicating Terminal Panel construction. The resulting Terminal Tab must:

- use the Empty Workspace’s Workspace Root as its initial Terminal Working
  Directory;
- be appended to the Top-level Tab order;
- become the Active Tab;
- become the Focused Pane; and
- use the normal terminal focus lifecycle.

The existing tab-bar “+” menu and Cmd+T command remain available and must
produce the same result. New Browser Tabs and content opened from the Right
Sidebar must also continue to work when no Active Tab exists; insertion falls
back to appending because there is no active insertion point.

The empty state must not:

- create a Panel merely by rendering;
- hide or disable the Right Sidebar;
- change Workspace selection;
- display a destructive action; or
- open another window or sheet.

## Session persistence

### Snapshot representation

The existing `WorkspaceSnapshot.panelCount` field will represent the number of
Terminal Panels to reconstruct and may be zero. No new field is required.

For a Workspace with no persisted Terminal Panels:

```json
{
  "panelCount": 0,
  "terminalDirectories": [],
  "terminalCustomTitles": []
}
```

The remainder of the Workspace metadata remains unchanged.

### Snapshot creation

Creating a snapshot must collect actual Terminal Panels without inserting a
synthetic Workspace Root entry when none exist.

- A Workspace with Terminal Panels persists their current Terminal Working
  Directories and terminal custom titles as today.
- An Empty Workspace persists `panelCount: 0` and empty terminal arrays.
- A Workspace containing only runtime-only nonterminal Panels also persists
  zero Terminal Panels and therefore restores empty.

Normal application termination remains the required save boundary. This
proposal does not add an immediate checkpoint for tab closure or periodic
autosave.

### Snapshot decoding and restoration

Snapshot normalization must accept zero as a valid count:

- `panelCount == 0` produces no restored Terminal Working Directories and no
  restored terminal custom titles;
- a positive `panelCount` keeps the existing behavior of sanitizing stored
  paths, truncating excess entries, and filling missing entries with the
  Workspace Root;
- missing terminal arrays in an existing positive-count snapshot continue to
  restore through the legacy fallback;
- negative counts must not create Panels and should normalize to zero rather
  than indexing an invalid collection.

Workspace restoration must not index the first restored Terminal Working
Directory unconditionally. It must create zero or more Terminal Panels by
iterating over the normalized restored directories. With zero entries, the
Workspace remains valid with empty Panel collections and nil active state.

### Schema compatibility

The Session Snapshot schema version remains unchanged because:

- no serialized field is added, removed, or renamed;
- all existing positive-count snapshots keep their current meaning;
- newly written zero-count snapshots are valid JSON values for the existing
  integer field; and
- resetting every existing user session would be disproportionate.

An older Argus binary may create one Terminal Panel if it reads a zero-count
snapshot because the old implementation enforces a minimum of one. That
downgrade behavior does not corrupt Workspace identity or metadata and is
acceptable.

## Implementation plan

### 1. Add and expose the preference

Update the settings model to:

- add the new `UserDefaults` key;
- publish the Boolean property;
- load it with a `false` fallback;
- persist changes from `didSet`; and
- include it in canonical-value persistence.

Add the General Settings section and explanatory copy. Extend the existing
settings tests rather than introducing a new settings subsystem.

### 2. Make zero tabs a supported Workspace state

Update Workspace documentation and any assumptions that say a Workspace always
has exactly one active Panel. Preserve the existing optional active identifiers
and existing no-op guards for navigation when there are no tabs.

Do not add a placeholder Panel, hidden terminal, sentinel UUID, or special
Empty Panel type. A genuinely empty Panel order and registry are the source of
truth.

Verify that these existing operations remain safe with empty collections:

- Active Tab and layout lookup;
- previous/next tab selection;
- focus and unfocus;
- tab insertion after the Active Tab;
- opening File, Browser, Git Preview, or Release Notes Tabs;
- sidebar row presentation; and
- Workspace and window title formatting.

### 3. Route final-terminal closure through the preference

Update the explicit tab-close route before it posts confirmation. Keep one
computed fact describing whether the request closes the final Terminal Tab and
use it both for the preference decision and the post-close Workspace-removal
decision.

Update the Terminal Surface close handler to use the same preference when its
cleanup leaves the Workspace empty.

Keep runtime cleanup in the manager-owned close routes so views do not own
Agent Status or Turn Completion Attention lifecycle.

### 4. Restore zero Terminal Panels

Adjust snapshot construction, normalization, and Workspace restoration to
support zero without changing the wire shape or schema version.

Retain all existing positive-count and legacy missing-array behaviors. Add
focused zero-count cases alongside the current terminal-directory snapshot
tests.

### 5. Add the actionable empty state

Render the empty state inside the Selected Workspace content view only when
`panelOrder` is empty. Keep the normal titlebar and tab bar outside the
conditional so the Workspace retains its usual chrome.

Use the shared terminal creation method for the button, tab-bar menu, and
keyboard command behavior. Do not introduce a new terminal factory in the
view.

### 6. Promote documentation with implementation

When implementation starts, update:

- `docs/SPEC.md` Settings, Workspaces, Panels/tabs/panes, and Session
  persistence rules;
- `CONTEXT.md` Empty Workspace terminology and Active Tab relationships; and
- `docs/UI_DESIGN_PRINCIPLES.md` tab invariants, configurable final-terminal
  confirmation, and actionable zero-tab empty state.

After code and verification are complete:

- set this proposal’s Implementation field to `Implemented`;
- promote the behavior into `docs/SPEC.md`; and
- retain this proposal only if its rationale remains useful.

No ADR is required because this changes product behavior and an existing
snapshot value range without introducing a cross-cutting architectural
boundary.

## Test plan

### Settings tests

Extend `Tests/SettingsTests/AppSettingsTests.swift` to verify:

- the preference defaults to `false`;
- setting it to `true` persists across a new `AppSettings` instance;
- setting it back to `false` also persists; and
- initialization writes the canonical Boolean to the expected key.

Add a source-contract assertion that General Settings exposes the intended
native Toggle and binding.

### Workspace close tests

Extend `Tests/WorkspaceTests/WorkspaceTabNavigationTests.swift` to cover:

1. **Default behavior**
   - the setting is disabled;
   - closing the sole Terminal Tab posts one Workspace-close confirmation;
   - the notification identifies the Workspace and final-terminal origin;
   - the Workspace, Terminal Panel, Active Tab, and selection remain unchanged.

2. **Retention behavior**
   - enable the preference;
   - close the sole Terminal Tab;
   - verify no Workspace-close confirmation is posted;
   - verify the same Workspace ID and Project membership remain;
   - verify `panelOrder`, `panels`, and terminal layout/title state are empty;
   - verify `activePanelId` and `activeTabId` are nil; and
   - verify the Workspace remains selected.

3. **Reopening from empty**
   - add a Terminal Tab to the retained Workspace;
   - verify its Terminal Working Directory is the Workspace Root;
   - verify it becomes the Active Tab and Focused Pane; and
   - verify no new Workspace was created.

4. **Other tabs remain**
   - close a Terminal Tab while a Browser or File Tab remains;
   - verify the preference does not alter ordinary tab closure or selection.

5. **Split behavior**
   - close one Pane and verify the split collapses without consulting the
     preference;
   - attempt to close the final Terminal Tab with the preference disabled and
     verify the entire split remains intact after cancellation; and
   - close the final split tab with retention enabled and verify every Pane is
     closed while the Workspace remains.

6. **Terminal Surface closure**
   - deliver the normal surface-close Foundation Notification;
   - verify disabled behavior removes the resulting empty Workspace as today;
   - verify enabled behavior retains it; and
   - verify Agent Status and Turn Completion Attention cleanup still occurs.

7. **Explicit Workspace closure**
   - start from an Empty Workspace with retention enabled;
   - close it explicitly;
   - verify it is removed normally; and
   - when it was the last Workspace, verify a fresh Standalone Workspace with
     one Terminal Tab is created.

### Session tests

Extend the Session Snapshot tests to cover:

- encoding and decoding `panelCount: 0` with empty terminal arrays;
- `restoredTerminalDirectories` and `restoredTerminalCustomTitles` returning
  empty arrays for zero;
- restoring a zero-count snapshot into a Workspace with no Panels or active
  identifiers;
- creating a snapshot from an Empty Workspace without a synthetic directory;
- normal save and relaunch restoration preserving the same empty Workspace;
- a Browser-only runtime Workspace restoring empty because Browser Panels are
  not persisted;
- existing positive-count snapshots restoring the same number, directories,
  and custom titles;
- legacy snapshots without terminal arrays retaining their current fallback;
  and
- negative or inconsistent counts failing safely without array indexing.

### UI contract tests

Extend the Workspace UI contract tests to assert that:

- the Selected Workspace content branches on an empty `panelOrder`;
- the titlebar and tab bar remain mounted outside the empty-state branch;
- the visible copy is “No tabs open” and “New Terminal Tab”;
- the button uses the existing terminal creation path; and
- no independent window, sheet, or placeholder Panel is introduced.

### Validation

Run:

```sh
./scripts/test.sh
```

The complete validation must pass formatting checks, SwiftLint, the macOS
`ArgusTests` target, the Companion CLI build, and CLI smoke tests.

Perform manual application checks in both light-derived and dark-derived
Ghostty chrome palettes:

1. Toggle retention on and off without restarting.
2. Close the last Terminal Tab through its close button and Cmd+W.
3. Close the last Terminal Surface by exiting the shell.
4. Repeat in Standalone, Main-checkout, and Worktree Workspaces.
5. Confirm worktree deletion remains available only through explicit Workspace
   closure when retention is enabled.
6. Create a terminal from the empty-state button, tab-bar add menu, and Cmd+T.
7. Verify terminal focus and the initial Terminal Working Directory.
8. Quit normally, relaunch, and confirm the empty Workspace restores empty.
9. Confirm the Files and Changes Right-sidebar Views still use the retained
   Workspace’s normal roots.
10. Close an Empty Workspace explicitly and confirm last-Workspace replacement
    still creates one fresh Terminal Tab.

## Acceptance criteria

Implementation is complete only when all of the following are true:

- Existing users retain the current final-Terminal confirmation by default.
- A user can enable one global preference without restarting Argus.
- With the preference enabled, closing the final Terminal Tab never asks to
  close the Workspace and never removes it.
- The retained Workspace has the same identity, Project association, root,
  worktree metadata, title, sidebar position, and selection.
- The retained Workspace has no Panels, Top-level Tabs, Active Tab, Focused
  Pane, or Terminal Surfaces.
- The center content area clearly offers creation of a new Terminal Tab while
  the existing add menu and Cmd+T continue to work.
- New Terminal Tabs created from empty use the Workspace Root and receive
  normal focus.
- Empty Workspaces restore empty through the current Session Snapshot schema.
- Existing positive-count and legacy snapshots continue to restore correctly.
- Explicit Workspace and worktree deletion behavior remains unchanged.
- Stable documentation is updated as part of implementation promotion.
- The complete automated validation suite passes.
