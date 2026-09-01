import Foundation

struct GitMetadataWatchPaths {
    let rootPath: String
    let gitDirectory: String
    let commonDirectory: String

    init(rootPath: String) {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let checkoutURL = rootURL.resolvingSymlinksInPath()
        let dotGitURL = checkoutURL.appendingPathComponent(".git", isDirectory: true)
        var gitURL = dotGitURL
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue
        {
            if let record = Self.pathFileRecord(at: dotGitURL), record.hasPrefix("gitdir: "),
                let directory = Self.directoryURL(String(record.dropFirst("gitdir: ".count)), relativeTo: checkoutURL)
            {
                gitURL = directory
            }
        }
        gitURL = gitURL.resolvingSymlinksInPath().standardizedFileURL
        let commonURL =
            Self.pathFileRecord(at: gitURL.appendingPathComponent("commondir"))
            .flatMap { Self.directoryURL($0, relativeTo: gitURL) } ?? gitURL
        self.rootPath = rootURL.path
        gitDirectory = gitURL.resolvingSymlinksInPath().standardizedFileURL.path
        commonDirectory = commonURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    var watchedPaths: [String] {
        var paths = [rootPath]
        for directory in [commonDirectory, gitDirectory] {
            if !paths.contains(where: { GitMetadataEventPath.relativePath(directory, in: $0) != nil }) {
                paths.append(directory)
            }
        }
        return paths
    }

    func relativeMetadataPaths(for path: String) -> [String] {
        [commonDirectory, gitDirectory, URL(fileURLWithPath: rootPath).appendingPathComponent(".git").path]
            .compactMap { GitMetadataEventPath.relativePath(path, in: $0) }
    }

    private static func directoryURL(_ path: String, relativeTo base: URL) -> URL? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true, relativeTo: base).standardizedFileURL
    }

    private static func pathFileRecord(at url: URL) -> String? {
        let resolvedURL = url.resolvingSymlinksInPath()
        let maximumBytes = 4_096
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes,
            let handle = try? FileHandle(forReadingFrom: resolvedURL)
        else { return nil }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else { return nil }
        if data.last == UInt8(ascii: "\n") {
            data.removeLast()
            if data.last == UInt8(ascii: "\r") { data.removeLast() }
        }
        return String(data: data, encoding: .utf8)
    }
}

enum GitMetadataEventPath {
    static func relativePath(_ path: String, in directory: String) -> String? {
        let canonicalEventPath = canonicalPath(path)
        let canonicalDirectory = canonicalPath(directory)
        if canonicalEventPath == canonicalDirectory { return "" }
        let prefix = canonicalDirectory.hasSuffix("/") ? canonicalDirectory : canonicalDirectory + "/"
        guard canonicalEventPath.hasPrefix(prefix) else { return nil }
        return String(canonicalEventPath.dropFirst(prefix.count))
    }

    static func isRelevant(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/")
        if components.first == "worktrees" {
            if components.count <= 2 { return true }
            return isMetadataPath(Array(components.dropFirst(2)))
        }
        return isMetadataPath(components)
    }

    private static func canonicalPath(_ path: String) -> String {
        var ancestor = URL(fileURLWithPath: path)
        var missingComponents: [String] = []
        while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
            missingComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() { resolved.appendPathComponent(component) }
        return resolved.path
    }

    private static func isMetadataPath(_ components: [Substring]) -> Bool {
        guard let first = components.first, components.last?.hasSuffix(".lock") != true else { return false }
        if components.count == 1 {
            return [
                "HEAD", "config", "config.worktree", "gh-stack", "packed-refs", "gitdir", "commondir", "locked", "refs"
            ]
            .contains(first)
        }
        if first == "refs" { return isReferencePath(components) }
        if first == "logs" {
            let loggedPath = Array(components.dropFirst())
            return loggedPath == ["HEAD"] || isReferencePath(loggedPath)
        }
        return false
    }

    private static func isReferencePath(_ components: [Substring]) -> Bool {
        guard components.first == "refs" else { return false }
        if components.count == 1 { return true }
        return ["heads", "branch-metadata", "remotes"].contains(components[1])
    }
}
