import CoreGraphics
import Foundation
import Testing

@testable import Argus

@Suite
struct SidebarStatePersistenceTests {
    @Test
    func sidebarVisibilityAndWidthPersistAcrossInstances() async throws {
        try await MainActor.run {
            let suiteName = "com.argus.tests.sidebar-state.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let sidebar = SidebarState(defaults: defaults)
            sidebar.isVisible = false
            sidebar.width = 333

            let restoredSidebar = SidebarState(defaults: defaults)
            assertEqual(restoredSidebar.isVisible, false, "left sidebar visibility restores")
            assertEqual(restoredSidebar.width, 333, "left sidebar width restores")

            let gitSidebar = GitSidebarState(defaults: defaults)
            gitSidebar.isVisible = true
            gitSidebar.width = 444
            gitSidebar.selectedView = .files

            let restoredGitSidebar = GitSidebarState(defaults: defaults)
            assertEqual(restoredGitSidebar.isVisible, true, "right sidebar visibility restores")
            assertEqual(restoredGitSidebar.width, 444, "right sidebar width restores")
            assertEqual(restoredGitSidebar.selectedView, .files, "right sidebar View restores")
        }
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
