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
