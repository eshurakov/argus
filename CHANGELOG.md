# Changelog

This file records changes pushed for local Argus releases. New entries use a `YYYY-MM-DD` heading and link to their commit or commits.

## 2026-07-25

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
