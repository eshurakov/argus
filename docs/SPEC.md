# Argus application specification

## Status

Stable v1 baseline, updated 2026-08-14.

This document defines behavior implemented by the current Argus application. Future work belongs under `docs/proposals/` until it is implemented and incorporated here.

The words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" are normative.

## Product scope

Argus is a personal macOS terminal workspace manager built on Ghostty. It organizes terminal, browser, file, and Git preview content into Workspaces; groups repository-backed Workspaces into Projects; manages Git worktrees; shows Workspace files and Git changes; and restores durable session state.

Argus is a single-user, single-machine application. It has one main Workspace window and a separate native Settings surface. It does not provide a general external control API in v1; the local socket is limited to the agent integration events specified below.

## Application shell

1. The main window MUST use a three-column layout: the left sidebar, center Workspace content, and the Right Sidebar.
2. The main window MUST use a full-size transparent titlebar and an opaque application shell. Its shell and default Terminal backgrounds MUST be black while the window is key and dark grey (`#1A1A1A`) while it is not key. App-owned document backgrounds MUST follow the same focus treatment without recoloring foreground content, images, web pages, or semantic diff highlights.
3. The left sidebar and Right Sidebar MUST be independently toggleable and resizable.
4. Left-sidebar visibility and width MUST persist in `UserDefaults`. Its default width is 200 points, with an effective range from 80 points to one third of the window width.
5. Right-sidebar visibility, width, and selected Right-sidebar View MUST persist in `UserDefaults`. Its width range is 180 to 600 points and its default width is 250 points.
6. Dividers MUST provide a drag target wider than their visible separator.
7. Inspectable content MUST remain in the main Workspace window. Settings, sheets, alerts, menus, and popovers MAY use their normal macOS surfaces.
8. The main window MUST indicate keyboard/key-window focus through its background appearance, without a titlebar focus strip or perimeter outline. When it is not key, ordinary headers and toolbar controls SHOULD soften, and selection accents SHOULD become less prominent without hiding the Selected Workspace or Active Tab. Panel content, Agent Status, and Turn Completion Attention MUST remain undimmed. Focus appearance MUST NOT intercept input or affect layout. Increased Contrast MUST retain normal chrome opacity.

## Settings

1. Argus MUST provide a native macOS Settings surface for global application preferences.
2. Settings MUST be stored separately from the Session Snapshot.
3. General settings MUST include:
   - restore previous session;
   - default Right-sidebar View;
   - default directory for a new Standalone Workspace; and
   - whether to keep a Workspace open after its final Terminal Tab closes.
4. An explicitly supplied Standalone Workspace directory MUST take precedence over the configured default. The configured default MUST take precedence over the user's home directory.
5. Appearance settings MUST include interface text size, document text size, and compact or comfortable interface density.
6. Terminal settings MUST include the audible-bell preference. Ghostty configuration remains authoritative for terminal font, colors other than Argus's background override, and keybindings.
7. Files and Changes settings MUST include hidden Workspace Item visibility, initial source wrapping, initial Markdown and SVG display modes, initial diff layout, and these two global Changes View toggles:
   - **Combine working changes**;
   - **Show committed changes against Base Branch**.
   Both toggles MUST default to off, persist independently outside the Session Snapshot, and apply immediately. Combining Working Changes MUST alter only presentation and MUST NOT alter the index. Against Base MUST be additive, read-only, and computed from Git data already stored locally without contacting or updating a remote.
8. Browser settings MUST include homepage, search provider, page zoom, WebKit inspectability, and persistent or private website data storage.
9. Global defaults MUST apply when their target is created. They MUST NOT reset existing Panel-local state.
10. `.git` MUST remain excluded from the Files View even when hidden Workspace Items are visible.

Changing either Changes View toggle MUST refresh the Selected Workspace without
changing the Selected Workspace, Active Tab, Focused Pane, Right Sidebar
selection, or existing Git Preview Tabs.

## Projects and Workspaces

### Projects

1. A Project MUST have an immutable Project ID and a mutable display name.
2. A Named Project MUST identify one Git repository by its canonical Project Repository Root.
3. Project creation MUST reject a non-repository directory and a repository already represented by another Named Project.
4. Project creation MUST detect the main branch from, in order: the remote HEAD, local `main`, local `master`, or the current branch. The creation UI MAY accept an explicit main-branch override when detection fails.
5. Creating a Named Project MUST also create its Main-checkout Workspace.
6. A Project MUST keep an ordered list of child Workspace IDs and persist its display name, repository path, main branch, expansion state, and optional color.
7. Argus MUST maintain one non-removable Catch-all Project named "Workspaces" for Standalone Workspaces.
8. Removing a Named Project MUST remove its child Workspaces and attempt to remove their Managed Worktrees.
9. Named Projects MUST appear before the Catch-all Project in the left sidebar.

### Workspaces

