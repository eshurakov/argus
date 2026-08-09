# Argus application specification

## Status

Stable v1 baseline, updated 2026-08-08.

This document defines behavior implemented by the current Argus application. Future work belongs under `docs/proposals/` until it is implemented and incorporated here.

The words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" are normative.

## Product scope

Argus is a personal macOS terminal workspace manager built on Ghostty. It organizes terminal, browser, file, and Git preview content into Workspaces; groups repository-backed Workspaces into Projects; manages Git worktrees; shows Workspace files and Git changes; and restores durable session state.

Argus is a single-user, single-machine application. It has one main Workspace window and a separate native Settings surface. It does not provide a general external control API in v1; the local socket is limited to the agent integration events specified below.

## Application shell

1. The main window MUST use a three-column layout: the left sidebar, center Workspace content, and the Right Sidebar.
2. The main window MUST use a full-size transparent titlebar and an opaque black application shell.
3. The left sidebar and Right Sidebar MUST be independently toggleable and resizable.
4. Left-sidebar visibility and width MUST persist in `UserDefaults`. Its default width is 200 points, with an effective range from 80 points to one third of the window width.
5. Right-sidebar visibility, width, and selected Right-sidebar View MUST persist in `UserDefaults`. Its width range is 180 to 600 points and its default width is 250 points.
6. Dividers MUST provide a drag target wider than their visible separator.
7. Inspectable content MUST remain in the main Workspace window. Settings, sheets, alerts, menus, and popovers MAY use their normal macOS surfaces.

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
7. Files and Changes settings MUST include hidden Workspace Item visibility, initial source wrapping, initial Markdown and SVG display modes, initial diff layout, and initial diff overflow behavior.
8. Browser settings MUST include homepage, search provider, page zoom, WebKit inspectability, and persistent or private website data storage.
9. Global defaults MUST apply when their target is created. They MUST NOT reset existing Panel-local state.
10. `.git` MUST remain excluded from the Files View even when hidden Workspace Items are visible.

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
7. Cmd+1 through Cmd+8 MUST select Workspaces by global left-sidebar order. Cmd+9 MUST select the last Workspace.
8. The left sidebar MUST show Project and Workspace hierarchy, selection, Workspace type, branch when available, and Agent Status when present.
9. A Standalone Workspace MUST allow its Workspace Root to be changed from its left-sidebar context menu.
10. The Workspace Root change workflow MUST support both directory browsing and direct path entry. An entered path MUST resolve to an existing directory.
11. Changing a Standalone Workspace's Workspace Root MUST immediately update its Files View and Git Status Root. New Terminal tabs MUST start at the new Workspace Root without changing existing Terminal Working Directories.
12. A Standalone Workspace row MUST show its Workspace Root beneath its display name, abbreviating the user's home directory with `~`.
13. When the keep-open preference is enabled, closing the final Terminal Tab MUST retain the same Workspace as an Empty Workspace with no Panels, Top-level Tabs, Active Tab, Focused Pane, or live Terminal Surfaces.
14. An Empty Workspace MUST remain selectable and retain its Workspace Root, Project membership, sidebar order, Files View, and Changes View context.

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
11. Closing the final Terminal Tab MUST require Workspace-close confirmation before changing state when the keep-open preference is disabled. When the preference is enabled, it MUST close the complete Terminal Tab and retain an Empty Workspace.
12. Closing a final Browser, File, Git Preview, or Release Notes Tab MUST retain the existing generic Workspace-close lifecycle regardless of the keep-open preference.
13. The empty content region of a Selected Empty Workspace MUST show the normal Workspace chrome, a restrained terminal symbol, “No tabs open”, and a native “New Terminal Tab” action. The action MUST use the normal Terminal Tab creation path and initialize the new Terminal Working Directory from the Workspace Root.

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
3. Argus MUST load Ghostty default and recursive configuration before applying its bundled opaque-black terminal background override.
4. Terminal surfaces MUST retain user Ghostty configuration except for the Argus-owned background and background-opacity values.
5. Spawned shells MUST receive `ARGUS_SOCKET_PATH`, `ARGUS_WORKSPACE_ID`, and `ARGUS_SURFACE_ID`.
6. These variables identify the application socket, Workspace, and Terminal Surface for supported integrations. Their presence MUST NOT be treated as proof that a particular Agent Integration is enabled.
7. Argus MUST set terminal-identifying environment values and prepend existing supported Homebrew binary directories to `PATH`.
8. Terminal title and working-directory callbacks MUST update their Terminal Panel state on the main thread.
9. Inactive terminal surfaces SHOULD remain mounted during Top-level Tab changes. They MUST be occluded and prevented from stealing focus or accessibility interaction.
10. Terminal Working Directory MUST remain distinct from Workspace Root and Git Status Root.
11. Cmd+V with an image-only system clipboard MUST reach the running terminal program as Ctrl+V. Text-capable clipboard contents MUST retain Ghostty's normal paste behavior.

