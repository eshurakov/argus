import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct BrowserPanelConfigurationTests {
    @Test
    func browserConfigurationAppliesOnlyWhenPanelIsCreated() async {
        await MainActor.run {
            let configuration = BrowserPanelConfiguration(
                homepage: "https://argus.local/home",
                searchProvider: .google,
                pageZoom: 1.25,
                developerToolsEnabled: true,
                dataStore: .private
            )
            let homepagePanel = BrowserPanel(configuration: configuration)
            defer { homepagePanel.close() }
            #expect(homepagePanel.currentURL?.absoluteString == "https://argus.local/home")
            #expect(homepagePanel.webView.pageZoom == 1.25)
            #expect(homepagePanel.webView.isInspectable)
            #expect(!homepagePanel.webView.configuration.websiteDataStore.isPersistent)
            #expect(homepagePanel.navigate(to: "swift concurrency"))
            #expect(
                homepagePanel.currentURL?.absoluteString
                    == "https://www.google.com/search?q=swift%20concurrency"
            )

            let explicitURL = URL(string: "https://example.com/explicit")!
            let explicitPanel = BrowserPanel(currentURL: explicitURL, configuration: configuration)
            defer { explicitPanel.close() }
            #expect(explicitPanel.currentURL == explicitURL)

            let blankPanel = BrowserPanel(
                configuration: .init(
                    homepage: "",
                    searchProvider: .bing,
                    pageZoom: 1,
                    developerToolsEnabled: false,
                    dataStore: .persistent
                )
            )
            defer { blankPanel.close() }
            #expect(blankPanel.currentURL == nil)
            #expect(blankPanel.webView.configuration.websiteDataStore.isPersistent)
        }
    }

    @Test
    func browserSearchResolutionPreservesURLsAndEncodesQueries() {
        #expect(
            BrowserPanel.resolvedURL(from: "swift async await", searchProvider: .duckDuckGo)?.absoluteString
                == "https://duckduckgo.com/?q=swift%20async%20await"
        )
        #expect(
            BrowserPanel.resolvedURL(from: "https://example.com/a b", searchProvider: .google)?.scheme == "https"
        )
        #expect(
            BrowserPanel.resolvedURL(from: "example.com/path", searchProvider: .bing)?.absoluteString
                == "https://example.com/path"
        )
        #expect(
            BrowserPanel.resolvedURL(from: "search words", searchProvider: .none)
                == BrowserNavigationPolicy.directURL(from: "search words")
        )
    }
}
