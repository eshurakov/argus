import AppKit
import Foundation

struct WorkspaceFileTreeEntry: Equatable, Sendable {
    let path: String
    let isDirectory: Bool
}

enum WorkspaceFileIcon {
    private static let packageFileNames: Set<String> = [
        "cargo.lock", "cargo.toml", "composer.json", "gemfile", "gemfile.lock", "go.mod", "go.sum",
        "package-lock.json", "package.json", "package.swift", "pnpm-lock.yaml", "podfile", "podfile.lock",
        "pyproject.toml", "requirements.txt", "yarn.lock"
    ]
    private static let textFileNames: Set<String> = [
        "authors", "changelog", "contributing", "copying", "license", "notice", "readme"
    ]
    private static let configurationFileNames: Set<String> = [
        ".editorconfig", ".gitattributes", ".gitignore", ".gitmodules"
    ]
    private static let extensionGroups: [(symbolName: String, extensions: Set<String>)] = [
        (
            "chevron.left.forwardslash.chevron.right",
            [
                "swift", "c", "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "hxx", "cs", "css", "scss",
                "sass", "less", "dart", "erl", "ex", "exs", "fs", "fsx", "go", "hrl", "html", "htm",
                "java", "js", "jsx", "mjs", "cjs", "kt", "kts", "lua", "php", "py", "pyw", "rb", "rs",
                "scala", "sol", "svelte", "ts", "tsx", "vb", "vue", "xhtml", "zig"
            ]
        ),
        ("terminal", ["sh", "bash", "zsh", "fish", "command", "bat", "cmd", "ps1"]),
        ("doc.text", ["txt", "md", "markdown", "rtf", "textile", "adoc"]),
        ("gearshape", ["env", "ini", "cfg", "conf", "config", "toml", "properties", "xcconfig"]),
        ("curlybraces", ["json", "jsonc", "yaml", "yml", "xml", "plist"]),
        ("tablecells", ["csv", "tsv", "sql", "sqlite", "db"]),
        ("photo", ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "ico", "svg"]),
        ("waveform", ["mp3", "wav", "aiff", "aif", "m4a", "aac", "flac", "ogg"]),
        ("film", ["mov", "mp4", "m4v", "avi", "mkv", "webm"]),
        ("archivebox", ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]),
        ("doc.richtext", ["pdf", "doc", "docx", "pages", "odt"])
    ]

    static func systemName(for fileName: String) -> String {
        let name = (fileName as NSString).lastPathComponent.lowercased()
        let fileExtension = (name as NSString).pathExtension

        if packageFileNames.contains(name) || name == "dockerfile" || name.hasPrefix("dockerfile.") {
            return "shippingbox"
        }
        if textFileNames.contains(name) {
            return "doc.text"
        }
        if configurationFileNames.contains(name) || name == ".env" || name.hasPrefix(".env.") {
            return "gearshape"
        }
        if name == "makefile" || name.hasPrefix("makefile.") {
            return "terminal"
        }
        return extensionGroups.first(where: { $0.extensions.contains(fileExtension) })?.symbolName ?? "doc"
    }
}

struct WorkspaceFileTreeRequest: Hashable, Sendable {
    let workspaceId: UUID
    let rootPath: String
    let showHiddenFiles: Bool

    init(workspaceId: UUID, rootPath: String, showHiddenFiles: Bool = true) {
        self.workspaceId = workspaceId
        self.rootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        self.showHiddenFiles = showHiddenFiles
    }
}

struct WorkspaceFileTreeNode: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case directory(children: [WorkspaceFileTreeNode])
        case file
    }

    let id: String
    let name: String
    let path: String
    let content: Content

    var children: [WorkspaceFileTreeNode] {
        guard case .directory(let children) = content else { return [] }
        return children
    }

    var idPrefix: String {
        switch content {
        case .directory:
            return "directory"
        case .file:
            return "file"
        }
    }

    func replacingChildren(_ children: [WorkspaceFileTreeNode]) -> WorkspaceFileTreeNode {
        guard case .directory = content else { return self }
        return WorkspaceFileTreeNode(
            id: id,
            name: name,
            path: path,
            content: .directory(children: children)
        )
    }
}

struct WorkspaceFileTreeRow: Identifiable, Equatable {
    enum Content: Equatable {
        case directory(WorkspaceFileTreeNode)
        case file(WorkspaceFileTreeNode)
    }

    let id: String
    let name: String
    let depth: Int
    let content: Content
}

struct WorkspaceFileTreeSnapshot: Equatable, Sendable {
    static let displayedEntryLimit = 2_500

    let request: WorkspaceFileTreeRequest?
    let rootPath: String
    let nodes: [WorkspaceFileTreeNode]
    let fileCount: Int
    let directoryCount: Int
    let totalEntryCount: Int
    let omittedEntryCount: Int
    let isCapped: Bool
    let loadedDirectoryPaths: Set<String>

