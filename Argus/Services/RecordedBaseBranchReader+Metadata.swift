import Foundation

extension RecordedBaseBranchReader {
    func readGhStack(commonDirectory: URL, records: inout Records) throws {
        try readGhStackFile(at: commonDirectory.appendingPathComponent("gh-stack"), records: &records)
        let administrativeRoot = commonDirectory.appendingPathComponent("worktrees", isDirectory: true)
        let directories: [URL]
        do {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: administrativeRoot.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw RecordedBaseBranchReadError.stackUnreadable
            }
            directories = try FileManager.default.contentsOfDirectory(
                at: administrativeRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !Self.isMissingFile(error) { records.diagnose(error, fallback: .stackUnreadable) }
            return
        }
        for directory in directories.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true {
                    try readGhStackFile(at: directory.appendingPathComponent("gh-stack"), records: &records)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                records.diagnose(error, fallback: .stackUnreadable)
            }
        }
    }

    private func readGhStackFile(at url: URL, records: inout Records) throws {
        do {
            guard let metadata = try readStackMetadata(at: url) else { return }
            if metadata.hasMalformedStacks {
                records.diagnose(RecordedBaseBranchReadError.stackMalformed, fallback: .stackMalformed)
            }
            for stack in metadata.stacks {
                try Task.checkCancellation()
                do {
                    try Self.validateBranchName(stack.trunk.branch, failure: .stackInvalidBranch)
                    records.trunkBranches.insert(stack.trunk.branch)
                } catch {
                    records.diagnose(error, fallback: .stackInvalidBranch)
                }
                var parent = stack.trunk.branch
                for reference in stack.branches {
                    try Task.checkCancellation()
                    let branch = reference.branch
                    do {
                        try Self.validateBranchName(branch, failure: .stackInvalidBranch)
                        try Self.validateBranchName(parent, failure: .stackInvalidBranch)
                        guard branch != parent else { throw RecordedBaseBranchReadError.stackInvalidBranch }
                        records.toolParents[branch, default: []].insert(parent)
                    } catch {
                        records.diagnose(error, fallback: .stackInvalidBranch)
                    }
                    parent = branch
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            records.diagnose(error, fallback: .stackUnreadable)
        }
    }

    private func readStackMetadata(at url: URL) throws -> GhStackMetadataFile? {
        do {
            return try decodeStackMetadata(at: url)
        } catch is DecodingError {
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.05)
            try Task.checkCancellation()
            do {
                return try decodeStackMetadata(at: url)
            } catch is DecodingError {
                throw RecordedBaseBranchReadError.stackMalformed
            }
        }
    }

    private func decodeStackMetadata(at url: URL) throws -> GhStackMetadataFile? {
        try Task.checkCancellation()
        guard let data = try metadataData(at: url) else { return nil }
        let metadata = try JSONDecoder().decode(GhStackMetadataFile.self, from: data)
        try Task.checkCancellation()
        return metadata
    }

    func metadataData(
        at url: URL, failure: RecordedBaseBranchReadError = .stackUnreadable,
        oversized: RecordedBaseBranchReadError = .stackTooLarge
    ) throws -> Data? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw failure }
            guard let size = attributes[.size] as? NSNumber, size.int64Value <= Self.maximumMetadataBytes else {
                throw oversized
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumMetadataBytes + 1) ?? Data()
            guard data.count <= Self.maximumMetadataBytes else { throw oversized }
            return data
        } catch {
            if Self.isMissingFile(error) { return nil }
            throw error
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        guard let error = error as? CocoaError else { return false }
        return error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }
}

