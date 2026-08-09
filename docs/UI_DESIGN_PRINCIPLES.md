# Argus UI design principles

## Status

This document is the target UI behavior contract for Argus. It is derived from
the application spec and recent workspace, Files, Changes, diff, and tab work.
Recent code supplies evidence for these rules, but not every existing view is
fully compliant.

The words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" are normative.
The application spec remains authoritative for product behavior. This document
governs how that behavior is presented and how users interact with it. If the
two conflict, resolve the conflict in the spec and this document rather than
adding a local exception.

New UI and materially changed UI MUST follow this contract. Existing code may
not yet satisfy every rule; that is implementation debt, not precedent for
another exception.

## Product posture

Argus is a dense, native macOS work tool. It SHOULD feel familiar to users of
terminal applications, editors, and source-control clients. The interface
exists to keep work moving, not to call attention to itself.

Three ideas take priority:

1. Keep work in its workspace.
2. Make every interaction legible before the user clicks.
3. Preserve context and layout while state changes.

Use system typography, SF Symbols, native controls, standard keyboard behavior,
and macOS materials unless a custom control materially improves the workspace.
Custom chrome SHOULD still behave like a macOS control.

## Surface model

Choose a surface based on the user's task, not implementation convenience.

| Surface | Purpose | Examples |
| --- | --- | --- |
| Center workspace tab | Content the user reads, operates on, or returns to | Terminal, browser, file, diff, blame |
| Left sidebar | Project and workspace navigation | Projects, workspaces, active workspace |
| Right sidebar | Contextual navigation, status, and compact actions | Files, Changes, git operations |
| Native Settings | Global application configuration | General, Appearance, Terminal, Files & Changes, Browser |
| Sheet | Short, bounded workflow requiring completion or cancellation | Create, rename, adopt |
| Alert | Confirmation or blocking failure requiring a decision | Delete, discard, remove worktree |
| Context menu | Secondary operations on a resource | Open, copy, rename, delete |

Argus is a single-window application. Inspectable content MUST NOT open an
additional independent `NSWindow`, `NSPanel`, or utility window. Attached
sheets, alerts, menus, and popovers remain valid for the transient workflows in
the table above. An additional content window is allowed only if the application
spec explicitly introduces a multi-window workflow.

Native Settings is application configuration, not inspectable content. It MAY
use the standard macOS Settings surface and MUST NOT be presented as a Workspace
tab.

## Settings controls

Settings MUST use native `Form`, `Picker`, `Toggle`, and `Stepper` patterns
where those controls express the setting. Settings controls MUST retain native
keyboard and accessibility behavior rather than recreating form controls as
custom chrome.

Files & Changes Settings MUST put common Files preferences first and group
repository presentation under a labeled Changes section. Supporting text MUST
stay visually attached to the setting it explains instead of occupying
detached form rows.

Appearance and density settings MUST preserve the fixed opaque black application
shell. They MUST NOT reduce required hit targets, divider drag targets, or other
accessibility geometry below this contract's minimums.

## Keep content in workspace tabs

Files, diffs, blame output, browser pages, and similar content MUST open in the
center column as tabs in the workspace that initiated the action.

Content tabs MUST use the normal workspace tab lifecycle:

- Insert a new tab immediately after the active top-level tab and select it.
- Use the shared tab bar for selection, reordering, and closing.
- Use the normal close command and adjacent-tab selection behavior.
- Keep content-specific controls inside the tab content header.
- Do not add a second close button inside the content view.

Opening a resource that is already open in the same workspace SHOULD select the
existing tab rather than create a duplicate. Mutable previews, such as diffs and
blame, SHOULD refresh the existing tab in place. Identity SHOULD include
workspace, repository root, content kind, and resource path. Different content
kinds, such as diff and blame for one file, remain distinct tabs.

Tab reuse is workspace-scoped. The same resource MAY be open in separate
workspaces because each workspace carries independent task context.

If loading finishes after the user has switched workspaces, the result MUST
remain attached to the workspace that initiated it. Completion MUST NOT switch
the selected workspace, raise another window, or steal keyboard focus. If the
originating workspace no longer exists, discard the result.

Sidebars remain available while a content tab is open. Opening content MUST NOT
replace or hide the navigator that opened it.

Persistence for every panel type MUST follow the application spec. Adding a new
content type requires an explicit persistence decision and corresponding tests.

## Tabs and split panes

A top-level tab MAY own a split tree of terminal panes. The tab remains the unit
shown, reordered, and closed in the tab bar; a pane remains the unit focused for
keyboard input.