1. A Workspace MUST have an immutable Workspace ID, one Workspace Root, and an ordered set of Top-level Tabs. A nonempty Workspace MUST have one Active Tab; an Empty Workspace has no Active Tab.
2. A Workspace MAY be a Standalone Workspace, Main-checkout Workspace, or Worktree Workspace.
3. A Standalone Workspace MAY use an ordinary directory with no Git repository.
4. New Workspaces MUST start with one Terminal Tab backed by one Terminal Panel.
5. Workspaces MUST support rename, close, selection, and reordering within a Project.
6. Closing the last Workspace MUST create and select a fresh Standalone Workspace containing one Terminal Tab.
7. Cmd+1 through Cmd+8 MUST select Workspaces by global left-sidebar order. Cmd+9 MUST select the last Workspace. The left sidebar MUST NOT reserve a permanent Workspace Number column. While Command is held, the sidebar MUST overlay the reachable shortcut digit on the Workspace row icon: 1–8 for the first eight Workspaces, and 9 only on the last Workspace when more than eight exist.
8. The left sidebar MUST show Project and Workspace hierarchy, selection, Workspace type, branch when available, Agent Status when present, and the number of Terminal Surfaces that still have a running process when that count is greater than zero. That count MUST use Ghostty's per-surface close-confirmation heuristic, MUST include split Panes, and MUST NOT show Top-level Tab count. The Selected Workspace row MUST be marked with a leading accent indicator and a restrained row fill, MUST keep normal sidebar foreground colors, and MUST NOT fill the complete row with the accent color.
9. A Standalone Workspace MUST allow its Workspace Root to be changed from its left-sidebar context menu.
10. The Workspace Root change workflow MUST support both directory browsing and direct path entry. An entered path MUST resolve to an existing directory.
11. Changing a Standalone Workspace's Workspace Root MUST immediately update its Files View and Git Status Root. New Terminal tabs MUST start at the new Workspace Root without changing existing Terminal Working Directories.
12. A Standalone Workspace row MUST show its Workspace Root beneath its display name, abbreviating the user's home directory with `~`.
13. When the keep-open preference is enabled, closing the final Terminal Tab MUST retain the same Workspace as an Empty Workspace with no Panels, Top-level Tabs, Active Tab, Focused Pane, or live Terminal Surfaces.
14. An Empty Workspace MUST remain selectable and retain its Workspace Root, Project membership, sidebar order, Files View, and Changes View context.
15. The existing per-Named-Project New Workspace sheet MUST support Pull Request intake as a third source alongside New Branch and Existing Branch. Pull Request intake MUST NOT be available from the top-level New Workspace command or the Catch-all Project.
16. Pull Request intake MUST accept a positive Pull Request number or an HTTPS GitHub Pull Request URL, use the active GitHub CLI context, and create or select a Worktree Workspace in the initiating Named Project.
17. A newly created Pull Request Worktree Workspace MUST use the Pull Request head branch as its local branch and derived title, and the Pull Request title as its custom title. Existing custom titles MUST be preserved when an exact Workspace is reused.

### Stack Groups

