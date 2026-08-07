import Foundation
import Testing

@testable import Argus

@Suite(.serialized)
@MainActor
struct BrowserPanelTests {
    @Test
    func schemeLessAddressesDefaultToHTTPS() throws {
        #expect(BrowserPanel.resolvedURL(from: "example.com/path")?.absoluteString == "https://example.com/path")
        #expect(BrowserPanel.resolvedURL(from: "localhost:8080")?.absoluteString == "https://localhost:8080")
        #expect(BrowserPanel.resolvedURL(from: "http://example.com")?.absoluteString == "http://example.com")
        #expect(BrowserPanel.resolvedURL(from: "  ") == nil)
    }

    @Test
    func searchProviderOnlyClassifiesQueriesWhenEnabled() {
        #expect(
            BrowserPanel.resolvedURL(from: "example.com/docs", searchProvider: .none)?.absoluteString
                == "https://example.com/docs"
        )
        #expect(
            BrowserPanel.resolvedURL(from: "swift concurrency", searchProvider: .none)
                == BrowserNavigationPolicy.directURL(from: "swift concurrency")
        )
        #expect(
            BrowserPanel.resolvedURL(from: "swift concurrency", searchProvider: .google)?.absoluteString
                == "https://www.google.com/search?q=swift%20concurrency"
        )
    }

    @Test
    func homepageAlwaysUsesDirectURLResolution() {
        let panel = BrowserPanel(
            configuration: .init(
                homepage: "data:text/html,Argus",
                searchProvider: .google,
                pageZoom: 1,
                developerToolsEnabled: false,
                dataStore: .private
            ))
        defer { panel.close() }

        #expect(panel.currentURL?.absoluteString == "data:text/html,Argus")
    }

    @Test
    func browserSettingsMapToPublicWebKitProperties() {
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let panel = BrowserPanel(
            id: id,
            currentURL: URL(string: "data:text/html,Argus"),
            configuration: .init(
                homepage: "",
                searchProvider: .none,
                pageZoom: 1.25,
                developerToolsEnabled: true,
                dataStore: .private
            )
        )
        defer { panel.close() }

        #expect(panel.id == id)
        #expect(panel.webView.pageZoom == 1.25)
        #expect(panel.webView.isInspectable)

        panel.pageZoom = 1.5
        panel.developerToolsEnabled = false
        #expect(panel.webView.pageZoom == 1.5)
        #expect(!panel.webView.isInspectable)
    }

    @Test
    func browserUsesNormalTopLevelTabLifecycle() throws {
        let workspace = Workspace(workingDirectory: "/tmp")
        let firstTab = try #require(workspace.panelOrder.first)
        workspace.addTerminalPanel(workingDirectory: "/tmp/second")
        workspace.selectPanel(firstTab)

        let browser = workspace.addBrowserPanel(
            url: URL(string: "data:text/html,Argus"),
            configuration: .init(
                homepage: "",
                searchProvider: .none,
                pageZoom: 1,
                developerToolsEnabled: false,
                dataStore: .private
            )
        )
        #expect(workspace.panelOrder[1] == browser.id)
        #expect(workspace.activeTabId == browser.id)

        workspace.closeTab(browser.id)
        #expect(workspace.panels[browser.id] == nil)
        #expect(!workspace.panelOrder.contains(browser.id))
    }
}