- A nonempty Workspace MUST have exactly one active top-level tab and one pane within its split tree. An Empty Workspace has neither.
- Split commands operate on the focused terminal pane and MUST NOT create
  another top-level tab.
- A new split SHOULD inherit the focused pane's working directory and become
  focused.
- Closing a focused pane in a multi-pane tab MUST close only that pane, collapse
  the remaining layout, and focus a surviving pane.
- Closing the only pane MUST use the normal top-level tab lifecycle.
- Closing the last terminal top-level tab MUST confirm Workspace closure when
  the keep-open preference is disabled. The safe cancel action MUST leave that
  Terminal Panel active and unchanged. When the preference is enabled, closing
  that tab removes its complete split tree and leaves an Empty Workspace.
- Reordering a top-level tab MUST move its complete split tree.
- Split dividers MUST provide an enlarged drag target and resize cursor.

File, diff, blame, and browser content SHOULD open as top-level tabs unless the
application spec defines split support for that content type.

## Make interactions legible

Every enabled custom clickable surface MUST provide all of these affordances:

- A hit area matching the visible row or control, normally via
  `contentShape(Rectangle())`.
- Visible hover feedback.
- A pointing-hand cursor through `.cursor(.pointingHand)` or a shared equivalent.
- A tooltip naming the action when the visible content does not name it.
- An accessible label when the visible content does not name the action.

This rule applies to rows, tabs, disclosure controls, icon buttons, segmented
chrome controls, and hover-revealed actions. Every enabled icon-only control MUST
provide the full set of affordances above, whether implemented as a SwiftUI
`Button`, an AppKit control, or a custom clickable surface. Icon-only standard
buttons are not exempt. Native text fields, pickers, menus, and standard buttons
whose visible text names the action MAY retain native cursor behavior. Disabled
controls MUST look disabled, reject input, and MUST NOT show a pointing-hand
cursor.

Use specialized cursors where the operation has a stronger established
meaning:

- Resize cursors for draggable dividers and resize handles.
- I-beam cursors for selectable or editable text.
- Ghostty-provided cursor state inside terminal surfaces.
- Drag or grab cursors where direct manipulation requires them.

Do not make users infer clickability from an icon alone. Icon-only controls MUST
have a tooltip and accessibility label. Use SF Symbols with consistent weight
and scale throughout application chrome.

## Hover, selection, and progressive disclosure

Hover is transient. Selection and active state are persistent. Their treatments
MUST be visually distinct, and selected or active state MUST remain stronger
than hover.

Use these treatments consistently:

- Clickable rows receive a subtle full-row hover fill.
- Compact icon actions receive a local rounded hover fill.
- Active tabs and selected rows retain a visible fill when the pointer leaves.
- Hover MUST NOT obscure the selected state.

Secondary actions MAY appear on hover to keep dense lists readable. Hover
disclosure MUST NOT move labels, resize rows, or change neighboring layout.
Reserve the action area and crossfade or overlay the alternate content. Git file
rows, where diff statistics give way to actions in the same trailing region,
are the reference pattern.

Controls hidden by hover state MUST also be removed from hit testing and the
accessibility tree. Hover MUST NOT be the only way to perform an operation.
Provide the same operation through keyboard focus, an accessibility action, a
context menu, or another persistent control.

## Hit areas and density

Argus favors compact desktop density, but visible size and hit size are
different concerns.

- A clickable row MUST use the full available row width as its hit area.
- Compact icon actions SHOULD provide at least a 20 by 20 point hit area.
- A one-point divider MUST provide an invisible drag target at least 6 points
  wide. The current 12-point divider target is preferred.
- Increasing hit area MUST NOT add visible padding that breaks established row
  density.

Application chrome SHOULD use plain button styling with explicit hover and
selection treatment. Forms and sheets SHOULD use native fields, segmented
pickers, default actions, and cancel actions rather than recreating them.

## Stable layout and restrained motion

Interaction feedback MUST NOT cause content to jump. Reserve space for loading
indicators, badges, hover actions, and controls whose state changes frequently.

Refreshes SHOULD keep already loaded content visible. Show a compact progress
indicator in reserved chrome while new data loads. Replace the whole view with a
loading state only when no useful content is available yet or when the context
has changed completely.

Motion communicates state only. Use short transitions, typically around 150 to
250 milliseconds, for disclosure, selection, and appearance changes. Avoid
decorative motion, bounce, and page-load choreography. Resizing and direct
manipulation MUST track the pointer without animation.

## Sidebar hierarchy

