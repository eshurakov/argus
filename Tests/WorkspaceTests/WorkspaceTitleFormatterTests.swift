import Foundation
import Testing

@testable import Argus

@Suite
struct WorkspaceTitleFormatterTests {
    @Test
    func workspacePathsAbbreviateTheHomeDirectory() {
        let home = "/Users/jdp"

        #expect(
            WorkspacePathFormatter.abbreviatedPath(
                "/Users/jdp/Development/kilo-org/on-call",
                homeDirectory: home
            ) == "~/Development/kilo-org/on-call"
        )
        #expect(WorkspacePathFormatter.abbreviatedPath(home, homeDirectory: home) == "~")
        #expect(
            WorkspacePathFormatter.abbreviatedPath(
                "/Users/jdproject/work",
                homeDirectory: home
            ) == "/Users/jdproject/work"
        )
    }

    @Test
    func workspaceTitlesOmitRedundantContextAndUseArgusFallback() {
        assertEqual(
            WorkspaceTitleFormatter.title(workspaceTitle: "argus", contextName: "argus"),
            "argus",
            "redundant workspace/context text is omitted"
        )
        assertEqual(
            WorkspaceTitleFormatter.title(workspaceTitle: "feature-ui", contextName: "Argus"),
            "feature-ui — Argus",
            "distinct workspace/context text is combined"
        )
        assertEqual(
            WorkspaceTitleFormatter.title(workspaceTitle: "", contextName: ""),
            "Argus",
            "empty title context falls back to Argus"
        )
    }

    @Test
    func applicationQuitCopyNamesAffectedWorkspaces() {
        assertEqual(
            RunningProcessConfirmationCopy.applicationMessage(
                processCount: 1,
                locationLabels: ["feature-ui — Argus"]
            ),
            "A terminal in feature-ui — Argus still has a running process. Quitting will terminate that process.",
            "one named workspace is included in the quit warning"
        )
        let joinedLabels = ListFormatter.localizedString(
            byJoining: ["feature-ui — Argus", "Notes — notes"]
        )
        assertEqual(
            RunningProcessConfirmationCopy.applicationMessage(
                processCount: 3,
                locationLabels: ["feature-ui — Argus", "Notes — notes"]
            ),
            "Terminals in \(joinedLabels) still have a running process. "
                + "Quitting will terminate those processes.",
            "multiple named workspaces are listed in the quit warning"
        )
    }

    private func assertEqual(_ actual: String, _ expected: String, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