1. Named Projects MUST derive Stack Groups through the same Recorded Base Branch metadata reader used by Against Base. Sources MUST include effective `branch.<branch>.base` Git configuration, Graphite `parentBranchName` objects under `refs/branch-metadata/`, and schema-v1 `gh-stack` files in common and linked-worktree Git directories, including worktrees without open Workspaces. The Catch-all Project MUST remain unchanged.
2. A valid nonempty, non-self explicit configuration value MUST override tool records for its branch. Matching tool parents MUST coalesce, including consistent partial gh-stack chains and forks. Different tool parents or cyclic parent declarations MUST be diagnosed, and their ambiguous incoming edges MUST NOT be used. Unrelated valid relationships MUST remain usable. Missing/empty declarations mean no recorded parent; malformed, unreadable, or unsupported provider data MUST produce a nonmodal diagnostic rather than erase valid data from other sources.
3. Discovery MUST be offline and read-only. It MUST NOT invoke `gh stack view`, authenticate, fetch, mutate tracking, restack, merge, or install an extension. Cached commit hashes, branch-name conventions, and Git ancestry MUST NOT supply parent relationships. Displayed relationships describe local declarations, not live GitHub review, queue, or Pull Request target state.
4. A Stack Group MUST contain at least two open Workspaces whose canonical checkout paths and current Git branches bind unambiguously to one connected recorded-parent component. Discovery MUST NOT treat a Git administrative directory as an assumed Main-checkout Workspace; an unknown physical checkout location MUST remain unbound with a diagnostic. Metadata files and each metadata command's combined captured stdout/stderr MUST be limited to 1 MiB, and branch/parent declarations to 4096 UTF-8 bytes.
5. Groups MUST occupy their earliest member's existing manual position. Parents MUST precede dependents, and sibling subtrees MUST preserve existing manual order with a stable branch-name tie-breaker. Discovery MUST NOT rewrite durable manual order. Unparented configured Project main branches and unparented declared gh-stack trunks MUST separate independent groups; sharing such a trunk alone is not a group relationship. A trunk with its own recorded parent MUST participate in that explicit relationship, regardless of source containers.
6. Missing intermediate or shared parents MUST appear once as nonselectable branch references so connectors never fabricate a different parent or connect siblings as a chain. An immediately preceding missing parent MAY appear for context; unused trailing branches SHOULD be omitted. References and headers MUST NOT count as Workspaces or receive shortcut digits. Every real Workspace MUST occur exactly once in the navigation projection.
7. The sidebar, Cmd-number shortcuts, adjacent Workspace navigation, and selection after closing a Workspace MUST use the same fully expanded projection. Collapsing a Project or Stack Group MUST NOT renumber Workspaces. Explicit selection MUST reveal its Workspace, including same-ID reselection; a newly created checkout MAY retain that reveal intent until fresh inventory arrives, but later selection or disclosure MUST cancel it. Background refresh MUST NOT independently expand groups or change selection or focus, and unrelated metadata diagnostics MUST NOT block an otherwise valid reveal.
8. Stack Group headers MUST disclose without selecting or closing Workspaces and MUST show the real Workspace count. Collapsed Stack Groups and Projects MUST summarize hidden Selected Workspace and Turn Completion Attention without acknowledging it. Workspace rows MUST retain their existing selection, status/type icon, Command overlay, and running-process badge semantics.
9. Directional connectors MUST point from actual recorded parent to dependent using measured row geometry and distinct fork lanes, while member text retains a fixed inset within each group. Connectors MUST remain separate from status icons and noninteractive. Row help and accessibility MUST identify the recorded parent, all recorded direct dependents, and relevant conflicts, including dependents omitted from visible references. Stack relationships MUST remain in the grouped list without a separate Selected Workspace Stack footer. Unknown parents MUST NOT be labeled as inferred main. Compact layouts MUST preserve supported minimum-width action targets and process counts.
10. Dragging or moving a grouped Workspace MUST move its complete Stack Group as one sidebar block. Parent constraints MUST remain metadata-controlled. Same-block and cross-Project drops MUST be rejected. Closing a Workspace MUST retain its existing independent lifecycle; grouping MUST NOT introduce cascading closure or deletion.
11. Discovery MUST run independently of sidebar visibility, Selected Workspace, and Changes settings. It MUST use debounced FSEvents observation of repository/common and linked administrative metadata, including configuration and all supported parent sources, reread after installing a watch, coalesce in-flight requests, and discard obsolete or unowned results. Refresh MUST retain loaded content while pending. A Named Project MUST provide Refresh Stacks and a compact retryable diagnostic; configuration outside watched repository metadata is reread on explicit or other refresh.
12. Collapsed Stack Group keys MUST persist with Project state using backward-compatible defaults and no Session Snapshot schema change. Keys MUST be scoped by Project and recorded root/parent references, not source, titles, or positions; unchanged linear groups MUST retain compatible keys. Root-branch replacement or rename MAY reset disclosure. Discovered snapshots, loading/errors, pending reveal intent, and observers MUST remain runtime-only.

## Panels, tabs, and panes

1. V1 supports Terminal, Browser, File, Git Preview, and Release Notes Panels.
2. A Workspace MUST maintain a Panel registry and use root Panel IDs to order Top-level Tabs.
3. New Terminal tabs MUST be appended and selected.
4. New Browser, File, and Git Preview Tabs SHOULD be inserted after the Active Tab and selected.
5. Terminal tab labels MUST default to `Terminal N`. A user-supplied terminal title MUST override the ordinal label.
6. Top-level Tabs MUST support selection, drag-and-drop reordering, explicit move actions, and close actions.
7. Opening the same File Tab or Git Preview Tab in one Workspace SHOULD select and refresh the existing tab instead of creating a duplicate.
8. Tab reuse MUST be scoped to the initiating Workspace.
9. Cmd+[ and Cmd+] MUST select the previous and next Top-level Tab with wraparound.
10. Cmd+W MUST close the Focused Pane when a terminal split has multiple panes; otherwise it MUST close the Active Tab.
11. Closing a Terminal Pane or Terminal Tab MUST require confirmation when Ghostty reports that any affected Terminal Surface still has a running process. Cancel MUST leave the Pane, Tab, Workspace selection, and process unchanged. Confirmation MUST state that closing will terminate the running process.
12. Closing the final Terminal Tab MUST require Workspace-close confirmation before changing state when the keep-open preference is disabled. When that confirmation is shown, it MUST include any running-process consequence instead of presenting a second dialog. When the preference is enabled, it MUST close the complete Terminal Tab and retain an Empty Workspace after any required running-process confirmation.
13. Closing a Workspace that contains a Terminal Surface with a running process MUST require confirmation and MUST combine that consequence with any worktree-deletion choice rather than presenting a second dialog.
14. Closing a final Browser, File, Git Preview, or Release Notes Tab MUST retain the existing generic Workspace-close lifecycle regardless of the keep-open preference.
15. The empty content region of a Selected Empty Workspace MUST show the normal Workspace chrome, a restrained terminal symbol, “No tabs open”, and a native “New Terminal Tab” action. The action MUST use the normal Terminal Tab creation path and initialize the new Terminal Working Directory from the Workspace Root.

