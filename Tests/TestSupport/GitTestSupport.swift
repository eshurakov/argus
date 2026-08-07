import Foundation

struct TestTemporaryDirectory {
    let url: URL

    init(prefix: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum TestGit {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/git")

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], cwd: String) throws -> String {
        guard executable == "git" || executable == "/usr/bin/git" else {
            throw NSError(
                domain: "ArgusTests.TestGit",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported test executable: \(executable)"]
            )
        }
        return try run(arguments, in: URL(fileURLWithPath: cwd))
    }

    @discardableResult
    static func run(
        _ arguments: [String],
        in directory: URL,
        environment: [String: String] = [:]
    ) throws -> String {
        try capture(arguments, in: directory, environment: environment)
    }

    // This helper keeps process setup, output capture, and error reporting in one disposable boundary.
    // swiftlint:disable:next function_body_length
    static func capture(
        _ arguments: [String],
        in directory: URL,
        environment: [String: String] = [:]
    ) throws -> String {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-git-output-\(UUID().uuidString)")
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-git-error-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(
            [
                "GIT_ASKPASS": "echo",
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "core.fsmonitor",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_VALUE_0": "false",
                "GIT_TERMINAL_PROMPT": "0"
            ].merging(environment) { _, new in new }
        ) { _, new in new }
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        try? output.close()
        try? error.close()

        let outputText =
            String(
                data: try Data(contentsOf: outputURL),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let errorText =
                String(
                    data: try Data(contentsOf: errorURL),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(
                domain: "ArgusTests.TestGit",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "git \(arguments.joined(separator: " ")) failed: \(errorText)"
                ]
            )
        }
        return outputText
    }
}
