import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct PullRequestStatusNavigationTests {
    @Test(arguments: [true, false], [true, false])
    func openingPreservesWorkspaceStateOnSuccessAndFailure(openSucceeds: Bool, sourceIsSelected: Bool) throws {
        let fixture = try PullRequestNavigationFixture()
        defer { fixture.close() }
        let other = try #require(fixture.manager.selectedWorkspace)
        let otherTab = other.openReleaseNotesPanel()
        let source = fixture.addWorktree()
        let terminal = try #require(source.addTerminalPanel())
        let focusedPane = try #require(source.splitActiveTerminal(direction: .vertical))
        let lastTab = source.openFilePanel(rootPath: source.currentDirectory, relativePath: "unopened.txt")
        source.selectPanel(focusedPane.id)
        if sourceIsSelected { fixture.manager.selectWorkspace(source.id) }
        fixture.project.isExpanded = false
        let selectedWorkspaceID = fixture.manager.selectedWorkspaceId
        let contextRevision = fixture.manager.workspaceContextRevision
        let layouts = source.tabLayouts
        let before = try fixture.snapshotData()
        let status = fixture.status()
        var openedURLs: [URL] = []

        let opened = fixture.manager.openPullRequest(
            status, in: source.id,
            openURL: {
                openedURLs.append($0)
                return openSucceeds
            })

        #expect(opened == openSucceeds)
        #expect(openedURLs == [status.url])
        #expect(fixture.manager.selectedWorkspaceId == selectedWorkspaceID)
        #expect(fixture.manager.workspaceContextRevision == contextRevision)
        #expect(source.activeTabId == terminal.id)
        #expect(source.activePanelId == focusedPane.id)
        #expect(source.panelOrder == [terminal.id, lastTab.id])
        #expect(Set(source.panels.keys) == [terminal.id, focusedPane.id, lastTab.id])
        #expect(source.panels[terminal.id] as? TerminalPanel === terminal)
        #expect(source.panels[focusedPane.id] as? TerminalPanel === focusedPane)
        #expect(source.panels[lastTab.id] as? FilePanel === lastTab)
        #expect(source.tabLayouts == layouts)
        #expect(other.activeTabId == otherTab.id)
        #expect(other.activePanelId == otherTab.id)
        #expect(other.panelOrder == [otherTab.id])
        #expect(Set(other.panels.keys) == [otherTab.id])
        #expect(try fixture.snapshotData() == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshotURL.path))
    }

    @Test
    func repeatedOpeningFromDifferentWorkspacesDoesNotReuseBrowserTabs() throws {
        let fixture = try PullRequestNavigationFixture()
        defer { fixture.close() }
        let selected = try #require(fixture.manager.selectedWorkspace)
        let selectedTab = selected.openReleaseNotesPanel()
        let first = fixture.addWorktree()
        let second = fixture.addWorktree()
        let firstBrowser = first.addBrowserPanel(configuration: fixture.manager.browserPanelConfiguration)
        let secondBrowser = second.addBrowserPanel(configuration: fixture.manager.browserPanelConfiguration)
        let firstTab = first.openReleaseNotesPanel()
        let secondTab = second.openReleaseNotesPanel()
        let firstFocus = firstBrowser.focusRequest
        let secondFocus = secondBrowser.focusRequest
        let before = try fixture.snapshotData()
        let status = fixture.status()
        var openedURLs: [URL] = []

        for source in [first, first, second, first] {
            let opened = fixture.manager.openPullRequest(
                status, in: source.id,
                openURL: {
                    openedURLs.append($0)
                    return true
                })
            #expect(opened)
            #expect(fixture.manager.selectedWorkspaceId == selected.id)
            #expect(first.activeTabId == firstTab.id)
            #expect(first.activePanelId == firstTab.id)
            #expect(second.activeTabId == secondTab.id)
            #expect(second.activePanelId == secondTab.id)
        }

        #expect(openedURLs == [status.url, status.url, status.url, status.url])
        #expect(first.panelOrder == [firstBrowser.id, firstTab.id])
        #expect(second.panelOrder == [secondBrowser.id, secondTab.id])
        #expect(Set(first.panels.keys) == [firstBrowser.id, firstTab.id])
        #expect(Set(second.panels.keys) == [secondBrowser.id, secondTab.id])
        #expect(first.panels[firstBrowser.id] as? BrowserPanel === firstBrowser)
        #expect(second.panels[secondBrowser.id] as? BrowserPanel === secondBrowser)
        #expect(firstBrowser.currentURL == nil)
        #expect(secondBrowser.currentURL == nil)
        #expect(firstBrowser.focusRequest == firstFocus)
        #expect(secondBrowser.focusRequest == secondFocus)
        #expect(selected.activeTabId == selectedTab.id)
        #expect(selected.activePanelId == selectedTab.id)
        #expect(selected.panelOrder == [selectedTab.id])
        #expect(try fixture.snapshotData() == before)
    }

    @Test(arguments: [
        "http://reviews.invalid/team/argus/pull/42",
        "file:///team/argus/pull/42",
        "javascript:alert(1)",
        "/team/argus/pull/42",
        "https://user@reviews.invalid/team/argus/pull/42",
        "https://reviews.invalid/team/argus/issues/42",
        "https://reviews.invalid/team/argus/pull",
        "https://reviews.invalid/team/argus/pull/0",
        "https://reviews.invalid/team/argus/pull/-42",
        "https://reviews.invalid/team/argus/pull/99999999999999999999999999999",
        "https://reviews.invalid/team/argus/pull/not-a-number",
        "https://other.invalid/team/argus/pull/42",
        "https://reviews.invalid/other/argus/pull/42",
        "https://reviews.invalid/team/other/pull/42",
        "https://reviews.invalid/team/argus/pull/43"
    ])
    func invalidURLsAndIdentityMismatchesDoNotCallOpenerOrChangeState(urlString: String) throws {
        let fixture = try PullRequestNavigationFixture()
        defer { fixture.close() }
        let selected = try #require(fixture.manager.selectedWorkspace)
        let selectedTab = selected.openReleaseNotesPanel()
        let source = fixture.addWorktree()
        let before = try fixture.snapshotData()
        var openedURLs: [URL] = []

        let opened = fixture.manager.openPullRequest(
            fixture.status(urlString: urlString), in: source.id,
            openURL: {
                openedURLs.append($0)
                return true
            })

        #expect(!opened)
        #expect(openedURLs.isEmpty)
        #expect(source.panels.isEmpty)
        #expect(source.panelOrder.isEmpty)
        #expect(source.tabLayouts.isEmpty)
        #expect(source.activeTabId == nil)
        #expect(source.activePanelId == nil)
        #expect(fixture.manager.selectedWorkspaceId == selected.id)
        #expect(selected.activeTabId == selectedTab.id)
        #expect(selected.activePanelId == selectedTab.id)
        #expect(selected.panelOrder == [selectedTab.id])
        #expect(try fixture.snapshotData() == before)
    }

    @Test
    func registeredNamedProjectWorktreesProduceWorkspaceScopedTargets() throws {
        let fixture = try PullRequestNavigationFixture()
        defer { fixture.close() }
        let first = fixture.addWorktree()
        let second = fixture.addWorktree()
        let firstPath = try #require(first.worktreePath)
        let secondPath = try #require(second.worktreePath)

        #expect(
            fixture.manager.pullRequestStatusTargets == [
                WorkspacePullRequestTarget(
                    workspaceID: first.id, projectID: fixture.project.id,
                    repositoryPath: fixture.project.repositoryPath, worktreePath: firstPath),
                WorkspacePullRequestTarget(
                    workspaceID: second.id, projectID: fixture.project.id,
                    repositoryPath: fixture.project.repositoryPath, worktreePath: secondPath)
            ])
    }

    @Test(arguments: [
        "main-checkout", "standalone", "catch-all", "unassigned", "missing-project", "missing-membership",
        "missing-path", "empty-path", "removed-workspace", "removed-project"
    ])
    func ineligibleOrRemovedWorkspacesCannotBeTargetsOrCallOpener(reason: String) throws {
        let fixture = try PullRequestNavigationFixture()
        defer { fixture.close() }
        let selected = try #require(fixture.manager.selectedWorkspace)
        let selectedTab = selected.openReleaseNotesPanel()
        let source = fixture.addWorktree()
        let status = fixture.status()
        let existing = source.addBrowserPanel(configuration: fixture.manager.browserPanelConfiguration)
        source.openReleaseNotesPanel()

        switch reason {
        case "main-checkout", "standalone":
            source.workspaceType = reason == "main-checkout" ? .mainCheckout : .external
        case "catch-all":
            source.projectId = fixture.manager.catchAllProject.id
            fixture.manager.catchAllProject.addWorkspace(source.id)
        case "unassigned": source.projectId = nil
        case "missing-project": source.projectId = UUID()
        case "missing-membership": fixture.project.removeWorkspace(source.id)
        case "missing-path": source.worktreePath = nil
        case "empty-path": source.worktreePath = ""
        case "removed-workspace": fixture.manager.removeWorkspace(source.id)
        case "removed-project": fixture.manager.projects.removeAll { $0.id == fixture.project.id }
        default: Issue.record("Unexpected eligibility scenario: \(reason)")
        }
        let panelOrder = source.panelOrder
        let panelIDs = Set(source.panels.keys)
        let activeTabID = source.activeTabId
        let focusedPaneID = source.activePanelId
        let before = try fixture.snapshotData()
        var openedURLs: [URL] = []

        let opened = fixture.manager.openPullRequest(
            status, in: source.id,
            openURL: {
                openedURLs.append($0)
                return true
            })

        #expect(fixture.manager.pullRequestStatusTargets.isEmpty)
        #expect(!opened)
        #expect(openedURLs.isEmpty)
        #expect(source.panelOrder == panelOrder)
        #expect(Set(source.panels.keys) == panelIDs)
        #expect(source.activeTabId == activeTabID)
        #expect(source.activePanelId == focusedPaneID)
        #expect(existing.currentURL == nil)
        #expect(fixture.manager.selectedWorkspaceId == selected.id)
        #expect(selected.activeTabId == selectedTab.id)
        #expect(selected.activePanelId == selectedTab.id)
        #expect(selected.panelOrder == [selectedTab.id])
        #expect(try fixture.snapshotData() == before)
    }
}

