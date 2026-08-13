# Changelog

This file records changes pushed for local Argus releases. New entries use a `YYYY-MM-DD` heading and link to their commit or commits.

## 2026-08-13

- Quitting Argus now names the Project and Workspace that still have a running process, so you can find that terminal without guessing.
- The left sidebar now treats Workspaces as a top-level section like Projects. Its plus button creates a standalone Workspace, the Projects plus button only creates a Project, standalone Workspace icons no longer show a question mark, and Workspace paths are lighter so the title stands out.
- Workspace rows now show how many terminals still have a running process, instead of how many tabs are open. The badge hides when nothing is running.

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

- Users can keep an Empty Workspace open after closing its final Terminal Tab, restore it without terminal panels, and create a new Terminal Tab from its empty state. ([e3fe82f](https://github.com/eshurakov/argus/commit/e3fe82f))

- The Changes View can now combine working changes and show committed changes against the base branch, with independent settings and read-only previews. ([48c6964](https://github.com/jeanduplessis/argus/commit/48c6964))

- Named Projects can now create a Worktree Workspace from a GitHub Pull Request URL or number, including fork Pull Requests, through the active GitHub CLI context. ([d447f6a](https://github.com/jeanduplessis/argus/commit/d447f6a))

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