extension RecordedBaseBranchReader {
    func readConfiguration(
        commonDirectory: URL, worktrees: [GitWorktreeBranch], unlocatedMainBranch: String?, records: inout Records
    ) throws {
        var checkouts = Dictionary(grouping: worktrees.filter { $0.branch != nil }, by: { $0.branch! })
            .mapValues { $0.map(\.path) }
        if let unlocatedMainBranch {
            checkouts[unlocatedMainBranch, default: []].append(commonDirectory.path)
        }
        try readCommonConfiguration(commonDirectory: commonDirectory, excluding: Set(checkouts.keys), records: &records)
        for branch in checkouts.keys.sorted() {
            try Task.checkCancellation()
            var parents = Set<String>()
            for checkout in checkouts[branch, default: []] {
                do {
                    if let parent = try configuredParent(branch: branch, checkoutPath: checkout) {
                        parents.insert(parent)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    records.diagnose(error, fallback: .configuration)
                }
            }
            if parents.count > 1 {
                records.recordConflict(for: branch, parents: parents)
            } else {
                records.configParents[branch] = parents.first
            }
        }
    }

    private func readCommonConfiguration(
        commonDirectory: URL, excluding checkedOutBranches: Set<String>, records: inout Records
    ) throws {
        do {
            let result = try git(
                [
                    "--git-dir", commonDirectory.path,
                    "config", "--null", "--show-scope", "--show-origin", "--name-only",
                    "--get-regexp", "^branch\\..+\\.base$"
                ], at: commonDirectory.path)
            let origins = try configurationOrigins(result, records: &records)
            for branch in origins.keys.sorted() {
                try Task.checkCancellation()
                guard !checkedOutBranches.contains(branch), let origin = origins[branch] else { continue }
                do {
                    guard origin.hasPrefix("file:") || origin == "command line:" else {
                        throw RecordedBaseBranchReadError.configuration
                    }
                    let file = origin.hasPrefix("file:") ? String(origin.dropFirst("file:".count)) : nil
                    records.configParents[branch] = try configuredParent(
                        branch: branch, checkoutPath: commonDirectory.path, file: file)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    records.diagnose(error, fallback: .configuration)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            records.diagnose(error, fallback: .configuration)
        }
    }

    private func configurationOrigins(
        _ result: ExternalProcessResult, records: inout Records
    ) throws -> [String: String] {
        if result.terminationStatus == 1 { return [:] }
        guard result.terminationStatus == 0, let output = String(data: result.stdout, encoding: .utf8),
            output.hasSuffix("\0")
        else { throw RecordedBaseBranchReadError.configuration }
        let fields = output.dropLast().components(separatedBy: "\0")
        guard fields.count.isMultiple(of: 3) else { throw RecordedBaseBranchReadError.configuration }
        var origins: [String: String] = [:]
        for index in stride(from: 0, to: fields.count, by: 3) {
            try Task.checkCancellation()
            guard fields[index] != "worktree" else { continue }
            guard let branch = RecordedBaseBranchConfiguration.branchName(forKey: fields[index + 2]) else {
                throw RecordedBaseBranchReadError.configuration
            }
            do {
                try Self.validateBranchName(branch, failure: .invalidConfig)
                origins[branch] = fields[index + 1]
            } catch {
                records.diagnose(error, fallback: .configuration)
            }
        }
        return origins
    }

    private func configuredParent(branch: String, checkoutPath: String, file: String? = nil) throws -> String? {
        try Self.validateBranchName(branch, failure: .invalidConfig)
        let fileArguments = file.map { ["--file", $0, "--no-includes"] } ?? []
        let key = RecordedBaseBranchConfiguration.key(for: branch)
        let result = try git(
            ["config", "--null"] + fileArguments + ["--get", key], at: checkoutPath)
        if result.terminationStatus == 1 { return nil }
        guard result.terminationStatus == 0, let output = String(data: result.stdout, encoding: .utf8),
            output.hasSuffix("\0"), !output.dropLast().contains("\0")
        else { throw RecordedBaseBranchReadError.configuration }
        return try Self.parentName(String(output.dropLast()), branch: branch, failure: .invalidConfig)
    }
}

private struct GhStackMetadataFile: Decodable {
    let stacks: [GhStackMetadata]
    let hasMalformedStacks: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case stacks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw RecordedBaseBranchReadError.stackUnsupportedVersion
        }
        var stackContainer = try container.nestedUnkeyedContainer(forKey: .stacks)
        var stacks: [GhStackMetadata] = []
        var hasMalformedStacks = false
        while !stackContainer.isAtEnd {
            try Task.checkCancellation()
            let stackDecoder = try stackContainer.superDecoder()
            do {
                stacks.append(try GhStackMetadata(from: stackDecoder))
            } catch is DecodingError {
                hasMalformedStacks = true
            }
        }
        self.stacks = stacks
        self.hasMalformedStacks = hasMalformedStacks
    }
}

private struct GhStackMetadata: Decodable {
    let trunk: GhStackBranchReference
    let branches: [GhStackBranchReference]
}

private struct GhStackBranchReference: Decodable {
    let branch: String
}