Sidebars are navigators, not alternate content areas. They SHOULD stay compact,
use full-width rows, and put directories before files at each tree level.
Disclosure state belongs to the tree row; opening content belongs to a tab.

The Changes View MUST render the ordered typed Change Sections in the active
Git Status Snapshot. With both Changes View settings disabled, it MUST preserve
the Staged, Unstaged, and Untracked sections and their existing layout. When
combination is enabled, it MUST render one Uncommitted section; when Against
Base is enabled, it MUST append the read-only Against Base section after all
Working Changes sections. Working sections MUST always precede Against Base.

Each available section shows its entry count and exposes only operations valid
for its typed kind. Empty available sections remain visible and collapsible. An
unavailable Against Base section remains visible while enabled, shows a concise
branch/error message, and exposes no rows or operations. Section actions,
expansion, directory IDs, row IDs, counts, and accessibility values MUST be
driven by typed section and Git File Change data rather than localized titles.

The branch summary SHOULD show aggregate file, addition, deletion, and upstream
information without consuming another content row. Its total and the Changes
badge MUST use active section entries, including entries that occur in both
Working Changes and Against Base as separate comparison contexts.

Long directory chains MAY be compacted when the intermediate directories add no
choice. Compaction MUST preserve the full path in help and accessibility text.
Expansion controls MUST state whether they expand or collapse and whether they
affect one directory, one section, or all sections.

Large trees MUST remain bounded according to the application spec or service
limit. When rows are omitted, the sidebar MUST disclose that the result is
truncated and show the total count when known. The Changes View MUST apply the
global 500-entry cap in visible section order while retaining uncapped section
counts and Section Operation scope. Its truncation copy MUST describe omitted
change entries rather than implying that every entry is a unique file.

Changing either Changes View setting is a presentation refresh, not navigation.
It MUST preserve the Selected Workspace, Active Tab, Focused Pane, Right
Sidebar selection, existing Git Preview Tabs, scroll position, and expansion
state. Expand/collapse-all MUST affect only currently present, available
sections, and expansion state MUST remain independent for each typed section
kind when settings are toggled.

## Selection, activation, and focus

Selection and activation are separate where users may act on a resource before
opening it. File trees are the reference behavior: a single click selects, a
double click or explicit Open action opens a file tab, and a directory click
selects and toggles disclosure.

Selecting a workspace tab MUST run the shared focus lifecycle. Terminal tabs
MUST restore terminal focus. Background tabs and asynchronous work MUST NOT
steal first responder status.

Common actions MUST have standard menu commands and keyboard shortcuts. This
includes creating a workspace or tab, closing the active pane or tab, splitting
a terminal, toggling sidebars, and selecting numbered workspaces. Custom
gesture-backed rows MUST expose equivalent button or accessibility semantics so
keyboard and VoiceOver users can activate them.

Drag-and-drop reordering SHOULD preserve the same selection and focus state as
click-based reordering. Reordering MUST NOT create or destroy resources.

## Destructive actions

Any action that can permanently remove user data, uncommitted work, a worktree,
or a project MUST require explicit confirmation. This applies to both one-item
and bulk operations.

Confirmation UI MUST:

- Name the operation and affected resource.
- State the irreversible effect in plain language.
- Show the accurate affected count for bulk actions.
- Provide a safe Cancel action.
- Mark the destructive action with the native destructive role where available.

Non-destructive, reversible source-control actions such as stage and unstage
SHOULD execute directly and refresh status afterward.

Destructive actions SHOULD NOT dominate idle UI. They belong in hover actions,
context menus, or explicit confirmation flows, with semantic color used for the
decision rather than decoration.

## Loading, empty, error, and disabled states

Every asynchronous surface MUST define initial loading, refresh, empty, error,
and loaded states.

- Initial loading uses a compact progress indicator and a short, specific label.
- Refresh keeps existing content visible and uses reserved indicator space.
- Controls that would start a duplicate operation MUST be disabled while that
  operation is running.
- Empty states state what is empty and, when useful, give the next available
  action.
- An Empty Workspace keeps the Center Content Area Titlebar, Top-level Tab bar,
  and Right Sidebar available, and offers a native “New Terminal Tab” action
  in the content region. Rendering the state MUST NOT create a placeholder
  Panel or change Workspace selection.
- Error states include a concise title, useful detail, and a recovery action
  when recovery is possible.
- Bounded or truncated data sets disclose the limit and the total when known.

State changes MUST preserve scroll position, selection, expansion, and focus
unless the underlying workspace or resource changed. A refresh is not a
navigation event.

## Visual language