## Right Sidebar

1. The Right Sidebar MUST contain the Files and Changes Right-sidebar Views.
2. Switching Right-sidebar Views MUST NOT change Workspace selection or Active Tab.
3. Asynchronous results MUST remain associated with the Workspace that initiated them.

## Titlebar

1. The Center Content Area Titlebar MUST identify the Selected Workspace and its Project or Standalone Workspace directory context.
2. Duplicate Workspace and context names SHOULD be shown once rather than repeated.
3. Available Git context MUST include the current branch, dirty state, and upstream ahead or behind counts.
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
3. The Changes View MUST show branch and upstream information, ahead and behind counts, aggregate statistics, and Staged, Unstaged, and Untracked sections.
4. Git File Changes MUST show their status, path, and available addition/deletion statistics.
5. Changed paths MAY be grouped into a compacted Change Tree.
6. Displayed changes MUST be capped at 500 while section counts and Section Operations continue to represent the full Git Status Snapshot.
7. Git status MUST request individual untracked paths rather than treating an untracked directory as one opaque item.
8. A clean repository MUST show a clean state. A non-repository directory MUST offer Git initialization.
9. Refreshing the same Git Status Snapshot SHOULD keep current content visible and show progress in reserved chrome.
10. Changing the snapshot owner MAY replace content with an initial loading state.

### Change actions

1. Staged changes MUST offer unstage, diff, blame, and copy-path actions.
2. Unstaged changes MUST offer stage, discard, diff, blame, and copy-path actions.
3. Untracked changes MUST offer stage, delete, diff, copy-path, and add-to-`.gitignore` actions. The add-to-`.gitignore` action MUST support untracked file paths and displayed untracked directory paths.
4. Applicable Section Operations MUST include stage all, unstage all, discard all, and delete all.
5. Discard and delete operations MUST require confirmation.
6. A completed Git Mutation MUST refresh the Git Status Snapshot.
7. Diff and blame actions MUST open Git Preview Tabs in the initiating Workspace.
8. Reopening the same Preview Kind, Git Status Root, and path SHOULD refresh and select its existing Git Preview Tab.

### Automatic Git refresh

1. Argus MUST use recursive FSEvents monitoring for the Git Status Root.
2. Normal filesystem changes MUST be debounced by approximately 300 milliseconds.
3. A completed refresh MUST start an approximately one-second cooldown for ordinary working-tree events.
4. Git metadata changes that would create index feedback loops MUST be suppressed.
5. Branch and ref changes received during cooldown MUST be deferred so the displayed branch cannot remain stale.

## Git worktrees

