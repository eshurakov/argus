import Foundation
import Testing

@testable import Argus

@Suite
struct ExistingBranchPickerTests {
    @Test(.timeLimit(.minutes(1)))
    func defaultTimeoutIncludesDescendantsHoldingOutputPipesOpen() async throws {
        let service = WorktreeService(gitCommandTimeout: 0.2)
        let start = Date()

        do {
            _ = try await service.runProcess(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                args: ["-c", "sleep 1 &"],
                commandDescription: "pipe-holding fixture"
            )
            Issue.record("pipe-holding subprocess should time out")
        } catch let error as WorktreeError {
            guard case .gitCommandTimedOut = error else {
                Issue.record("unexpected timeout error: \(error)")
                return
            }
        }

        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func largeBranchListDoesNotBlockOnAFullOutputPipe() async throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("argus-large-branch-picker-\(UUID().uuidString)", isDirectory: true)
        let repo = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try run("git", ["init", "-b", "main", "."], cwd: repo.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: repo.path)
        try run("git", ["config", "user.name", "Test User"], cwd: repo.path)
        try "fixture".write(
            to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: repo.path)
        try run("git", ["commit", "-m", "initial"], cwd: repo.path)

        let head = try capture("git", ["rev-parse", "HEAD"], cwd: repo.path)
        let refsDirectory = repo.appendingPathComponent(".git/refs/heads", isDirectory: true)
        let branchPrefix = "branch-\(String(repeating: "x", count: 100))-"
        for index in 0..<700 {
            try "\(head)\n".write(
                to: refsDirectory.appendingPathComponent("\(branchPrefix)\(index)"),
                atomically: false,
                encoding: .utf8
            )
        }

        let available = try await WorktreeService().listWorkspaceBranchChoices(repositoryPath: repo.path)

        assertTrue(available.count == 700, "all available branches are returned")
        assertTrue(available.contains("\(branchPrefix)699"), "last generated branch is returned")
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentCompletedProcessesDoNotBlockAfterExit() async throws {
        let service = WorktreeService(gitCommandTimeout: 2)

        async let first = service.runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            args: [],
            commandDescription: "first completed fixture"
        )
        async let second = service.runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            args: [],
            commandDescription: "second completed fixture"
        )

        let outputs = try await [first, second]
        #expect(outputs == ["", ""])
    }

    @Test
    func coveredBehaviors() async throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("argus-existing-picker-\(UUID().uuidString)", isDirectory: true)
        let origin = temp.appendingPathComponent("origin.git", isDirectory: true)
        let seed = temp.appendingPathComponent("seed", isDirectory: true)
        let repo = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try createRemoteFixture(origin: origin, seed: seed, temp: temp)

        try run(
            "git", ["clone", "--single-branch", "--branch", "main", origin.path, repo.path],
            cwd: temp.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: repo.path)
        try run("git", ["config", "user.name", "Test User"], cwd: repo.path)

        let localBranches = try capture(
            "git", ["branch", "--all", "--format=%(refname:short)"], cwd: repo.path)
        assertFalse(
            localBranches.contains("origin/feature/unfetched"),
            "test branch starts as an unfetched remote branch")

        let service = WorktreeService()
        let available = try await service.listAvailableBranches(repositoryPath: repo.path)
        assertTrue(
            available.contains("origin/feature/unfetched"),
            "available branches include remote heads not present in local remote-tracking refs")
        assertFalse(available.contains("origin/main"), "checked-out main remains unavailable")

        let worktreePath = try await service.createWorktree(
            projectId: UUID(),
            repositoryPath: repo.path,
            branchName: "origin/feature/unfetched",
            createNewBranch: false
        )
        defer { try? FileManager.default.removeItem(atPath: worktreePath) }
        let checkedOutBranch = try capture("git", ["branch", "--show-current"], cwd: worktreePath)
        assertTrue(
            checkedOutBranch == "feature/unfetched",
            "unfetched remote head opens as a local tracking branch")
    }

    private func createRemoteFixture(origin: URL, seed: URL, temp: URL) throws {
        try run("git", ["init", "--bare", origin.path], cwd: temp.path)
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try run("git", ["init", "-b", "main", "."], cwd: seed.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: seed.path)
        try run("git", ["config", "user.name", "Test User"], cwd: seed.path)
        try "hello".write(
            to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: seed.path)
        try run("git", ["commit", "-m", "initial"], cwd: seed.path)
        try run("git", ["remote", "add", "origin", origin.path], cwd: seed.path)
        try run("git", ["push", "-u", "origin", "main"], cwd: seed.path)
        try run("git", ["checkout", "-b", "feature/unfetched"], cwd: seed.path)
        try "feature".write(
            to: seed.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try run("git", ["add", "feature.txt"], cwd: seed.path)
        try run("git", ["commit", "-m", "feature"], cwd: seed.path)
        try run("git", ["push", "origin", "feature/unfetched"], cwd: seed.path)
    }

    private func run(_ executable: String, _ args: [String], cwd: String) throws {
        _ = try capture(executable, args, cwd: cwd)
    }

    private func capture(_ executable: String, _ args: [String], cwd: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/\(executable)")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.fsmonitor",
            "GIT_CONFIG_VALUE_0": "false"
        ]) { _, new in new }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        process.waitUntilExit()
        let output =
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let detail =
                String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "ExistingBranchPickerTests", code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(executable) \(args.joined(separator: " ")) failed: \(detail)"
                ])
        }
        return output
    }

    private func assertTrue(_ condition: Bool, _ message: String) {
        #expect(condition, Comment(rawValue: message))
    }

    private func assertFalse(_ condition: Bool, _ message: String) {
        assertTrue(!condition, message)
    }
}
