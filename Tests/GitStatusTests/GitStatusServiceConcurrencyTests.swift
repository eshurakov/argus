import Foundation
import Testing

@testable import Argus

@Suite
struct GitStatusServiceConcurrencyTests {
    @Test(.timeLimit(.minutes(1)))
    func concurrentStatusLoadsCompleteWithoutWaitingOnPipeDescendants() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-concurrent")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        try run("/usr/bin/git", ["config", "user.email", "argus@example.test"], in: repo.url)
        try run("/usr/bin/git", ["config", "user.name", "Argus Test"], in: repo.url)
        try "hello\n".write(
            to: repo.url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)

        let service = GitStatusService()
        let results = await withTaskGroup(of: GitStatusLoadState.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await service.status(rootPath: repo.url.path)
                }
            }
            return await group.reduce(into: [GitStatusLoadState]()) { $0.append($1) }
        }

        assertEqual(results.count, 8, "all concurrent status loads finish")
        for result in results {
            guard case .loaded(let summary) = result else {
                fail("expected loaded status for concurrent load, got \(result)")
            }
            assertEqual(summary.isClean, true, "concurrent status loads see the committed tree")
        }
    }
}
