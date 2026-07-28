import Foundation

/// Formats Workspace Roots for compact presentation without losing their
/// filesystem identity.
enum WorkspacePathFormatter {
    static func abbreviatedPath(
        _ path: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let standardizedHome = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path

        if standardizedPath == standardizedHome {
            return "~"
        }

        let homePrefix = standardizedHome.hasSuffix("/") ? standardizedHome : "\(standardizedHome)/"
        guard standardizedPath.hasPrefix(homePrefix) else { return standardizedPath }
        return "~/\(standardizedPath.dropFirst(homePrefix.count))"
    }
}

/// Git metadata shown alongside the active workspace title.
struct TitlebarGitContext: Equatable, Sendable {
    let visibleText: String
    let windowTitleText: String
}

/// Formats shared git status state for the custom titlebar and window title.
enum TitlebarGitContextFormatter {
    static func context(from state: GitStatusLoadState) -> TitlebarGitContext? {
        guard case .loaded(let summary) = state else { return nil }

        var visibleParts: [String] = []
        var windowTitleParts: [String] = []
        let branchName = summary.branchName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let branchName, !branchName.isEmpty {
            visibleParts.append(branchName)
            windowTitleParts.append(branchName)
        }

        if !summary.isClean {
            visibleParts.append("•")
            windowTitleParts.append("dirty")
        }

        if summary.upstreamName != nil {
            visibleParts.append("↑\(summary.aheadCount)")
            visibleParts.append("↓\(summary.behindCount)")
            windowTitleParts.append("ahead \(summary.aheadCount)")
            windowTitleParts.append("behind \(summary.behindCount)")
        }

        guard !visibleParts.isEmpty else { return nil }
        return TitlebarGitContext(
            visibleText: visibleParts.joined(separator: " "),
            windowTitleText: windowTitleParts.joined(separator: " ")
        )
    }
}

/// Formats the active workspace context shown in the custom titlebar and
/// underlying `NSWindow.title`.
enum WorkspaceTitleFormatter {
    static let fallbackTitle = "Argus"

    static func title(workspaceTitle: String, contextName: String?) -> String {
        title(workspaceTitle: workspaceTitle, contextName: contextName, gitContext: nil)
    }

    static func title(workspaceTitle: String, contextName: String?, gitContext: String?) -> String {
        let workspace = normalized(workspaceTitle)
        let context = normalized(contextName ?? "")
        let baseTitle: String

        switch (workspace.isEmpty, context.isEmpty) {
        case (true, true):
            baseTitle = fallbackTitle
        case (true, false):
            baseTitle = context
        case (false, true):
            baseTitle = workspace
        case (false, false) where workspace.localizedCaseInsensitiveCompare(context) == .orderedSame:
            baseTitle = context
        case (false, false):
            baseTitle = "\(workspace) — \(context)"
        }

        let gitContext = normalized(gitContext ?? "")
        return gitContext.isEmpty ? baseTitle : "\(baseTitle) — \(gitContext)"
    }

    static func contextName(projectName: String?, directoryPath: String) -> String {
        if let projectName = projectName, !normalized(projectName).isEmpty {
            return normalized(projectName)
        }

        let basename = URL(fileURLWithPath: directoryPath).lastPathComponent
        return normalized(basename)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
