import Foundation
import Testing

@testable import Argus

@Suite
struct ExternalProcessTests {
    @Test(.timeLimit(.minutes(1)))
    func returnsAfterParentExitsEvenIfDescendantHoldsPipesOpen() async throws {
        let start = Date()
        let result = try await ExternalProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf ready; sleep 1 &"],
            timeout: 2,
            commandDescription: "pipe-holding fixture"
        )

        #expect(result.terminationStatus == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "ready")
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test(.timeLimit(.minutes(1)))
    func timesOutWhileTheParentProcessIsStillRunning() async throws {
        let start = Date()

        do {
            _ = try await ExternalProcess.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: 0.2,
                commandDescription: "long-running fixture"
            )
            Issue.record("long-running process should time out")
        } catch let error as ExternalProcessError {
            guard case .timedOut = error else {
                Issue.record("unexpected timeout error: \(error)")
                return
            }
        }

        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentCompletedProcessesDoNotStarveOutputReaders() async throws {
        let processCount = 12
        let outputs = try await withThrowingTaskGroup(of: ExternalProcessResult.self) { group in
            for index in 0..<processCount {
                group.addTask {
                    try await ExternalProcess.run(
                        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                        arguments: [],
                        timeout: 5,
                        commandDescription: "completed fixture \(index)"
                    )
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(outputs.count == processCount)
        #expect(outputs.allSatisfy { $0.terminationStatus == 0 && $0.stdout.isEmpty })
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func standardInputAtLimitPreservesBinaryBytes(_ synchronous: Bool) async throws {
        let input = Data((0..<ExternalProcess.maximumInputBytes).map { UInt8(truncatingIfNeeded: $0) })
        let result = try await inputFixture(standardInput: input, synchronous: synchronous)

        #expect(result.terminationStatus == 0)
        #expect(result.stdout == input)
        #expect(result.stderr.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [nil, Data()] as [Data?])
    func emptyStandardInputReachesEOF(_ synchronous: Bool, _ input: Data?) async throws {
        let result = try await inputFixture(standardInput: input, synchronous: synchronous)

        #expect(result.terminationStatus == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func oversizedStandardInputIsRejectedBeforeSpawn(_ synchronous: Bool) async throws {
        let input = Data(repeating: 255, count: ExternalProcess.maximumInputBytes + 1)
        await #expect(throws: ExternalProcessInputLimitError.self) {
            try await inputFixture(
                standardInput: input,
                synchronous: synchronous,
                executableURL: URL(fileURLWithPath: "/nonexistent/argus-input-fixture"))
        }
        #expect(
            ExternalProcessInputLimitError().localizedDescription == "Command input exceeded the supported limit.")
    }

    @Test(arguments: [false, true], ["stdout", "stderr", "combined"])
    func boundedRunsRejectFastExitingOutputWithoutExposingIt(_ synchronous: Bool, _ stream: String) async throws {
        let script =
            switch stream {
            case "stdout": "printf bounded-output-marker"
            case "stderr": "printf bounded-output-marker >&2"
            default: "printf 1234; printf 56789 >&2"
            }
        await #expect(throws: ExternalProcessOutputLimitError.self) {
            try await boundedFixture(script: script, synchronous: synchronous)
        }
        #expect(
            ExternalProcessOutputLimitError().localizedDescription == "Command output exceeded the configured limit.")
    }

    @Test(arguments: [false, true], ["stdout", "stderr", "combined"])
    func continuousOutputCannotStarveTheBound(_ synchronous: Bool, _ stream: String) async throws {
        let script =
            switch stream {
            case "stdout": "exec /usr/bin/yes bounded-fixture"
            case "stderr": "exec /usr/bin/yes bounded-fixture >&2"
            default: "while :; do printf bounded-fixture; printf bounded-fixture >&2; done"
            }
        await #expect(throws: ExternalProcessOutputLimitError.self) {
            try await boundedFixture(script: script, synchronous: synchronous)
        }
    }

    @Test(arguments: [0, 1, 8, 32])
    func bufferedOutputAtEOFNeverExceedsTheCombinedCap(_ limit: Int) throws {
        let stdout = Pipe()
        let stderr = Pipe()
        let reader = WorktreeProcessOutputReader(stdout: stdout, stderr: stderr, maximumOutputBytes: limit)
        defer { reader.close() }
        try stdout.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: limit / 2))
        try stderr.fileHandleForWriting.write(contentsOf: Data(repeating: 66, count: limit - limit / 2 + 1))
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        #expect(throws: ExternalProcessOutputLimitError.self) { try reader.drain() }
        #expect(reader.output.stdout.count + reader.output.stderr.count == limit)
        #expect(reader.isFinished)
    }

    @Test(arguments: [0, 1, 8, 32])
    func exactCombinedOutputLimitIsAccepted(_ limit: Int) throws {
        let stdout = Pipe()
        let stderr = Pipe()
        let reader = WorktreeProcessOutputReader(stdout: stdout, stderr: stderr, maximumOutputBytes: limit)
        defer { reader.close() }
        try stdout.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: limit / 2))
        try stderr.fileHandleForWriting.write(contentsOf: Data(repeating: 66, count: limit - limit / 2))
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        try reader.drain()
        #expect(reader.output.stdout.count + reader.output.stderr.count == limit)
    }

    @Test(arguments: [false, true])
    func continuousOutputStillRespondsToCancellation(_ synchronous: Bool) async throws {
        let task = Task.detached {
            if synchronous {
                return try ExternalProcess.runSynchronously(
                    executableURL: URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["cancellation-fixture"],
                    maximumOutputBytes: 67_108_864, timeout: 5, commandDescription: "cancellation fixture")
            }
            return try await ExternalProcess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["cancellation-fixture"],
                maximumOutputBytes: 67_108_864, timeout: 5, commandDescription: "cancellation fixture")
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func continuousOutputWithoutAnOptInCapStillHonorsTimeout() async throws {
        await #expect(throws: ExternalProcessError.timedOut("continuous fixture")) {
            try await ExternalProcess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["timeout-fixture"],
                timeout: 0.05, commandDescription: "continuous fixture")
        }
    }

    private func inputFixture(
        standardInput: Data?,
        synchronous: Bool,
        executableURL: URL = URL(fileURLWithPath: "/bin/cat")
    ) async throws -> ExternalProcessResult {
        if synchronous {
            return try ExternalProcess.runSynchronously(
                executableURL: executableURL, arguments: [], standardInput: standardInput,
                maximumOutputBytes: ExternalProcess.maximumInputBytes, timeout: 2, commandDescription: "input fixture")
        }
        return try await ExternalProcess.run(
            executableURL: executableURL, arguments: [], standardInput: standardInput,
            maximumOutputBytes: ExternalProcess.maximumInputBytes, timeout: 2, commandDescription: "input fixture")
    }

    private func boundedFixture(script: String, synchronous: Bool) async throws -> ExternalProcessResult {
        if synchronous {
            return try ExternalProcess.runSynchronously(
                executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                maximumOutputBytes: 8, timeout: 2, commandDescription: "bounded fixture")
        }
        return try await ExternalProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            maximumOutputBytes: 8, timeout: 2, commandDescription: "bounded fixture")
    }

    @Test(.timeLimit(.minutes(1)))
    func synchronousRunMatchesAsyncExitAndOutput() throws {
        let result = try ExternalProcess.runSynchronously(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            timeout: 5,
            commandDescription: "echo fixture"
        )

        #expect(result.terminationStatus == 0)
        #expect(
            String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }
}
