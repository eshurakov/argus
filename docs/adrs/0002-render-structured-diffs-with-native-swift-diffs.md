# ADR 0002: Render structured diffs with native Swift Diffs

- Status: Accepted
- Date: 2026-08-14

## Context

Git Preview Tabs still need syntax-aware split and unified diff rendering inside
the normal Workspace tab lifecycle. ADR 0001 solved that with an Argus-owned
WebKit bridge around `@pierre/diffs`. That kept Node.js out of application
builds, but it also introduced a committed JavaScript bundle, a per-preview
`WKWebView`, and a non-native selection and scrolling surface.

`SwiftDiffs` 1.0.0 is a native macOS package with a SwiftUI `DiffView`, AppKit
and TextKit 2 rendering, and no third-party runtime dependencies. It requires
macOS 26. Argus now accepts that deployment floor. The package does not expose
soft wrapping or a host-controlled document font size.

## Decision

Argus renders structured diffs with `SwiftDiffs`.

- `GitPreviewService` continues to resolve old and new file content from Git
  objects, the index, or the working tree according to the `GitFileChange` and
  Change Section.
- Argus maps that content to `SwiftDiffs.DiffInput.files` and keeps Split and
  Unified layout plus light or dark appearance at the Argus boundary.
- Structured diffs use the package's collapsible context policy and horizontal
  scrolling. Diff overflow settings and wrap controls are removed.
- Blame previews continue to use ANSI text.
- Browser Panels continue to use WebKit. Diff rendering no longer depends on
  WebKit, Node.js, or a committed JavaScript bundle.

## Consequences

- Application builds require macOS 26 and resolve `SwiftDiffs` as a Swift
  package dependency.
- Native text selection, copying, scrolling, and accessibility replace the
  previous WebKit bridge behavior.
- Document text size no longer changes structured-diff typography until
  `SwiftDiffs` exposes a host font-size option.
- Binary, non-UTF-8, oversized, or otherwise unsupported content still uses a
  recoverable ANSI-text result instead of entering the renderer.
- Review comments, inline annotations, editing, and multi-file review workflows
  remain outside this renderer's responsibility.

## References

- `docs/SPEC.md`
- `docs/DEVELOPMENT.md`
- `Argus/DiffRendering/`
- `Argus/Services/GitPreviewService.swift`
- `Tests/GitStatusTests/ArgusDiffRenderingTests.swift`
- `Tests/GitStatusTests/GitPreviewServiceTests.swift`
- https://github.com/jeanduplessis/swift-diffs