The application shell uses an opaque black background across the native window,
sidebars, Center Content Area Titlebar, and Top-level Tab bar. Terminal content
uses the opaque black Argus background override while retaining other active
Ghostty configuration and theme colors. Document content retains active Ghostty
theme colors. Use shared `ChromeColors` values rather than local fixed colors.
Separators use subtle adaptive one-point lines, and sidebars MUST NOT use
translucent materials.

Established geometry is the default:

- 44-point primary sidebar and titlebar headers.
- 30-point tab bars, branch bars, root bars, and content subheaders.
- Compact 10 to 14 point system type in chrome and trees.
- Monospaced type for paths, branches, counts, code, and terminal-oriented data.

Use semantic color for selection, status, additions, deletions, warning, error,
and success. Do not use color as the only signal. Pair it with text, an icon, or
an accessibility value.

Git file status MUST use the status-specific icon and color required by the
application spec. Its accessibility value MUST also name the status. A generic
colored dot is not sufficient.

Long paths and branch names SHOULD truncate in the middle. Human-readable names
SHOULD truncate at the end. Keep information hierarchy clear without adding
decorative cards, shadows, gradients, or extra containers.

## Content readability

File, diff, and blame content SHOULD use monospaced type, remain selectable, and
follow the active light or dark appearance. Loading and rendering failures MUST
stay inside the originating content tab rather than opening another window.

Diff-specific view controls belong in the content header. Split and unified
layout, and scroll and wrap overflow, SHOULD use compact native controls. Their
state is local to the content tab unless the product explicitly defines a
workspace-wide preference. Unsupported, binary, oversized, or failed previews
MUST show a recoverable in-tab message rather than blank content.

## Accessibility and help

Pointer polish is not a substitute for accessible interaction.

- Icon-only controls MUST have `.help` text and an accessibility label.
- Selection, expansion, disabled state, and operation status MUST be exposed to
  assistive technology.
- Status MUST NOT rely on color alone.
- Hover-revealed controls MUST have a non-hover path.
- Hidden controls MUST be both non-interactive and accessibility-hidden.
- Text content such as files, diffs, and blame output SHOULD remain selectable.
- Focus order SHOULD follow visual order and remain stable across refreshes.

## Copy and labels

Labels SHOULD describe the object or result directly. Action labels use a verb
and object when space permits, such as "Refresh changes", "Delete file", or
"New workspace". Avoid generic labels such as "OK" when the button can name the
action.

Tooltips use sentence-style action names. Confirmation copy names the affected
resource and consequence. Errors report what failed and preserve the underlying
error detail when it helps recovery.

## Enforcement

UI contract tests SHOULD protect behavior that can regress without a compiler
error. At minimum, tests for a new interaction pattern MUST cover applicable
items from this list:

- Correct surface placement, especially tab rather than window presentation.
- Resource identity, tab reuse, and refresh-in-place behavior.
- Hover feedback, pointing-hand cursor, full hit area, and stable geometry.
- Selection precedence over hover.
- Hidden-control hit testing and accessibility behavior.
- Destructive confirmation and bulk-operation scope.
- Workspace ownership and focus behavior for asynchronous completion.

Source-contract tests are useful for wiring, but they do not replace a manual
check of pointer, keyboard, VoiceOver, light appearance, and dark appearance.

When a feature needs a behavior that contradicts this document, update this
contract in the same change and explain why the exception should become a new
project-wide rule.

## Current reference implementations

These files contain the patterns from which this contract was derived:

- `Argus/Models/Workspace.swift`: tab insertion, reuse, selection, reordering,
  closing, and focus lifecycle.
- `Argus/Models/Panel.swift`: shared panel protocol and file and git-preview
  panel models.
- `Argus/Models/TerminalPanel.swift`: terminal panel lifecycle.
- `Argus/Views/Content/TabBarView.swift`: shared tab interaction and visual
  states.
- `Argus/Views/Content/ContentAreaView.swift`: central content routing and file
  content.
- `Argus/Views/GitSidebar/RightSidebarView.swift`: Files and Changes navigation,
  selection, context actions, and refresh behavior.
- `Argus/Views/GitSidebar/GitSidebarView.swift`: stable hover actions, compact
  git hierarchy, destructive operations, and preview opening.
- `Argus/Views/ChromeColors.swift`: adaptive content chrome, hover, active, and
  separator colors.
- `Argus/Views/Sidebar/SidebarDivider.swift`: enlarged invisible drag targets
  and resize cursors.
- `Tests/GitStatusTests/GitStatusUIContractTests.swift` and
  `Tests/WorkspaceTests/WorkspaceUIContractTests.swift`: executable UI wiring
  contracts.