extension PullRequestStatusNavigationTests {
    @Test(arguments: [true, false])
    func runtimeStatusAndOpeningLeaveTheSessionSnapshotUnchanged(openSucceeds: Bool) throws {
        let fixture = try PullRequestNavigationFixture()
        defer { fixture.close() }
        let source = fixture.addWorktree()
        fixture.project.color = .blue
        let before = try fixture.snapshotData()
        try fixture.manager.saveSession(to: fixture.snapshotURL)
        let persistedBefore = try Data(contentsOf: fixture.snapshotURL)
        let model = WorkspacePullRequestStatusModel(
            provider: GitHubPullRequestService(environment: [:], executableSearchPaths: []),
            automaticallySchedules: false)
        defer { model.stop() }
        model.update(
            targets: fixture.manager.pullRequestStatusTargets,
            selectedWorkspaceID: fixture.manager.selectedWorkspaceId,
            isEnabled: true, isActive: false)
        let status = fixture.status()
        model.publish(
            WorkspacePullRequestState(
                status: status, lastSuccess: Date(timeIntervalSince1970: 1_700_000_000), hasLoaded: true),
            for: source.id)
        var openedURLs: [URL] = []
        let opened = fixture.manager.openPullRequest(
            status, in: source.id,
            openURL: {
                openedURLs.append($0)
                return openSucceeds
            })

        let snapshot = fixture.manager.makeSessionSnapshot()
        let after = try fixture.snapshotData()
        #expect(opened == openSucceeds)
        #expect(openedURLs == [status.url])
        #expect(model.state(for: source.id)?.status == status)
        #expect(after == before)
        #expect(try Data(contentsOf: fixture.snapshotURL) == persistedBefore)
        #expect(source.panels.isEmpty)
        #expect(source.panelOrder.isEmpty)
        #expect(source.activeTabId == nil)
        #expect(source.activePanelId == nil)
        #expect(snapshot.workspaces.first { $0.id == source.id }?.panelCount == 0)
        try expectDurableSnapshotFields(after, workspaceID: source.id, projectID: fixture.project.id)
    }