1. Git operations MUST use spawned `git` processes. Argus MUST NOT depend on libgit2.
2. Managed Worktrees MUST be stored under `~/.argus/worktrees/<project-uuid>/<branch-slug>/`.
3. Storage slugs MUST be lowercase, filesystem-safe, and hyphen-separated. Storage-path collisions MUST receive a numeric suffix.
4. Creating a new Worktree Workspace MUST reject a branch name that already exists. Storage-path suffixing MUST NOT be described as branch-name generation.
5. Existing local and remote branches MAY be selected for a Worktree Workspace.
6. Branch choices MUST exclude branches already checked out in another worktree.
7. Worktree removal MUST invoke `git worktree remove`; Project cleanup MAY force removal.
8. Argus MUST scan its managed storage for Orphaned Worktrees not represented by Workspace state.
9. Orphaned Worktrees MUST support adopt, delete, and dismiss actions.
10. "Delete Worktree and Close" MUST remove the worktree before deleting Workspace state.
11. If worktree removal fails, the Workspace MUST remain open and the underlying error MUST be shown.
12. Worktree deletion progress MUST reflect actual removal and Workspace-close operation boundaries.
13. V1 does not model Managed Worktree ownership separately from every possible external secondary worktree. Code MUST NOT infer safe deletion solely from the generic Worktree Workspace type.

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
17. Pi integration MUST be installed or removed only through explicit Settings controls. It MUST own only its extension file under the effective Pi agent directory, preserve unrelated files, use public lifecycle events to report running, idle, and error states, emit a successful Turn Completion Event when an agent turn settles without a final error, clear its status on session shutdown, and remain silent on delivery failure. Running Pi sessions MUST be restarted or reloaded after a change.
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
5. Project snapshots MUST include Project identity, repository metadata, ordering, expansion state, and optional color.
6. Workspace snapshots MUST include Workspace identity and type, Project association, branch and worktree metadata, Workspace Root, display title, the count used to reconstruct Terminal Panels, terminal custom titles, and per-terminal Terminal Working Directories.
7. Restored Terminal Panels MUST use their last observed Terminal Working Directory as the initial directory.
8. File Panels, Git Preview Panels, Browser Panels, Release Notes Panels, split layouts, Active Tab, Focused Pane, Git Status Snapshots, and Agent Status Entries are runtime-only in v1. A Workspace whose persisted Terminal Panel count is zero MUST restore with no Terminal Panels and nil active state.
9. Argus MUST synchronously save the Session Snapshot during normal application termination. It MUST also synchronously checkpoint after a user commits a Workspace display-name or Workspace Root change, so those changes survive an application crash.
10. V1 does not provide periodic autosave. Event-driven checkpoints for explicitly user-authored durable changes do not constitute periodic autosave.
11. Restore MUST be skipped when disabled in Settings or by the supported test/restore environment overrides.

## Build and local installation

1. `scripts/build.sh` MUST build the app and, by default, the Companion CLI scaffold, bundle the CLI at `Contents/Resources/bin/argus` relative to the built application, and ad-hoc sign the result.
2. Debug MUST remain the default configuration; `--release` MUST select Release.
3. The build script MUST support build, web-asset rebuild, CLI-only build, run, install, clean, and Xcode-project generation commands.
4. Normal app builds MUST use the committed Pierre diff renderer bundle and MUST NOT require Node.js.
5. Rebuilding that bundle MUST use the pinned `ArgusWeb` dependencies. The generated bundle MUST be the only tracked artifact changed by the rebuild.
6. Run and install operations MUST ask a running Argus instance to quit, wait up to approximately five seconds, and then terminate it if needed.
7. Launching a newly built app MUST strip inherited Argus identity environment variables.
8. V1 build tooling does not check for active coding-agent processes before replacing the app.

## Known v1 limitations

- The Companion CLI is a versioned scaffold and has no socket-backed commands; the application socket implements only the agent turn-completion and live Agent Status methods described above.
- Pi has no generic public lifecycle event for `needsInput`; the Pi integration reports idle while waiting for the next prompt.
- Kilo's public extension API cannot prove that every ordinary non-synthetic user message was authored interactively by a person, so completion provenance uses conservative best-effort filtering.
- Nonterminal Panels, split layout, and current tab/focus state are not restored.
- Session persistence occurs on normal application termination and after committed Workspace display-name or Workspace Root changes; there is no periodic autosave.
- Worktree ownership is not represented independently from Workspace type.
