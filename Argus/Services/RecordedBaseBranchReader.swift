import Foundation

struct RecordedBaseBranchReader: Sendable {
    static let maximumMetadataBytes = 1_048_576
    static let maximumBranchNameBytes = 4_096
    private let environment: [String: String]

    init(environment: [String: String] = GitCommandEnvironment.standard) {
        self.environment = environment.merging([
            "GIT_NO_LAZY_FETCH": "1",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_OPTIONAL_LOCKS": "0"
        ]) { _, new in new }
    }

    func read(repositoryPath: String) throws -> RecordedBaseBranchSnapshot {
        do {
            let commonDirectory = try gitDirectoryOutput("--git-common-dir", at: repositoryPath)
            var records = Records()
            let discovery = try readWorktrees(
                repositoryPath: repositoryPath, commonDirectory: commonDirectory, records: &records)
            try readConfiguration(
                commonDirectory: commonDirectory, worktrees: discovery.worktrees,
                unlocatedMainBranch: discovery.unlocatedMainBranch, records: &records)
            try readGraphite(repositoryPath: repositoryPath, records: &records)
            try readGhStack(commonDirectory: commonDirectory, records: &records)
            let parents = try records.resolvedParents()
            try Task.checkCancellation()
            return RecordedBaseBranchSnapshot(
                gitCommonDirectory: commonDirectory.path,
                worktrees: discovery.worktrees,
                parents: parents,
                trunkBranches: records.trunkBranches,
                conflicts: records.conflicts,
                diagnostics: records.diagnostics.sorted()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RecordedBaseBranchReadError {
            throw error
        } catch {
            throw RecordedBaseBranchReadError.discovery
        }
    }

    func git(_ arguments: [String], at path: String, standardInput: Data? = nil) throws -> ExternalProcessResult {
        try Task.checkCancellation()
        do {
            let result = try ExternalProcess.runSynchronously(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments,
                workingDirectory: path,
                environment: environment,
                standardInput: standardInput,
                maximumOutputBytes: Self.maximumMetadataBytes,
                timeout: 30,
                commandDescription: "Read local recorded branch parents"
            )
            try Task.checkCancellation()
            return result
        } catch is ExternalProcessOutputLimitError {
            throw RecordedBaseBranchReadError.queryTooLarge
        }
    }

    func gitOutput(
        _ arguments: [String], at path: String, failure: RecordedBaseBranchReadError
    ) throws -> String {
        do {
            let result = try git(arguments, at: path)
            guard result.terminationStatus == 0, let output = String(data: result.stdout, encoding: .utf8) else {
                throw failure
            }
            return output
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RecordedBaseBranchReadError {
            throw error
        } catch {
            throw failure
        }
    }

    private func readWorktrees(
        repositoryPath: String, commonDirectory: URL, records: inout Records
    ) throws -> (worktrees: [GitWorktreeBranch], unlocatedMainBranch: String?) {
        let initiating = try verifiedCheckout(at: repositoryPath)
        do {
            let output = try gitOutput(
                ["worktree", "list", "--porcelain", "-z"], at: repositoryPath, failure: .discovery)
            let inventory = try parseWorktrees(output)
            var linked = inventory.linked.filter {
                $0.path != initiating.worktree.path && $0.path != commonDirectory.path
            }
            if initiating.gitDirectory == commonDirectory {
                return ([initiating.worktree] + linked.sorted { $0.path < $1.path }, nil)
            }
            linked.append(initiating.worktree)
            linked.sort { $0.path < $1.path }
            if let main = inventory.main {
                do {
                    let verified = try verifiedCheckout(at: main.path)
                    guard verified.gitDirectory == commonDirectory,
                        verified.worktree.path != commonDirectory.path,
                        FileManager.default.fileExists(atPath: verified.worktree.path + "/.git")
                    else { throw RecordedBaseBranchReadError.mainCheckout }
                    return ([verified.worktree] + linked, nil)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    records.diagnostics.insert(RecordedBaseBranchReadError.mainCheckout.localizedDescription)
                }
            }
            return (linked, inventory.main?.branch)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            records.diagnose(error, fallback: .discovery)
        }
        let registered = try registeredWorktrees(
            excluding: initiating.gitDirectory, commonDirectory: commonDirectory, records: &records)
        let worktrees = [initiating.worktree] + registered
        return (worktrees.sorted { $0.path < $1.path }, nil)
    }

    private func registeredWorktrees(
        excluding initiatingGitDirectory: URL, commonDirectory: URL, records: inout Records
    ) throws -> [GitWorktreeBranch] {
        var worktrees: [GitWorktreeBranch] = []
        let root = commonDirectory.appendingPathComponent("worktrees", isDirectory: true)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw RecordedBaseBranchReadError.discovery
            }
            let directories = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for directory in directories.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                if directory.standardizedFileURL.resolvingSymlinksInPath() == initiatingGitDirectory {
                    continue
                }
                do {
                    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true,
                        let data = try metadataData(
                            at: directory.appendingPathComponent("gitdir"), failure: .discovery, oversized: .discovery),
                        let path = String(data: data, encoding: .utf8), path.hasPrefix("/"), path.hasSuffix("\n")
                    else { continue }
                    let pointer = URL(fileURLWithPath: String(path.dropLast())).standardizedFileURL
                    guard pointer.lastPathComponent == ".git" else { continue }
                    let checkoutPath = pointer.deletingLastPathComponent().resolvingSymlinksInPath().path
                    guard FileManager.default.fileExists(atPath: checkoutPath) else { continue }
                    let checkout = try verifiedCheckout(at: checkoutPath)
                    if checkout.worktree.path == checkoutPath,
                        checkout.gitDirectory == directory.standardizedFileURL.resolvingSymlinksInPath()
                    {
                        worktrees.append(checkout.worktree)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    records.diagnose(error, fallback: .discovery)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            records.diagnose(error, fallback: .discovery)
        }
        return worktrees
    }

    private func verifiedCheckout(at path: String) throws -> (worktree: GitWorktreeBranch, gitDirectory: URL) {
        let topLevel = try gitDirectoryOutput("--show-toplevel", at: path)
        let gitDirectory = try gitDirectoryOutput("--git-dir", at: path)
        let result = try git(["symbolic-ref", "--quiet", "HEAD"], at: path)
        let branch: String?
        if result.terminationStatus == 1 {
            branch = nil
        } else {
            guard result.terminationStatus == 0, let output = String(data: result.stdout, encoding: .utf8),
                output.hasPrefix("refs/heads/"), output.hasSuffix("\n")
            else { throw RecordedBaseBranchReadError.discovery }
            branch = String(output.dropFirst("refs/heads/".count).dropLast())
        }
        if let branch { try Self.validateBranchName(branch, failure: .discovery) }
        return (GitWorktreeBranch(path: topLevel.path, branch: branch), gitDirectory)
    }

    private func gitDirectoryOutput(_ argument: String, at path: String) throws -> URL {
        let output = try gitOutput(["rev-parse", "--path-format=absolute", argument], at: path, failure: .discovery)
        guard output.hasPrefix("/"), output.hasSuffix("\n") else { throw RecordedBaseBranchReadError.discovery }
        return URL(fileURLWithPath: String(output.dropLast()), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    private func parseWorktrees(_ output: String) throws -> (main: GitWorktreeBranch?, linked: [GitWorktreeBranch]) {
        guard output.hasSuffix("\0\0") else { throw RecordedBaseBranchReadError.discovery }
        var main: GitWorktreeBranch?
        var linked: [GitWorktreeBranch] = []
        for (index, record) in output.components(separatedBy: "\0\0").dropLast().enumerated() {
            try Task.checkCancellation()
            let fields = record.components(separatedBy: "\0")
            guard let pathField = fields.first, pathField.hasPrefix("worktree ") else {
                throw RecordedBaseBranchReadError.discovery
            }
            let path = String(pathField.dropFirst("worktree ".count))
            guard path.hasPrefix("/") else { throw RecordedBaseBranchReadError.discovery }
            guard !fields.contains(where: { $0 == "bare" || $0 == "prunable" || $0.hasPrefix("prunable ") }) else {
                continue
            }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else {
                continue
            }
            let branchField = fields.first { $0.hasPrefix("branch refs/heads/") }
            let branch = branchField.map { String($0.dropFirst("branch refs/heads/".count)) }
            if let branch { try Self.validateBranchName(branch, failure: .discovery) }
            let worktree = GitWorktreeBranch(path: url.path, branch: fields.contains("detached") ? nil : branch)
            if index == 0 { main = worktree } else { linked.append(worktree) }
        }
        return (main, linked)
    }

    static func parentName(_ value: String, branch: String, failure: RecordedBaseBranchReadError) throws -> String? {
        try validateBranchName(branch, failure: failure)
        guard value.utf8.count <= maximumBranchNameBytes else { throw RecordedBaseBranchReadError.nameTooLarge }
        let parent = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parent.isEmpty, parent != branch else { return nil }
        try validateBranchName(parent, failure: failure)
        return parent
    }

    static func validateBranchName(_ value: String, failure: RecordedBaseBranchReadError) throws {
        guard value.utf8.count <= maximumBranchNameBytes else { throw RecordedBaseBranchReadError.nameTooLarge }
        guard GitReferenceValidation.isValidBranchName(value) else { throw failure }
    }
}

extension RecordedBaseBranchReader {
    struct Records {
        var configParents: [String: String] = [:]
        var toolParents: [String: Set<String>] = [:]
        var trunkBranches = Set<String>()
        var conflicts: [String: String] = [:]
        var diagnostics = Set<String>()

        mutating func diagnose(_ error: Error, fallback: RecordedBaseBranchReadError) {
            diagnostics.insert((error as? RecordedBaseBranchReadError ?? fallback).localizedDescription)
        }

        mutating func recordConflict(for branch: String, parents: Set<String>) {
            let names = parents.sorted().prefix(3).map(Self.diagnosticName).joined(separator: ", ")
            let more = parents.count > 3 ? ", and \(parents.count - 3) more" : ""
            conflicts[branch] = "Conflicting recorded parents for \(Self.diagnosticName(branch)): \(names)\(more)."
        }

        private static func diagnosticName(_ name: String) -> String {
            guard name.utf8.count > 80 else { return "'\(name)'" }
            var prefix = ""
            var suffix = ""
            var bytes = 0
            for scalar in name.unicodeScalars {
                let size = String(scalar).utf8.count
                guard bytes + size <= 48 else { break }
                prefix.unicodeScalars.append(scalar)
                bytes += size
            }
            bytes = 0
            for scalar in name.unicodeScalars.reversed() {
                let size = String(scalar).utf8.count
                guard bytes + size <= 24 else { break }
                suffix = String(scalar) + suffix
                bytes += size
            }
            return "'\(prefix)...\(suffix)'"
        }

        mutating func resolvedParents() throws -> [String: String] {
            var parents: [String: String] = [:]
            for branch in Set(configParents.keys).union(toolParents.keys).sorted() {
                try Task.checkCancellation()
                guard conflicts[branch] == nil else { continue }
                if let configured = configParents[branch] {
                    parents[branch] = configured
                } else if let candidates = toolParents[branch], candidates.count == 1 {
                    parents[branch] = candidates.first
                } else if let candidates = toolParents[branch], candidates.count > 1 {
                    recordConflict(for: branch, parents: candidates)
                }
            }
            var visited = Set<String>()
            for branch in parents.keys.sorted() {
                try Task.checkCancellation()
                var path: [String] = []
                var positions: [String: Int] = [:]
                var current = branch
                while !visited.contains(current), let parent = parents[current] {
                    try Task.checkCancellation()
                    if let start = positions[current] {
                        for cyclicBranch in path[start...] {
                            if let cyclicParent = parents.removeValue(forKey: cyclicBranch) {
                                conflicts[cyclicBranch] =
                                    "Recorded parent cycle: \(Self.diagnosticName(cyclicBranch)) "
                                    + "has parent \(Self.diagnosticName(cyclicParent))."
                            }
                        }
                        break
                    }
                    positions[current] = path.count
                    path.append(current)
                    current = parent
                }
                visited.formUnion(path)
            }
            return parents
        }
    }
}

enum RecordedBaseBranchReadError: LocalizedError {
    case discovery
    case mainCheckout
    case queryTooLarge
    case nameTooLarge
    case configuration
    case invalidConfig
    case graphiteUnreadable
    case graphiteMalformed
    case graphiteTooLarge
    case graphiteInvalidBranch
    case stackUnreadable
    case stackMalformed
    case stackUnsupportedVersion
    case stackTooLarge
    case stackInvalidBranch

    var errorDescription: String? {
        switch self {
        case .discovery: "Could not discover local Git worktrees and recorded branch parents."
        case .mainCheckout: "The main checkout location could not be verified."
        case .queryTooLarge: "Local Git metadata output exceeds the 1 MiB limit."
        case .nameTooLarge: "A local branch-parent declaration exceeds the 4096-byte name limit."
        case .configuration: "Local Git branch-base configuration could not be read."
        case .invalidConfig: "Local Git branch-base configuration contains an invalid branch name."
        case .graphiteUnreadable: "Local Graphite metadata could not be read."
        case .graphiteMalformed: "Local Graphite metadata is malformed."
        case .graphiteTooLarge: "Local Graphite metadata exceeds the 1 MiB limit."
        case .graphiteInvalidBranch: "Local Graphite metadata contains an invalid branch name."
        case .stackUnreadable: "Local gh-stack metadata could not be read."
        case .stackMalformed: "Local gh-stack metadata is malformed."
        case .stackUnsupportedVersion: "Local gh-stack metadata uses an unsupported schema version."
        case .stackTooLarge: "Local gh-stack metadata exceeds the 1 MiB limit."
        case .stackInvalidBranch: "Local gh-stack metadata contains an invalid branch relationship."
        }
    }
}