    private func expectDurableSnapshotFields(_ data: Data, workspaceID: UUID, projectID: UUID) throws {
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let workspaces = try #require(root["workspaces"] as? [[String: Any]])
        let workspace = try #require(workspaces.first { $0["id"] as? String == workspaceID.uuidString })
        let projects = try #require(root["projects"] as? [[String: Any]])
        let project = try #require(projects.first { $0["id"] as? String == projectID.uuidString })

        let workspaceFields: Set<String> = [
            "id", "projectId", "branchName", "workspaceType", "worktreePath", "title", "customTitle",
            "currentDirectory", "panelCount", "terminalDirectories", "terminalCustomTitles"
        ]
        #expect(Set(root.keys) == ["schemaVersion", "selectedWorkspaceId", "projects", "workspaces"])
        #expect(Set(workspace.keys) == workspaceFields)
        #expect(
            Set(project.keys) == [
                "id", "repositoryPath", "isCatchAll", "displayName", "mainBranch", "workspaceIds", "isExpanded",
                "color",
                "collapsedStackIds"
            ])
        let codingKeys = try SourceContract("Argus/Models/SessionSnapshot.swift").section(
            after: "private enum CodingKeys: String, CodingKey", before: "init(from decoder: Decoder)")
        let declaredFields = codingKeys.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
            .map { String($0.dropFirst("case ".count)) }
        #expect(Set(declaredFields) == workspaceFields)
    }
}