    init(
        request: WorkspaceFileTreeRequest? = nil,
        rootPath: String,
        nodes: [WorkspaceFileTreeNode],
        fileCount: Int,
        directoryCount: Int,
        totalEntryCount: Int? = nil,
        omittedEntryCount: Int = 0,
        isCapped: Bool,
        loadedDirectoryPaths: Set<String>
    ) {
        self.request = request
        self.rootPath = rootPath
        self.nodes = nodes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.totalEntryCount = totalEntryCount ?? fileCount + directoryCount + omittedEntryCount
        self.omittedEntryCount = omittedEntryCount
        self.isCapped = isCapped
        self.loadedDirectoryPaths = loadedDirectoryPaths
    }

    var displayedEntryCount: Int { fileCount + directoryCount }
}

struct WorkspaceFileTreeDirectorySnapshot: Equatable, Sendable {
    let rootPath: String
    let directoryPath: String
    let nodes: [WorkspaceFileTreeNode]
    let totalEntryCount: Int
    let omittedEntryCount: Int
    let isCapped: Bool

    init(
        rootPath: String,
        directoryPath: String,
        nodes: [WorkspaceFileTreeNode],
        totalEntryCount: Int? = nil,
        omittedEntryCount: Int = 0,
        isCapped: Bool
    ) {
        let counts = WorkspaceFileTree.countEntries(nodes: nodes)
        self.rootPath = rootPath
        self.directoryPath = directoryPath
        self.nodes = nodes
        self.totalEntryCount = totalEntryCount ?? counts.files + counts.directories + omittedEntryCount
        self.omittedEntryCount = omittedEntryCount
        self.isCapped = isCapped
    }
}

struct WorkspaceFileTreeDirectoryError: Equatable, Sendable {
    let path: String
    let message: String
}

@MainActor
protocol WorkspaceRelativePathCopying: AnyObject {
    func copyRelativePath(_ path: String)
}

@MainActor
final class PasteboardWorkspaceRelativePathClipboard: WorkspaceRelativePathCopying {
    func copyRelativePath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}

enum WorkspaceFileTreeLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded(WorkspaceFileTreeSnapshot)
    case missingDirectory(path: String)
    case error(path: String, message: String)
}

enum WorkspaceFileTreeDirectoryLoadState: Equatable, Sendable {
    case loaded(WorkspaceFileTreeDirectorySnapshot)
    case missingDirectory(path: String)
    case error(path: String, message: String)
}

enum WorkspaceFileOperationError: LocalizedError {
    case invalidPath
    case fileNotFound
    case invalidName

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "The file path is outside the workspace."
        case .fileNotFound:
            return "The item does not exist."
        case .invalidName:
            return "Enter a valid file name."
        }
    }
}

@MainActor
protocol WorkspaceFileOperating: AnyObject {
    func copyFile(rootPath: String, path: String) throws
    func deleteFile(rootPath: String, path: String) async throws
    func renameFile(rootPath: String, path: String, newName: String) async throws -> String
}

@MainActor
final class FileManagerWorkspaceFileOperator: WorkspaceFileOperating {
    func copyFile(rootPath: String, path: String) throws {
        let url = try Self.resolvedItemURL(rootPath: rootPath, path: path)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.path, forType: .string)
    }

    func deleteFile(rootPath: String, path: String) async throws {
        let url = try Self.resolvedItemURL(rootPath: rootPath, path: path)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.removeItem(at: url)
        }.value
    }

    func renameFile(rootPath: String, path: String, newName: String) async throws -> String {
        let sourceURL = try Self.resolvedItemURL(rootPath: rootPath, path: path)
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
            !trimmedName.contains("/"),
            trimmedName != ".",
            trimmedName != ".."
        else {
            throw WorkspaceFileOperationError.invalidName
        }

        let parentPath = (path as NSString).deletingLastPathComponent
        let newRelativePath =
            parentPath.isEmpty || parentPath == "."
            ? trimmedName
            : "\(parentPath)/\(trimmedName)"
        let destinationURL = try Self.resolvedDestinationURL(
            rootPath: rootPath,
            path: newRelativePath
        )

        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }.value
        return newRelativePath
    }

    private static func resolvedItemURL(rootPath: String, path: String) throws -> URL {
        let url = try resolvedDestinationURL(rootPath: rootPath, path: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkspaceFileOperationError.fileNotFound
        }
        return url
    }

    private static func resolvedDestinationURL(rootPath: String, path: String) throws -> URL {
        guard !path.isEmpty else { throw WorkspaceFileOperationError.invalidPath }
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
        let targetURL =
            rootURL
            .appendingPathComponent(path, isDirectory: false)
            .standardizedFileURL
        let rootPathWithSlash = rootURL.path.hasSuffix("/") ? rootURL.path : "\(rootURL.path)/"
        guard targetURL.path.hasPrefix(rootPathWithSlash) else {
            throw WorkspaceFileOperationError.invalidPath
        }
        return targetURL
    }
}

@MainActor
protocol WorkspaceFileOperationPrompting: AnyObject {
    func promptRename(currentName: String) -> String?
    func showFailure(title: String, message: String)
}

@MainActor
final class AlertWorkspaceFileOperationPrompter: WorkspaceFileOperationPrompting {
    func promptRename(currentName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename Item"
        alert.informativeText = "Enter a new file name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(string: currentName)
        textField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let renamed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return renamed.isEmpty ? nil : renamed
    }

    func showFailure(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
