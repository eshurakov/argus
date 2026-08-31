import Foundation
import Testing

@testable import Argus

@Suite
struct GitPreviewErrorPropagationTests {
    @Test
    func headLookupFailuresDoNotBecomeAnEmptyDiffSide() async {
        let service = GitPreviewService(
            commandRunner: GitPreviewCommandRunner { command in
                if command.arguments.contains("rev-parse") {
                    throw TestPreviewError.failed
                }
                return GitPreviewCommandResult(stdout: Data(), stderr: Data())
            }
        )
        let result = await service.preview(
            kind: .diff,
            rootPath: "/tmp/repo",
            file: GitFileChange(
                path: "file.txt",
                status: .modified,
                sectionKind: .uncommitted,
                hasUnstagedChanges: true,
                diffSource: .uncommitted
            )
        )

        guard case .failed(.diff, "file.txt", .uncommitted, let message) = result else {
            Issue.record("Expected HEAD lookup failure, got \(result)")
            return
        }
        #expect(message == TestPreviewError.failed.localizedDescription)
    }
}

private enum TestPreviewError: LocalizedError {
    case failed

    var errorDescription: String? { "Injected preview failure" }
}
