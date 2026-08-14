# ADR 0001: Render structured diffs with an Argus-owned WebKit bridge

- Status: Superseded by `0002-render-structured-diffs-with-native-swift-diffs.md`
- Date: 2026-07-09

## Context

Git Preview Tabs need syntax-aware split and unified diff rendering. The renderer
must fit the native SwiftUI application, preserve the normal Workspace tab
lifecycle, and keep Node.js and network access out of application builds and
runtime.

The `@pierre/diffs` package provides the required browser renderer. Depending on
`PierreDiffsSwift` would expose another package's Swift API and ownership model
inside Argus. Rendering terminal-oriented diff output would also discard the
structured old and new file content needed by the browser renderer.

## Decision

Argus renders structured diffs with `@pierre/diffs` through an Argus-owned
`WKWebView` bridge.

- `GitPreviewService` resolves old and new file content from Git objects, the
  index, or the working tree according to the `GitFileChange` and Change Section.
- Argus owns the Swift input types, HTML template, WebKit coordinator, JavaScript
  bridge contract, and renderer lifecycle.
- The JavaScript entry uses the vanilla `@pierre/diffs` API. Argus does not
  depend on `PierreDiffsSwift` or React.
- `ArgusWeb` is a build-time asset package. Its pinned dependencies produce the
  committed `Argus/Resources/pierre-diffs-bundle.js` file.
- Normal Xcode builds and application runtime use the committed bundle and do
  not require Node.js, npm, network access, or JavaScript package installation.
- Diff previews use structured old and new text. Blame previews continue to use
  ANSI text.
- Rendering remains separate from Git extraction, Git Mutations, diff
  statistics, and Top-level Tab ownership.

The public boundary remains narrow. Renderer options are added only when an
Argus interface requires them.

## Consequences

- Argus can change rendering libraries without changing Git Preview domain
  models or exposing third-party Swift types.
- Generated bundle changes must be committed with their source or dependency
  changes so application builds remain self-contained.
- The WebKit bridge needs focused tests for input encoding, readiness, updates,
  errors, and cleanup.
- Git content extraction needs status-specific tests because incorrect old or
  new content can produce a plausible but wrong diff.
- Binary, non-UTF-8, oversized, or otherwise unsupported content must use a
  recoverable text result instead of entering the renderer.
- Review comments, inline annotations, editing, and multi-file review workflows
  are outside this renderer's responsibility.

## References

- `docs/SPEC.md`
- `docs/DEVELOPMENT.md`
- `Argus/DiffRendering/`
- `Argus/Services/GitPreviewService.swift`
- `ArgusWeb/`
- `Tests/GitStatusTests/ArgusDiffRenderingTests.swift`
- `Tests/GitStatusTests/GitPreviewServiceTests.swift`