### Terminal splits

1. A terminal Top-level Tab MAY contain a recursive split tree of terminal Panes.
2. Exactly one Pane in the Active Tab MUST be focused for terminal input.
3. Cmd+D MUST split the Focused Pane vertically. Cmd+Shift+D MUST split it horizontally.
4. A new split SHOULD inherit the Focused Pane's Terminal Working Directory and become focused.
5. Closing a Pane in a multi-pane tab MUST collapse the remaining layout without closing the Top-level Tab.
6. Reordering or closing a Top-level Tab MUST operate on its complete split tree.

## Terminal runtime

1. Argus MUST use one process-wide Ghostty engine.
2. Each Terminal Panel MUST own one independent Terminal Surface.
3. Argus MUST load Ghostty default and recursive configuration before applying its bundled opaque-black terminal background override. Unfocused windows MUST use a cached configuration derived from that configuration with only the background changed to dark grey. Focus changes MUST NOT reload user files, recreate Terminal Surfaces, or restart processes.
4. Terminal surfaces MUST retain user Ghostty configuration except for the Argus-owned background and background-opacity values.
5. Spawned shells MUST receive `ARGUS_SOCKET_PATH`, `ARGUS_WORKSPACE_ID`, and `ARGUS_SURFACE_ID`.
6. These variables identify the application socket, Workspace, and Terminal Surface for supported integrations. Their presence MUST NOT be treated as proof that a particular Agent Integration is enabled.
7. Argus MUST set terminal-identifying environment values and prepend existing supported Homebrew binary directories to `PATH`.
8. Terminal title and working-directory callbacks MUST update their Terminal Panel state on the main thread.
9. Inactive terminal surfaces SHOULD remain mounted during Top-level Tab changes. They MUST be occluded and prevented from stealing focus or accessibility interaction.
10. Terminal Working Directory MUST remain distinct from Workspace Root and Git Status Root.
11. Cmd+V with an image-only system clipboard MUST reach the running terminal program as Ctrl+V. Text-capable clipboard contents MUST retain Ghostty's normal paste behavior.
12. That Ctrl+V MUST be delivered as a key event so it is encoded with the keyboard protocol the running program negotiated. It MUST NOT be delivered as pasted text, because the paste path replaces control bytes with a space.
13. Argus MUST use Ghostty's per-surface close-confirmation heuristic, including the user's Ghostty `confirm-close-surface` configuration, to decide whether a Terminal Surface still has a running process. Argus MUST NOT invent a separate process-group scan.
14. Closing the application or the main window MUST require confirmation when any Terminal Surface still has a running process. Cancel MUST leave the application, window, Workspaces, and processes unchanged. That confirmation MUST name each affected Workspace and its Named Project or Standalone Workspace directory context so the user can find the running process without guessing.
15. Dropping files on a Terminal Pane MUST insert their shell-quoted paths without executing them, and MUST target the Pane the user sees. Because inactive Terminal Tabs stay mounted in the same frame, the drop MUST resolve to the visible Pane under the pointer, and MUST be refused when the Active Tab shows no Terminal Pane there.

## Right Sidebar

1. The Right Sidebar MUST contain the Files and Changes Right-sidebar Views.
2. Switching Right-sidebar Views MUST NOT change Workspace selection or Active Tab.
3. Asynchronous results MUST remain associated with the Workspace that initiated them.

## Titlebar

1. The Center Content Area Titlebar MUST identify the Selected Workspace and its Project or Standalone Workspace directory context.
2. Duplicate Workspace and context names SHOULD be shown once rather than repeated.
3. The Center Content Area Titlebar MUST NOT show the current branch, dirty state, or upstream ahead or behind counts.
4. The macOS window title MUST track the visible Workspace context for system surfaces such as Mission Control.

### Files View

1. The Files View MUST show a lazy Workspace File Tree rooted at the Selected Workspace's Workspace Root.
2. Directories MUST load their children when expanded rather than requiring the entire tree to be loaded initially.
3. Directories MUST sort before files at each level.
4. Workspace Items MUST use semantic file and folder icons; unknown files MUST use `doc`.
5. The Files View MUST support selection and Workspace Item Operations for open, copy, rename, and delete where applicable. File and directory context menus MUST support copying the Workspace Item path relative to the Workspace Root as plain text.
6. Destructive Workspace Item Operations MUST require confirmation.
7. Refreshing the same Workspace File Tree SHOULD retain the current tree while new data loads and MUST ignore stale asynchronous results.
8. File enumeration MUST remain bounded and disclose truncation when its display limit is reached.
9. Opening a file MUST create or reuse a File Tab in the initiating Workspace.
10. File Tabs MAY render source text, Markdown, native image formats, and SVG source or image preview according to file type and Panel-local controls.
11. Unsupported, binary, oversized, or failed content MUST show an in-tab state instead of opening another window.

