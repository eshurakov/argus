# Changelog

This file records changes pushed for local Argus releases. New entries use a `YYYY-MM-DD` heading and link to their commit or commits.

## 2026-09-04

- The `argus` command line tool now lists and creates Workspaces in a running Argus. `argus workspace list` prints Projects and their Workspaces in sidebar order, with each Workspace's number, type, and branch, and shows Stack Groups as parent-to-dependent trees including branches that have no open Workspace. `--json` prints the same information for scripts. ([69d3adf](https://github.com/eshurakov/argus/commit/69d3adfbe7dfab5c15d91b101bbe92a9f84359ed))
- `argus workspace create` adds a Worktree Workspace to a Project. Without options it uses the Project of the terminal you run it in and generates an available branch name; `--project`, `--branch`, and `--name` set those explicitly. Creating a Workspace this way does not move your place in the sidebar, so it is safe to run from an agent's terminal. ([69d3adf](https://github.com/eshurakov/argus/commit/69d3adfbe7dfab5c15d91b101bbe92a9f84359ed))
- `argus workspace create --from <workspace>` starts the new branch from that Workspace's branch and records it as the parent, so both Workspaces appear together in a Stack Group in the sidebar and Changes compares against the right branch. Use `--from .` for the Workspace you are running in. ([69d3adf](https://github.com/eshurakov/argus/commit/69d3adfbe7dfab5c15d91b101bbe92a9f84359ed))
- `argus` now works without setup inside an Argus terminal: the bundled command is first on the `PATH` of every shell Argus starts, alongside the existing Argus environment variables. From an ordinary terminal, call it at `Argus.app/Contents/Resources/bin/argus` or symlink it onto your own `PATH`. ([69d3adf](https://github.com/eshurakov/argus/commit/69d3adfbe7dfab5c15d91b101bbe92a9f84359ed))
- The tool asks Argus for everything and decides nothing itself: names, branches, and `.` are resolved by the app against its live state, and an ambiguous name is refused with the matching candidates instead of a guess. It exits 0 on success, 1 when Argus refuses a request, and 3 when Argus is not running. ([69d3adf](https://github.com/eshurakov/argus/commit/69d3adfbe7dfab5c15d91b101bbe92a9f84359ed))

## 2026-09-03

- Released Argus 1.15.0 with Collections for organizing Named Projects. Create and rename Collections, move Projects with context menus or drag-and-drop, and reorder whole Project blocks without changing open work. Removing a Collection keeps its Projects and Workspaces. ([4310d91](https://github.com/jeanduplessis/argus/commit/4310d918261998b46a894f90c5f6df83a46e616f))
- Collections remember their order and disclosure state. Workspace shortcuts follow the same order even when groups are collapsed, and selecting a hidden Workspace reveals it. Session restore retains valid Collections even when invalid or duplicate records precede them. ([4310d91](https://github.com/jeanduplessis/argus/commit/4310d918261998b46a894f90c5f6df83a46e616f))
- Release checks now pass the current lint rules, with Pull Request Status behavior preserved and regression coverage for invalid UTF-8 diagnostics. ([4310d91](https://github.com/jeanduplessis/argus/commit/4310d918261998b46a894f90c5f6df83a46e616f))

## 2026-09-01

- Released Argus 1.14.0 with Workspace Stack Groups and main-agent-only Pi completion alerts. Subagents no longer trigger completion sounds or bell indicators, and Pi stays marked as running while delegated work continues. Enable the updated Pi integration in Settings, then restart Pi or run `/reload` to use the fix. ([6f9230f](https://github.com/jeanduplessis/argus/commit/6f9230f484eea0110766a8d2159293976c4bcc50))
- Worktree Workspaces now show Pull Request Status beside the branch name, with lifecycle, review, and check details plus Open, Copy URL, and Refresh actions. Background updates use batched, read-only GitHub CLI requests, respect rate limits, and can be disabled in Settings. ([85eb032](https://github.com/jeanduplessis/argus/commit/85eb032f2617b21b3acdbeba788f86e72b18b1fa))
- Related Workspaces now appear in collapsible Stack Groups with parent-to-dependent connectors, including forks and missing parent Workspaces. Grouping, keyboard navigation, and reordering share one order, collapsed groups remember their state, and relationship details stay in the list rather than a separate footer. ([a7ec9e8](https://github.com/jeanduplessis/argus/commit/a7ec9e8533a9fa7a7f5dd2c8f2fae51f3238b517))
- Stack Groups and Against Base now share locally recorded parents from Git configuration, Graphite, and gh-stack. Conflicting metadata is reported without hiding unrelated groups or Working Changes, and metadata changes refresh automatically without contacting a remote. ([a7ec9e8](https://github.com/jeanduplessis/argus/commit/a7ec9e8533a9fa7a7f5dd2c8f2fae51f3238b517))

## 2026-08-31

- Ghostty and AppKit state now stays on the Main Actor, and the Ghostty build rejects duplicate archive member names that can break dSYM generation. The build cache includes the local archive-naming patch, so patched and unpatched frameworks cannot be mixed. ([22bc945](https://github.com/jeanduplessis/argus/commit/22bc945ae070f41cd7a8f913f57a9c61fa342e1f))
- Released Argus 1.13.2 with terminal clipboard prompts that cancel cleanly; safe upgrades and removal for previously installed Kilo and Pi integrations; exact Git statistics and previews for special-character filenames and repositories without commits; restorable Project, Workspace, and Terminal Panel limits; Project-scoped Orphaned Worktree cleanup; and bounded agent socket lifetimes. ([91d32f3](https://github.com/jeanduplessis/argus/commit/91d32f3de9f86d2f6b330a51f247fda870340951))

## 2026-08-30

- Released Argus 1.13.1 with safer terminal clipboard prompts, exact Git filename handling, authorized Worktree deletion, bounded file and socket operations, stricter Session Snapshot recovery, reliable integration installation, and persistent Files, Changes, and Git Preview settings. ([e9f5051](https://github.com/jeanduplessis/argus/commit/e9f50513b3d092fa4f712f353ae840f61cf17039))

## 2026-08-29

- Argus now changes its window and terminal backgrounds from black to dark grey when the window loses keyboard focus, making the active window easier to spot across monitors. Headers and controls soften without dimming Panel content, Agent Status, or Turn Completion Attention. ([ed816d6](https://github.com/jeanduplessis/argus/commit/ed816d6ad31f3f82bfb1014c7ba1b26eaff93b6e))

## 2026-08-26

- Dropping a file into a terminal now inserts its path in the tab you are looking at, and in the pane you dropped it on. Drops previously always went to the last tab of the workspace and switched to it. When the open tab shows a browser, file, or diff instead of a terminal, the drop is now refused rather than typed into a hidden tab. ([2ff92c4](https://github.com/jeanduplessis/argus/commit/2ff92c4))
- The Changes panel now compares a stacked branch with the branch it is stacked on, instead of always with the repository's main branch. When a stacking tool has recorded a branch's parent — `branch.<name>.base` in Git configuration, or Graphite's branch metadata — Against Base uses that parent, so the section shows only the branch's own commits and its title names the parent. Branches without recorded metadata keep using the project's main branch. Nothing contacts a remote. ([9c75672](https://github.com/jeanduplessis/argus/commit/9c75672))
- The Changes panel no longer hides committed branch changes behind "Working tree clean". A branch with a clean working tree and changes against its base now shows those changes, and an unavailable base shows its explanation instead of being covered by the clean-state message. ([9c75672](https://github.com/jeanduplessis/argus/commit/9c75672))

## 2026-08-14

- Released Argus 1.12.1 with the Changes branch summary condensed into one row, keeping the branch, file totals, upstream status, and section control visible without the previous empty second line. ([b846d62](https://github.com/jeanduplessis/argus/commit/b846d62))
- Released Argus 1.12.0 with native Git diff rendering and a macOS 26 minimum requirement. ([557afef](https://github.com/jeanduplessis/argus/commit/557afef))
- Git diffs now use native macOS text rendering instead of an embedded web view, improving selection, copying, scrolling, and accessibility. Split and Unified layouts remain available; long lines scroll horizontally. Argus now requires macOS 26 and Xcode 26. ([a7350de](https://github.com/jeanduplessis/argus/commit/a7350de))
- The Changes panel now gives the branch name its own line, with file totals and upstream status on a smaller second line. Long branch and upstream names no longer crowd out ahead/behind counts. ([6c2bc8d](https://github.com/jeanduplessis/argus/commit/6c2bc8d))
- The app now uses one consistent style for interface details. Text in sidebar headers, the branch bar, file counts, and file headers follows the Interface Text Size setting like the rest of the chrome; the running-process badge on workspaces and the count on the Changes tab share one badge style; tab and workspace icons share one size and weight; and hover backgrounds use one shared treatment. ([3576e05](https://github.com/jeanduplessis/argus/commit/3576e05))
- Empty, error, and "not a repository" messages in the Files and Changes panels, file previews, and release notes now share one layout with consistent icon size, title, and action button styling. ([3576e05](https://github.com/jeanduplessis/argus/commit/3576e05))
- The workspace titlebar and the macOS window title no longer show the branch name, dirty marker, or ahead/behind counts. The titlebar now names just the workspace and its project or folder; the Changes panel remains the place to see branch details. ([ee88ca2](https://github.com/jeanduplessis/argus/commit/ee88ca2))
- The left sidebar no longer keeps a permanent number column next to workspaces. Hold Command to see each workspace's keyboard shortcut digit over its icon: 1-8 for the first eight workspaces, and 9 for the last one when there are more than eight. ([73ed79d](https://github.com/jeanduplessis/argus/commit/73ed79d))

## 2026-08-13

- The Files and Changes panels now remember which folders and sections you expanded. Switching between the two panels, changing workspace, or hiding and showing the right sidebar no longer collapses everything back to the top level. Nested folders reopen as they were, and a workspace's remembered state is discarded when you close it. ([95c2a96](https://github.com/jeanduplessis/argus/commit/95c2a96))
- Deleting a worktree no longer gets stuck reporting "Git command timed out". An earlier attempt that ran out of time could leave the worktree in a state Git itself refused to remove, so every later attempt failed the same way. Deleting a worktree now finishes the job and frees the branch name for reuse, and it allows much more time before giving up. Deleting a worktree with unsaved changes still asks first and keeps those files. ([d2f810c](https://github.com/jeanduplessis/argus/commit/d2f810c))
- Quitting Argus now names the Project and Workspace that still have a running process, so you can find that terminal without guessing. ([f64e920](https://github.com/jeanduplessis/argus/commit/f64e920))
- The left sidebar now treats Workspaces as a top-level section like Projects. Its plus button creates a standalone Workspace, the Projects plus button only creates a Project, standalone Workspace icons no longer show a question mark, and Workspace paths are lighter so the title stands out. ([91ef134](https://github.com/jeanduplessis/argus/commit/91ef134))
- Workspace rows now show how many terminals still have a running process, instead of how many tabs are open. The badge hides when nothing is running. ([f0111ab](https://github.com/jeanduplessis/argus/commit/f0111ab))

## 2026-08-11

- Git status and preview commands no longer leave the test run waiting after git has exited, so release verification can finish. ([b2479f0](https://github.com/jeanduplessis/argus/commit/b2479f0))
- Restored terminal tabs now fill the window width on launch. They previously stayed at Ghostty's default column count until the window was resized. ([a50fea6](https://github.com/jeanduplessis/argus/commit/a50fea6))
- Closing a terminal tab, pane, workspace, or the app now asks first when a process is still running, so an accidental close does not kill it. ([9d37bae](https://github.com/jeanduplessis/argus/commit/9d37bae))

## 2026-08-10

- Pasting an image with Cmd+V in a terminal now reaches the running program instead of inserting a blank space, so agents like Pi and Kilo pick up the image from the clipboard. Cmd+V previously sent the keystroke through the paste path, which replaces control characters with a space. ([4b5e825](https://github.com/jeanduplessis/argus/commit/4b5e825))
- The Changes panel now hides the Staged, Unstaged, and Untracked sections when they have no files in them, and shows a centered "Working tree clean" message when there is nothing to commit. ([d791ae1](https://github.com/jeanduplessis/argus/commit/d791ae1))
- The selected workspace in the left sidebar is now marked with a leading accent bar and a light row tint, instead of filling the whole row with solid blue, so workspace names stay easy to read. ([3e6ea37](https://github.com/jeanduplessis/argus/commit/3e6ea37))
- Previously installed Argus Pi extensions now upgrade safely to the current Agent Status and turn-completion extension, and can be removed without touching unrelated extensions. ([37992fd](https://github.com/jeanduplessis/argus/commit/37992fd))

## 2026-08-09

- Users can keep an Empty Workspace open after closing its final Terminal Tab, restore it without terminal panels, and create a new Terminal Tab from its empty state. ([e3fe82f](https://github.com/jeanduplessis/argus/commit/e3fe82f))

- The Changes View can now combine working changes and show committed changes against the base branch, with independent settings and read-only previews. ([9b58e1c](https://github.com/jeanduplessis/argus/commit/9b58e1c))

- Named Projects can now create a Worktree Workspace from a GitHub Pull Request URL or number, including fork Pull Requests, through the active GitHub CLI context. ([938826e](https://github.com/jeanduplessis/argus/commit/938826e))

## 2026-08-08

- Completed Pi agent turns now mark the affected Top-level Tab and Workspace as needing attention until viewed. ([5c155e9](https://github.com/jeanduplessis/argus/commit/5c155e9))

## 2026-08-07

- The test suite now uses isolated fixtures, deterministic behavior assertions, structured protocol checks, and reliable cleanup across Git, socket, browser, session, and worktree workflows. ([08e4a92](https://github.com/jeanduplessis/argus/commit/08e4a92))
- Double-clicking a file in the Changes View now opens its diff in a Git Preview Tab. ([d0fec1f](https://github.com/jeanduplessis/argus/commit/d0fec1f))

## 2026-08-06

- Settings toolbar symbols are restored, and concurrent Git command output is drained without starving branch and worktree operations. ([2aa2d43](https://github.com/jeanduplessis/argus/commit/2aa2d43))
- Help > Release Notes now opens the bundled changelog in a reusable Release Notes Tab in the Selected Workspace. ([2aa2d43](https://github.com/jeanduplessis/argus/commit/2aa2d43))
- Pi can now report live Agent Status through the app-owned socket, with explicit integration controls in Settings and ordered, ephemeral status updates. ([0146419](https://github.com/jeanduplessis/argus/commit/0146419))
- Standalone Workspace roots now support direct path entry, and committed Workspace names and roots are saved immediately. Workspace closing, worktree deletion, and destructive Files and Changes actions now use clearer in-view confirmations. ([0146419](https://github.com/jeanduplessis/argus/commit/0146419))
- The Changes View can add untracked files and displayed directories to `.gitignore`. Settings, icons, and terminal cleanup were also hardened against macOS 27 crashes. ([5474ae3](https://github.com/jeanduplessis/argus/commit/5474ae3), [0146419](https://github.com/jeanduplessis/argus/commit/0146419))

## 2026-07-30

- Terminal tabs now let Kilo and other terminal programs paste images from the system clipboard with Cmd+V. Text paste and modified paste shortcuts keep their existing behavior. ([557e8b9](https://github.com/jeanduplessis/argus/commit/557e8b9))

## 2026-07-28

- Standalone workspace rows now show their Workspace Root beneath the name, with the home directory abbreviated as `~`. ([4d36a31](https://github.com/jeanduplessis/argus/commit/4d36a31))

## 2026-07-27

- Argus now opens on macOS 27 with visible icons and working terminal sessions. The formatter configuration also supports the Xcode 27 toolchain. ([96b141f](https://github.com/jeanduplessis/argus/commit/96b141f))

## 2026-07-25

- Releases now use one version manifest and bounded verification stages that retain diagnostics, validate the built app and Companion CLI, and stop timed-out or interrupted command groups. Concurrent Git commands no longer leave the test run waiting after the processes have exited. ([cb1b68a](https://github.com/jeanduplessis/argus/commit/cb1b68a))
- Standalone workspaces can now choose their working directory from the workspace context menu. Files, changes, and new terminal tabs use the selected directory while existing terminal sessions remain unchanged. ([f368d2c](https://github.com/jeanduplessis/argus/commit/f368d2c))
- Files and folders can now copy their path relative to the Workspace Root from the Files View context menu. ([1533541](https://github.com/jeanduplessis/argus/commit/1533541))
- Argus now shows and sounds an alert when a Kilo turn finishes outside the active tab, with explicit Kilo integration controls in Settings. ([3e55ea4](https://github.com/jeanduplessis/argus/commit/3e55ea4))

## 2026-07-24

- Swift source and tests now pass the repository's lint rules without force casts or oversized type, function, and file bodies. ([928faf9](https://github.com/jeanduplessis/argus/commit/928faf9))

## 2026-07-23

- Repository documentation now describes the current v1 application, separates stable behavior, proposals, operations, and architecture decisions, and records the structured diff renderer as an ADR. GhosttyKit setup now validates build inputs, coordinates shared cache access, publishes complete artifacts safely, and handles chained SDK and Metal toolchain recovery. ([e4eb23e](https://github.com/jeanduplessis/argus/commit/e4eb23e))

## 2026-07-22

- Closing the last terminal tab now asks whether to close the workspace. Choosing "Keep Terminal" leaves the terminal tab open and active. ([5491b19](https://github.com/jeanduplessis/argus/commit/5491b19))
- The New Workspace sheet now suggests a random, collision-checked branch name (e.g. "brave-otter") with a shuffle button to regenerate it, a settings-configurable branch prefix, and an optional workspace display name. ([3d45d2d](https://github.com/jeanduplessis/argus/commit/3d45d2d))
