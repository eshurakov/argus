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
    func coveredBehaviors() {
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

    private func assertEqual(_ actual: String, _ expected: String, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