### Changes View

1. The Changes View MUST resolve its Git Status Root from Workspace classification:
   - Worktree Workspace: worktree path;
   - Main-checkout Workspace: Project Repository Root;
   - Standalone Workspace: Workspace Root.
2. Git status and mutations MUST NOT follow a Terminal Panel's live Terminal Working Directory.
3. The Changes View MUST show branch and upstream information, ahead and behind counts, aggregate statistics, and an ordered collection of typed Change Sections.
4. The two Changes View settings MUST combine independently:

   | Combine Working Changes | Show Against Base | Sections, in order |
   | --- | --- | --- |
   | Off | Off | Staged, Unstaged, Untracked |
   | On | Off | Uncommitted |
   | Off | On | Staged, Unstaged, Untracked, Against `<base>` |
   | On | On | Uncommitted, Against `<base>` |

   Working-change sections MUST always precede Against Base. Against Base is
   additive and MUST NOT replace Working Changes.
5. Git File Changes MUST show their Git File Status, path, and available addition/deletion statistics. Working Changes MUST retain their staged, unstaged, and untracked state even when combined. A path MAY appear in both Working Changes and Against Base because they are separate comparison contexts.
6. Uncommitted MUST contain one row per unique Working Changes path and represent its complete `HEAD`-to-working-tree difference. A row whose staged and unstaged changes cancel MUST remain visible with an explanatory empty-diff state. Unborn repositories MUST still represent staged additions and untracked files.
7. Changed paths MAY be grouped into a compacted Change Tree. Git status MUST enumerate individual untracked paths rather than treating an untracked directory as one opaque item.
8. The clean-state empty state MUST replace the file sections only when no present section has entries in any active comparison context and no present section is unavailable. A branch with committed Against Base changes and a clean working tree therefore MUST keep its sections. Otherwise, empty available sections MUST remain visible and collapsible. A non-repository directory MUST offer Git initialization.
9. Working Changes alone determine whether a working tree is dirty; Against Base MUST NOT make clean Working Changes dirty.
10. Displayed entries MUST be capped at 500 in visible section order. Section counts and Section Operations MUST retain their full uncapped scope.
11. The Changes badge, branch summary total, and aggregate additions/deletions MUST count entries in every active comparison context.

#### Base Branch and Against Base

1. Base Branch work MUST run only when its setting is enabled and MUST never contact a remote or mutate repository state.
2. A Recorded Base Branch MUST take precedence over the configured/detected rules below. Argus MUST use the same local metadata reader as Stack grouping: a valid explicit `branch.<current-branch>.base` wins; otherwise matching Graphite `parentBranchName` and gh-stack parent records coalesce. A conflicting or cyclic current-branch declaration MUST make only Against Base unavailable rather than choose a provider or silently fall back. Unrelated diagnostics MUST NOT block a usable current-branch parent or discard Working Changes. Empty, self, invalid, or unresolvable recorded names MUST fall through to the configured/detected rules. A Recorded Base Branch MUST resolve its local branch before its `origin`-tracking reference, because a stack parent's stale remote reference can move the merge base backwards.
3. A Named Project MUST use its configured main branch, preferring the corresponding `origin`-tracking reference over the local branch.
4. A Standalone Workspace MUST detect its Base Branch from `origin/HEAD`, then an available local `main` or `master`; after selecting the name, it MUST prefer the matching `origin`-tracking reference over the local branch. It MUST NOT use the current branch as its own Base Branch, scan arbitrary remotes, or infer a Base Branch from the current branch name.
5. Against Base MUST show committed changes from the merge base of the resolved Base Branch and `HEAD` to `HEAD`, excluding Working Changes. Its title MUST use the Base Branch name even when an `origin`-tracking reference supplies the content.
6. If the Base Branch or comparison is unavailable, only Against Base MUST become unavailable. Working Changes MUST remain loaded and actionable, while Against Base remains visible with a concise explanation and no rows or Section Operations. Refreshing MUST retry the comparison.

#### Change actions

1. Staged changes MUST offer Unstage, Diff, Blame, and Copy Path; Unstaged changes MUST offer Stage, confirmed Discard, Diff, Blame, and Copy Path; Untracked changes MUST offer Stage, confirmed Delete, Diff, Copy Path, and Add to `.gitignore`. Add to `.gitignore` MUST support untracked files and displayed untracked directories.
2. Classic Change Sections MUST retain their applicable Stage All, Unstage All, confirmed Discard All, and confirmed Delete All operations.
3. Uncommitted MUST expose the same applicable row actions from each path's retained Working Changes state. Stage MUST affect unstaged or untracked content, Unstage MUST affect staged content, Discard MUST affect only unstaged tracked content, and Delete MUST be limited to untracked paths.
4. Uncommitted Section Operations MUST keep Stage All, Unstage All, confirmed Discard All Unstaged, and confirmed Delete All Untracked as applicable. Destructive subsets MUST remain separate, name their exact operation, and use the full uncapped affected count.
5. Against Base MUST have no Git Mutations or Section Operations. Its rows MUST offer Diff and Copy Path, plus Blame only when the path exists at `HEAD`.
6. A completed Git Mutation MUST refresh the Git Status Snapshot without losing its active Changes View settings.

