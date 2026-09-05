import Foundation

/// Environment Argus injects into every spawned shell.
///
/// Kept separate from `TerminalSurface` so the contract can be verified
/// without a Ghostty surface.
///
/// Ghostty applies caller-supplied variables *after* its own environment
/// work, including the application binary directory it appends to `PATH`. A
/// `PATH` value here therefore replaces Ghostty's, so it is composed from the
/// inherited value plus both directories rather than from the bundled tools
/// directory alone.
enum TerminalEnvironment {
    static let socketPathKey = "ARGUS_SOCKET_PATH"
    static let workspaceIdKey = "ARGUS_WORKSPACE_ID"
    static let surfaceIdKey = "ARGUS_SURFACE_ID"
    static let pathKey = "PATH"

    /// Name of the bundled tools directory inside the application bundle's
    /// resources, and the Companion CLI it holds.
    static let bundledToolsDirectoryName = "bin"
    static let companionCLIName = "argus"

    static func variables(
        socketPath: String,
        workspaceId: UUID,
        surfaceId: UUID,
        bundledToolsDirectory: String?,
        inheritedPath: String?,
        applicationBinaryDirectory: String? = nil,
        additional: [String: String] = [:]
    ) -> [String: String] {
        var environment: [String: String] = [
            socketPathKey: socketPath,
            workspaceIdKey: workspaceId.uuidString,
            surfaceIdKey: surfaceId.uuidString
        ]
        if let path = searchPath(
            bundledToolsDirectory: bundledToolsDirectory,
            inheritedPath: inheritedPath,
            applicationBinaryDirectory: applicationBinaryDirectory
        ) {
            environment[pathKey] = path
        }
        // Caller-provided values are overrides and win deliberately.
        for (key, value) in additional {
            environment[key] = value
        }
        return environment
    }

    /// Bundled tools directory, but only when it actually holds the Companion
    /// CLI. A build that skipped CLI bundling MUST NOT change `PATH`.
    static func bundledToolsDirectory(
        resourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> String? {
        guard let resourceURL else { return nil }
        let directory = resourceURL.appendingPathComponent(bundledToolsDirectoryName, isDirectory: true)
        let executable = directory.appendingPathComponent(companionCLIName)
        guard fileManager.isExecutableFile(atPath: executable.path) else { return nil }
        return directory.standardizedFileURL.path
    }

    /// Directory holding the running application executable, which Ghostty
    /// appends to a spawned shell's `PATH`.
    static func applicationBinaryDirectory(
        executableURL: URL? = Bundle.main.executableURL
    ) -> String? {
        executableURL?.deletingLastPathComponent().standardizedFileURL.path
    }

    /// Puts the bundled tools directory first so `argus` resolves by name in an
    /// Argus terminal, keeps every inherited entry, and re-appends the
    /// application binary directory that Ghostty's own `PATH` work adds — this
    /// value replaces Ghostty's, so dropping it would remove that directory.
    ///
    /// Returns `nil` when there is nothing to add, leaving Ghostty's `PATH`
    /// untouched.
    private static func searchPath(
        bundledToolsDirectory: String?,
        inheritedPath: String?,
        applicationBinaryDirectory: String?
    ) -> String? {
        guard let tools = nonEmpty(bundledToolsDirectory) else { return nil }
        let inherited =
            nonEmpty(inheritedPath)?
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init) ?? []
        var seen: Set<String> = []
        var ordered: [String] = []
        // An empty entry means the current directory. Adding to an inherited
        // search path must not quietly rewrite what it already meant.
        for entry in [tools] + inherited + [applicationBinaryDirectory].compactMap(nonEmpty)
        where entry.isEmpty || seen.insert(entry).inserted {
            ordered.append(entry)
        }
        return ordered.joined(separator: ":")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