@MainActor
private struct PullRequestNavigationFixture {
    let suiteName: String
    let defaults: UserDefaults
    let manager: WorkspaceManager
    let project: Project
    let snapshotURL: URL

    init() throws {
        let suiteName = "ArgusTests.PullRequestStatusNavigation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-pull-request-ui-\(UUID().uuidString).json")
        let settings = AppSettings(defaults: defaults)
        settings.browserDataStore = .private
        settings.homepage = ""
        let manager = WorkspaceManager(
            settings: settings, sessionSnapshotURL: snapshotURL, environment: ["ARGUS_UNDER_TEST": "1"],
            pullRequestService: GitHubPullRequestService(environment: [:], executableSearchPaths: []))
        let project = Project(repositoryPath: "/argus-ui-tests/repository", mainBranch: "main")
        manager.projects.insert(project, at: 0)
        for workspace in manager.workspaces {
            for panelID in workspace.panelOrder { workspace.closeTab(panelID) }
        }
        self.suiteName = suiteName
        self.defaults = defaults
        self.manager = manager
        self.project = project
        self.snapshotURL = snapshotURL
    }

    func addWorktree() -> Workspace {
        let id = UUID()
        let path = "/argus-ui-tests/worktrees/\(id.uuidString)"
        let workspace = Workspace(
            snapshot: WorkspaceSnapshot(
                id: id, projectId: project.id, branchName: "feature/status", workspaceType: .worktree,
                worktreePath: path, title: "Source", customTitle: "Source Workspace", currentDirectory: path,
                panelCount: 0))
        project.addWorkspace(id)
        manager.workspaces.append(workspace)
        return workspace
    }

    func status(urlString: String = "https://reviews.invalid/team/argus/pull/42") -> PullRequestStatus {
        let repository = RepositoryIdentity(
            provider: .github, host: "reviews.invalid", owner: "team", repositoryName: "argus")
        return PullRequestStatus(
            identity: PullRequestIdentity(repository: repository, number: 42), url: URL(string: urlString)!,
            title: "Runtime-only Pull Request title", headBranchName: "feature/status",
            headCommitObjectID: String(repeating: "a", count: 40), headRepository: repository, baseBranchName: "main",
            lifecycle: .open, review: .approved, checks: PullRequestChecks(passed: 1))
    }

    func snapshotData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manager.makeSessionSnapshot())
    }

    func close() {
        for workspace in manager.workspaces {
            for panel in workspace.panels.values { panel.close() }
        }
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: snapshotURL)
    }
}