#### Preview behavior

1. Diff and Blame MUST open Git Preview Tabs in the initiating Workspace. Reopening a matching Preview Kind, Git Status Root, path, and comparison context SHOULD refresh and select the existing tab.
2. Uncommitted Diff MUST compare `HEAD` with the complete working-tree content, using empty content for an absent side. A canceled net change MUST show an explanatory state rather than a blank or failing diff.
3. Against Base Diff MUST compare the merge base with `HEAD`; Against Base Blame MUST target `HEAD` so Working Changes do not alter the committed preview.
4. Structured diffs MUST render natively with Split or Unified layout. Long lines MUST scroll horizontally.
5. Existing binary, size, line-length, and failure behavior MUST remain unchanged.

#### Refresh, clean state, and UI rules

1. Refresh results MUST apply only to the Workspace, Git Status Root, and settings that initiated them; stale results MUST be ignored.
2. Refreshing the same Workspace and Git Status Root SHOULD preserve loaded content, section and directory expansion, scroll position, selection, and focus. Expansion state MUST remain independent for each Change Section kind.
3. Expand/collapse-all MUST affect only currently present, available sections.
4. Accessibility values MUST identify Git File Status and the relevant Working Changes or Against Base context. Unavailable states MUST NOT rely on color alone.

### Automatic Git refresh

1. Argus MUST use recursive FSEvents monitoring for the Git Status Root and applicable common/linked Git administrative directories, including separate Git-directory layouts. Watch setup MUST NOT run Git subprocesses on MainActor and MUST preserve valid pathname whitespace and embedded newlines.
2. Normal filesystem changes MUST be debounced by approximately 300 milliseconds.
3. A completed refresh MUST start an approximately one-second cooldown for ordinary working-tree events.
4. Git index/object noise that would create feedback loops MUST be suppressed. Configuration, config.worktree, supported parent metadata, packed refs, and relevant HEAD/local/remote reference changes MUST remain refreshable, including sibling administrative metadata. Remote reference and reflog changes MUST remain refreshable for every remote so upstream counts do not become stale.
5. Relevant branch, ref, and parent-metadata changes received during cooldown MUST be deferred rather than dropped, so displayed branch and Against Base context cannot remain stale.

## Git worktrees

1. Git operations MUST use spawned `git` processes. Argus MUST NOT depend on libgit2.
2. Managed Worktrees MUST be stored under `~/.argus/worktrees/<project-uuid>/<branch-slug>/`.
3. Storage slugs MUST be lowercase, filesystem-safe, and hyphen-separated. Storage-path collisions MUST receive a numeric suffix.
4. Creating a new Worktree Workspace MUST reject a branch name that already exists. Storage-path suffixing MUST NOT be described as branch-name generation.
5. Existing local and remote branches MAY be selected for a Worktree Workspace.
6. Branch choices MUST exclude branches already checked out in another worktree.
7. Worktree removal MUST invoke `git worktree remove`; Project cleanup MAY force removal.
8. Forced worktree removal MUST complete even when `git worktree remove` cannot. When that command fails, Argus MUST delete the worktree directory directly and prune the stale worktree registration so the branch becomes available again. Unforced removal MUST NOT fall back this way, so a dirty worktree still fails and retains its uncommitted files.
9. Worktree removal MUST allow substantially more time than a Git query, because an interrupted removal can leave a worktree that `git worktree remove` permanently refuses.
10. Argus MUST scan its managed storage for Orphaned Worktrees not represented by Workspace state.
11. Orphaned Worktrees MUST support adopt, delete, and dismiss actions.
12. "Delete Worktree and Close" MUST remove the worktree before deleting Workspace state.
13. If worktree removal fails, the Workspace MUST remain open and the underlying error MUST be shown.
14. Worktree deletion progress MUST reflect actual removal and Workspace-close operation boundaries.
15. V1 does not model Managed Worktree ownership separately from every possible external secondary worktree. Code MUST NOT infer safe deletion solely from the generic Worktree Workspace type.
16. Pull Request intake MUST validate the Pull Request base Repository Identity against a fetch URL of the initiating Named Project. It MUST support HTTPS, SSH, and SCP-style GitHub fetch URLs, prefer `origin` when identities match multiple remotes, and MUST ignore push-only URLs.
17. Pull Request intake MUST fetch `refs/pull/<number>/head`, resolve `FETCH_HEAD^{commit}` as the authoritative head for the attempt, and create or reuse the requested local head branch at that exact commit. Fork Pull Requests MUST work without adding a Git remote.
18. Pull Request intake MUST reuse an exact existing branch, registered worktree, and matching Workspace. A same-name local branch at another commit MUST fail without resetting, force-updating, renaming, or deleting that branch or its worktree. Pull Request metadata and provider association remain transient; the ordinary Worktree Workspace is what the Session Snapshot restores.

