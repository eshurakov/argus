import Foundation

struct GitPreviewCommand: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let successfulExitCodes: Set<Int32>
}

enum GitPreviewKind: Equatable, Sendable {
    case diff
    case blame
}

enum GitPreviewContent: Equatable, Sendable {
    case diff(GitDiffPreview)
    case ansiText(String)
}

struct GitDiffPreview: Equatable, Sendable {
    let fileName: String
    let oldContent: String
    let newContent: String
}

struct GitPreview: Equatable, Sendable {
    let kind: GitPreviewKind
    let path: String
    let comparison: GitDiffSource
    let content: GitPreviewContent

    init(
        kind: GitPreviewKind,
        path: String,
        comparison: GitDiffSource = .unstaged,
        content: GitPreviewContent
    ) {
        self.kind = kind
        self.path = path
        self.comparison = comparison
        self.content = content
    }
}

enum GitPreviewLoadState: Equatable, Sendable {
    case loaded(GitPreview)
    case failed(kind: GitPreviewKind, path: String, comparison: GitDiffSource, message: String)
}

protocol GitPreviewProviding: Sendable {
    func preview(kind: GitPreviewKind, rootPath: String, file: GitFileChange) async -> GitPreviewLoadState
}
