import Foundation
import Testing

@testable import Argus

@MainActor
@Suite(.serialized)
struct WorkspaceCommandRejectionTests {
    @Test
    func unresolvableProjectReferencesAreRefused() async throws {
        let fixture = try WorkspaceCommandFixture()
        defer { fixture.cleanup() }

        let unknown = await fixture.runtime.receive(.create(fixture.createParameters(project: "no-such-project")))
        #expect(Self.rejection(unknown)?.code == .unknownProject)

        let catchAll = await fixture.runtime.receive(
            .create(fixture.createParameters(project: fixture.manager.catchAllProject.id.uuidString)))
        let catchAllRejection = try #require(Self.rejection(catchAll))
        #expect(catchAllRejection.code == .unknownProject)
        #expect(catchAllRejection.message.contains("Standalone"))

        let noContext = await fixture.runtime.receive(
            .create(fixture.createParameters(contextDirectory: "/")))
        #expect(Self.rejection(noContext)?.code == .unknownProject)
        #expect(fixture.manager.workspaces.count == 1)
    }

    @Test
    func ambiguousProjectNamesListTheirCandidates() async throws {
        let fixture = try WorkspaceCommandFixture()
        defer { fixture.cleanup() }
        let twin = Project(
            repositoryPath: fixture.temporary.url.appendingPathComponent("twin").path,
            mainBranch: "main")
        twin.displayName = fixture.project.displayName
        fixture.manager.projects.insert(twin, at: 0)

        let outcome = await fixture.runtime.receive(
            .create(fixture.createParameters(project: fixture.project.displayName)))
        let rejection = try #require(Self.rejection(outcome))
        #expect(rejection.code == .ambiguousProject)
        #expect(rejection.message.contains(fixture.project.id.uuidString))
        #expect(rejection.message.contains(twin.id.uuidString))
    }

    @Test
    func unusableBaseWorkspacesAreRefused() async throws {
        let fixture = try WorkspaceCommandFixture()
        defer { fixture.cleanup() }

        let missing = await fixture.runtime.receive(.create(fixture.createParameters(base: "no-such-workspace")))
        #expect(Self.rejection(missing)?.code == .unknownWorkspace)

        let withoutContext = await fixture.runtime.receive(
            .create(
                fixture.createParameters(
                    project: fixture.project.displayName,
                    base: WorkspaceCommandRuntime.contextReference
                )))
        #expect(Self.rejection(withoutContext)?.code == .unknownWorkspace)

        let standalone = fixture.standaloneWorkspace(title: "notes")
        let foreign = await fixture.runtime.receive(
            .create(
                fixture.createParameters(
                    project: fixture.project.displayName,
                    base: standalone.id.uuidString
                )))
        #expect(Self.rejection(foreign)?.code == .invalidBaseWorkspace)

        let unbranched = await fixture.runtime.receive(
            .create(fixture.createParameters(base: standalone.id.uuidString)))
        #expect(Self.rejection(unbranched)?.code == .unknownProject)
        #expect(fixture.manager.workspaces.count == 2)
    }

    @Test
    func ambiguousBaseWorkspaceReferencesListTheirCandidates() async throws {
        let fixture = try WorkspaceCommandFixture()
        defer { fixture.cleanup() }
        let first = fixture.standaloneWorkspace(title: "notes")
        let second = fixture.standaloneWorkspace(title: "notes")

        let outcome = await fixture.runtime.receive(.create(fixture.createParameters(base: "notes")))
        let rejection = try #require(Self.rejection(outcome))
        #expect(rejection.code == .ambiguousWorkspace)
        #expect(rejection.message.contains(first.id.uuidString))
        #expect(rejection.message.contains(second.id.uuidString))
    }

    @Test
    func invalidAndTakenBranchNamesAreRefused() async throws {
        let fixture = try WorkspaceCommandFixture()
        defer { fixture.cleanup() }

        let invalid = await fixture.runtime.receive(
            .create(fixture.createParameters(project: fixture.project.displayName, branch: "feature branch")))
        #expect(Self.rejection(invalid)?.code == .invalidParameters)

        let taken = await fixture.runtime.receive(
            .create(fixture.createParameters(project: fixture.project.displayName, branch: "main")))
        let rejection = try #require(Self.rejection(taken))
        #expect(rejection.code == .branchAlreadyExists)
        #expect(rejection.message.contains("main"))
        #expect(fixture.manager.workspaces.count == 1)
    }

    static func rejection(_ outcome: WorkspaceCommandOutcome) -> (code: ArgusSocketErrorCode, message: String)? {
        guard case .rejected(let code, let message) = outcome else { return nil }
        return (code, message)
    }
}