### GitHub CLI Pull Request boundary

1. The optional `gh` executable MUST be located through the application `PATH`, then `/opt/homebrew/bin/gh`, then `/usr/local/bin/gh`. Pull Request commands MUST use argument arrays, the Project Repository Root as their working directory, bounded output, a 30-second timeout, and noninteractive prompt, pager, color, and terminal-authentication overrides.
2. Argus MUST use the active `gh` authentication context and MUST NOT request, read, persist, or log GitHub credentials. Missing CLI, authentication, ambiguous bare-number repository selection, invalid metadata, provider timeout, and provider command failure MUST remain distinguishable actionable errors.
3. Pull Request creation MUST resolve metadata, fetch the head, prepare the Worktree, and attach or select the Workspace as one operation. The initiating Project ID and Project Repository Root MUST be revalidated before Workspace state changes; a removed or changed Project MUST receive no Workspace.

## Browser Panels

1. Browser Panels MUST render with WebKit inside normal Workspace Top-level Tabs.
2. Browser chrome MUST include back, forward, reload, address, security, and loading controls.
3. Navigation controls MUST be disabled when their actions are unavailable.
4. Scheme-less addresses MUST default to HTTPS.
5. Configured search providers MAY transform non-URL input into a search URL.
6. Browser creation MUST apply global defaults unless an explicit Panel value is supplied.
7. Cmd+F MUST show find-in-page controls with match count and next/previous navigation.
8. Escape MUST dismiss the find overlay.
9. Background Browser Panels MUST NOT become first responder or steal application focus.
10. Browser Panels are runtime-only in the v1 Session Snapshot and are not restored.

## Agent Status

1. V1 MAY display process-local Agent Status Entries supplied through the in-process `AgentStatusStore`.
2. Agent Keys MUST be unrestricted strings.
3. Supported states are idle, running, needs input, and error, each with a distinct label, icon, and semantic color.
4. Agent Status MAY be scoped to a Workspace or Terminal Surface.
5. Per-panel Agent Status MUST override Workspace-level Agent Status for that Terminal Surface.
6. A loading indicator MUST take precedence over Agent Status in a Top-level Tab. Agent Status MUST take precedence over the default icon.
7. Agent Status Entries MUST remain ephemeral and MUST NOT be restored.
8. Argus MUST host a user-local Unix Domain Socket for the implemented `agent.turnCompleted`, `agent.statusChanged`, and `agent.statusCleared` methods. The Socket Server MUST use bounded newline-delimited JSON frames, restrictive permissions, structured responses, and current Workspace/Terminal Surface ownership validation without activating the app or changing focus.
9. Agent Status Socket Requests MUST identify an Agent Key, Workspace ID, reporting session ID, and positive sequence number. A status update MAY identify a Terminal Surface; when supplied, that Surface MUST belong to the supplied Workspace. Older or duplicate updates from the same reporting session MUST be accepted idempotently without changing the Agent Status Entry.
10. `agent.statusChanged` MUST set one ephemeral Agent Status Entry, and `agent.statusCleared` MUST remove only the exact entry reported by that session and scope. Status ordering and Socket connections MUST remain process-local and MUST NOT be persisted.
11. A successful Turn Completion Event for an unviewed Top-level Tab MUST create runtime-only Turn Completion Attention on that tab and summarize it on the Workspace row. A completion in the Active Tab of the Selected Workspace while the main window is key MUST create neither attention nor sound.
12. Top-level Tab icon precedence MUST be loading, Turn Completion Attention, Agent Status, then the default icon. Workspace icon precedence MUST be Turn Completion Attention, Agent Status, then the Workspace-type icon.
13. Turn Completion Attention MUST clear when its Top-level Tab becomes viewed, and MUST be discarded when its tab or Workspace closes. It MUST NOT be restored from the Session Snapshot.
14. Agent settings MUST include an Agent completion sound preference that defaults to enabled and remains independent of Terminal audible bell behavior.
15. Kilo integration MUST be installed or removed only through explicit Settings controls. Argus MUST preserve unrelated Kilo JSON/JSONC configuration, own only its declaration and plugin file, surface setup errors, and require running Kilo sessions to restart after a change.
16. The Kilo TUI plugin MUST use public extension points only, accept successful root-turn completion after conservative non-synthetic, non-compaction user-turn filtering, ignore child, failed, interrupted, and idle-only events, and remain silent on delivery failure.
17. Pi integration MUST be installed or removed only through explicit Settings controls. It MUST own only its extension file under the effective Pi agent directory, preserve unrelated files, use public lifecycle events to report running, idle, and error states, clear its status on session shutdown, and remain silent on delivery failure. Processes marked with `PI_SUBAGENT_CHILD=1` MUST report neither Agent Status nor Turn Completion Events. A main-agent turn MUST emit at most one successful Turn Completion Event when it settles without a final error or interruption. If `pi-subagents` advertises its public event-bus RPC, the integration MUST check its current-session fleet status before announcing completion. On a successful main-agent settlement, active delegated work MUST retain running Agent Status and suppress completion until a later successful main-agent settlement reports no active work. An unsupported, failed, malformed, or timed-out advertised status check MUST suppress completion without blocking Pi indefinitely. Delayed checks MUST NOT report completion after another turn starts or the session shuts down or changes. Running Pi sessions MUST be restarted or reloaded after a change.
18. V1 still does not include functional Companion CLI commands, Agent PID tracking, TTS, notification history, or macOS Notification Center notifications.

