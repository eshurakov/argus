import AppKit
import Foundation

/// Type of panel content.
public enum PanelType: String, Codable, Sendable {
    case terminal
    case browser
    case file
    case releaseNotes
    case gitPreview
}

/// Protocol for all panel types.
///
/// Each panel appears as a tab within a workspace. The protocol is
/// `@MainActor` because panel state drives SwiftUI views. Conformers must be
/// classes (`AnyObject`) so workspaces can hold them by reference.
@MainActor
public protocol Panel: AnyObject, Identifiable, ObservableObject where ID == UUID {
    var id: UUID { get }
    var panelType: PanelType { get }
    var displayTitle: String { get }
    var displayIcon: String? { get }
    var isDirty: Bool { get }
    var isLoading: Bool { get }

    /// Tear down the panel's resources and release its surface.
    func close()
    /// Mark this panel as the focused (active) panel.
    func focus()
    /// Remove focus from this panel.
    func unfocus()
}

extension Panel {
    public var displayIcon: String? { nil }
    public var isDirty: Bool { false }
    public var isLoading: Bool { false }
}

/// Lightweight panel for a file opened from the Files sidebar.
///
/// File tabs are runtime UI state only. They are not currently included in
/// session snapshots, which still restore terminal panels only.
@MainActor
final class FilePanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .file

    @Published private(set) var rootPath: String
    @Published private(set) var relativePath: String

    init(
        id: UUID = UUID(),
        rootPath: String,
        relativePath: String
    ) {
        self.id = id
        self.rootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        self.relativePath = relativePath
    }

    var displayTitle: String {
        let name = (relativePath as NSString).lastPathComponent
        return name.isEmpty ? "File" : name
    }

    var displayIcon: String? { "doc.text" }

    var fileURL: URL {
        URL(fileURLWithPath: rootPath)
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
    }

    func updatePath(rootPath: String, relativePath: String) {
        self.rootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        self.relativePath = relativePath
    }

    func close() {}
    func focus() {}
    func unfocus() {}
}

/// Runtime-only application release notes opened from the Help menu.
@MainActor
final class ReleaseNotesPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .releaseNotes
    let displayTitle = "Release Notes"
    let displayIcon: String? = "doc.text"

    init(id: UUID = UUID()) {
        self.id = id
    }

    func close() {}
    func focus() {}
    func unfocus() {}
}

/// Runtime-only diff or blame preview opened from the Changes sidebar.
@MainActor
final class GitPreviewPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .gitPreview
    let rootPath: String

    @Published private(set) var preview: GitPreview

    init(
        id: UUID = UUID(),
        rootPath: String,
        preview: GitPreview
    ) {
        self.id = id
        self.rootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        self.preview = preview
    }

    var displayTitle: String {
        let name = (preview.path as NSString).lastPathComponent
        let path = name.isEmpty ? preview.path : name
        switch preview.kind {
        case .diff:
            return "Diff: \(path)"
        case .blame:
            return "Blame: \(path)"
        }
    }

    var displayIcon: String? {
        switch preview.kind {
        case .diff:
            return "doc.text.magnifyingglass"
        case .blame:
            return "person.line.dotted.person"
        }
    }

    func update(preview: GitPreview) {
        self.preview = preview
    }

    func close() {}
    func focus() {}
    func unfocus() {}
}
