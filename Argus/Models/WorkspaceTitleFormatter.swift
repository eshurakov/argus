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

/// Formats the active workspace context shown in the custom titlebar and
/// underlying `NSWindow.title`.
enum WorkspaceTitleFormatter {
    static let fallbackTitle = "Argus"

    static func title(workspaceTitle: String, contextName: String?) -> String {
        let workspace = normalized(workspaceTitle)
        let context = normalized(contextName ?? "")

        switch (workspace.isEmpty, context.isEmpty) {
        case (true, true):
            return fallbackTitle
        case (true, false):
            return context
        case (false, true):
            return workspace
        case (false, false) where workspace.localizedCaseInsensitiveCompare(context) == .orderedSame:
            return context
        case (false, false):
            return "\(workspace) — \(context)"
        }
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