## Release notes

1. Argus MUST bundle its application changelog and expose it through Help > Release Notes.
2. The changelog MUST open as a runtime-only Release Notes Tab in the Selected Workspace and MUST reuse an existing Release Notes Tab in that Workspace.
3. Release-note links MUST open in a Browser Tab in the Workspace that owns the Release Notes Tab.
4. Argus MUST NOT open release notes automatically after an update.

## Session persistence

1. Argus MUST store one JSON Session Snapshot at `~/Library/Application Support/Argus/session.json`.
2. The snapshot MUST use one schema version. An incompatible version MUST be discarded rather than migrated.
3. Snapshots with no Workspaces and snapshots containing more than 128 Workspaces MUST be rejected. A Workspace with zero persisted Terminal Panels is valid.
4. Restore MUST reconcile Project and Workspace references, retain one Catch-all Project, remove stale references, and choose a valid Selected Workspace.
5. Project snapshots MUST include Project identity, repository metadata, ordering, expansion state, optional color, and collapsed Stack Group keys. Older snapshots without collapsed keys MUST restore with all Stack Groups expanded.
6. Workspace snapshots MUST include Workspace identity and type, Project association, branch and worktree metadata, Workspace Root, display title, the count used to reconstruct Terminal Panels, terminal custom titles, and per-terminal Terminal Working Directories.
7. Restored Terminal Panels MUST use their last observed Terminal Working Directory as the initial directory.
8. File Panels, Git Preview Panels, Browser Panels, Release Notes Panels, split layouts, Active Tab, Focused Pane, Git Status Snapshots, and Agent Status Entries are runtime-only in v1. A Workspace whose persisted Terminal Panel count is zero MUST restore with no Terminal Panels and nil active state.
9. Argus MUST synchronously save the Session Snapshot during normal application termination. It MUST also synchronously checkpoint after a user commits a Workspace display-name or Workspace Root change, so those changes survive an application crash.
10. V1 does not provide periodic autosave. Event-driven checkpoints for explicitly user-authored durable changes do not constitute periodic autosave.
11. Restore MUST be skipped when disabled in Settings or by the supported test/restore environment overrides.

## Build and local installation

1. `scripts/build.sh` MUST build the app and, by default, the Companion CLI scaffold, bundle the CLI at `Contents/Resources/bin/argus` relative to the built application, and ad-hoc sign the result.
2. Debug MUST remain the default configuration; `--release` MUST select Release.
3. The build script MUST support build, CLI-only build, run, install, clean, and Xcode-project generation commands.
4. Structured Git Preview diffs MUST render with the native `SwiftDiffs` package. Normal app builds MUST NOT require Node.js or a committed JavaScript renderer bundle.
5. Run and install operations MUST ask a running Argus instance to quit, wait up to approximately five seconds, and then terminate it if needed.
6. Launching a newly built app MUST strip inherited Argus identity environment variables.
7. V1 build tooling does not check for active coding-agent processes before replacing the app.

## Known v1 limitations

- The Companion CLI is a versioned scaffold and has no socket-backed commands; the application socket implements only the agent turn-completion and live Agent Status methods described above.
- Pi has no generic public lifecycle event for `needsInput`; the Pi integration reports idle while waiting for the next prompt.
- Pi child-session filtering uses the `pi-subagents` package's `PI_SUBAGENT_CHILD` marker, and delegated-work checks use its advertised version-one fleet status API. Other launchers or older packages that do not advertise that API cannot provide delegated-work awareness. Plain Pi sessions retain lifecycle-based completion reporting.
- Kilo's public extension API cannot prove that every ordinary non-synthetic user message was authored interactively by a person, so completion provenance uses conservative best-effort filtering.
- Nonterminal Panels, split layout, and current tab/focus state are not restored.
- Session persistence occurs on normal application termination and after committed Workspace display-name or Workspace Root changes; there is no periodic autosave.
- Worktree ownership is not represented independently from Workspace type.
