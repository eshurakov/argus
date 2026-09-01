import Darwin
import Foundation

enum ExternalProcessError: Error, Equatable {
    case timedOut(String)
}

struct ExternalProcessInputLimitError: LocalizedError, Equatable {
    var errorDescription: String? { "Command input exceeded the supported limit." }
}

struct ExternalProcessOutputLimitError: LocalizedError, Equatable {
    var errorDescription: String? { "Command output exceeded the configured limit." }
}

struct ExternalProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32
}

enum GitCommandEnvironment {
    static var standard: [String: String] {
        ProcessInfo.processInfo.environment.merging([
            "GIT_ASKPASS": "echo",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_PAGER": "cat",
            "GIT_TERMINAL_PROMPT": "0"
        ]) { _, new in new }
    }
}

enum ExternalProcess {
    static let maximumInputBytes = Int(PIPE_BUF)

    static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        maximumOutputBytes: Int? = nil,
        timeout: TimeInterval,
        commandDescription: String
    ) async throws -> ExternalProcessResult {
        let running = try start(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: standardInput,
            maximumOutputBytes: maximumOutputBytes,
            timeout: timeout,
            commandDescription: commandDescription
        )
        return try await running.wait()
    }

    static func runSynchronously(
        executableURL: URL,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        maximumOutputBytes: Int? = nil,
        timeout: TimeInterval,
        commandDescription: String
    ) throws -> ExternalProcessResult {
        let running = try start(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: standardInput,
            maximumOutputBytes: maximumOutputBytes,
            timeout: timeout,
            commandDescription: commandDescription
        )
        return try running.waitSynchronously()
    }

    private static func start(
        executableURL: URL,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        maximumOutputBytes: Int? = nil,
        timeout: TimeInterval,
        commandDescription: String
    ) throws -> RunningExternalProcess {
        if let standardInput, standardInput.count > maximumInputBytes {
            throw ExternalProcessInputLimitError()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        if let standardInput {
            try stdin.fileHandleForWriting.write(contentsOf: standardInput)
        }
        try stdin.fileHandleForWriting.close()
        try process.run()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        return RunningExternalProcess(
            process: process,
            outputReader: WorktreeProcessOutputReader(
                stdout: stdout, stderr: stderr, maximumOutputBytes: maximumOutputBytes),
            timeout: timeout,
            commandDescription: commandDescription
        )
    }
}

private final class RunningExternalProcess {
    private let process: Process
    private let outputReader: WorktreeProcessOutputReader
    private let timeout: TimeInterval
    private let commandDescription: String

    init(
        process: Process,
        outputReader: WorktreeProcessOutputReader,
        timeout: TimeInterval,
        commandDescription: String
    ) {
        self.process = process
        self.outputReader = outputReader
        self.timeout = timeout
        self.commandDescription = commandDescription
    }

    func wait() async throws -> ExternalProcessResult {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            if Task.isCancelled {
                stop()
                outputReader.close()
                throw CancellationError()
            }
            try drainOutput()
            if process.isRunning {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000)
                } catch {
                    stop()
                    outputReader.close()
                    throw error
                }
            }
        }
        return try complete()
    }

    func waitSynchronously() throws -> ExternalProcessResult {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            if Task.isCancelled {
                stop()
                outputReader.close()
                throw CancellationError()
            }
            try drainOutput()
            if process.isRunning {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return try complete()
    }

    private func drainOutput() throws {
        do {
            try outputReader.drain()
        } catch {
            stop()
            outputReader.close()
            throw error
        }
    }

    private func complete() throws -> ExternalProcessResult {
        if process.isRunning {
            stop()
            outputReader.close()
            throw ExternalProcessError.timedOut(commandDescription)
        }
        return try finishAfterExit()
    }

    private func finishAfterExit() throws -> ExternalProcessResult {
        try drainOutput()
        let drainDeadline = Date().addingTimeInterval(0.05)
        while !outputReader.isFinished && Date() < drainDeadline {
            try drainOutput()
            Thread.sleep(forTimeInterval: 0.01)
        }
        outputReader.close()
        return ExternalProcessResult(
            stdout: outputReader.output.stdout,
            stderr: outputReader.output.stderr,
            terminationStatus: process.terminationStatus
        )
    }

    private func stop() {
        if process.isRunning {
            process.terminate()
        }
        let terminationDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.025)
        }
    }
}
