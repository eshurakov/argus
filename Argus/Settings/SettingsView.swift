import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var kiloIntegration: KiloIntegrationModel

    var body: some View {
        TabView {
            general
                .tabItem { tabLabel("General", icon: "gear") }
            appearance
                .tabItem { tabLabel("Appearance", icon: "textformat") }
            terminal
                .tabItem { tabLabel("Terminal", icon: "terminal") }
            filesAndChanges
                .tabItem { tabLabel("Files & Changes", icon: "doc.text") }
            browser
                .tabItem { tabLabel("Browser", icon: "globe") }
            agent
                .tabItem { tabLabel("Agent", icon: "bell") }
        }
        .frame(width: 560, height: 430)
    }

    private func tabLabel(_ title: String, icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            SemanticIcon(name: icon, pointSize: 13, weight: .regular)
        }
    }

    private var general: some View {
        Form {
            Toggle("Restore previous session", isOn: $settings.restorePreviousSession)

            Picker("Default Right-sidebar View", selection: $settings.defaultRightSidebarView) {
                ForEach(AppSettings.RightSidebarView.allCases) { view in
                    Text(view.title).tag(view)
                }
            }

            LabeledContent("Default Standalone Workspace Directory") {
                HStack {
                    Text(settings.defaultStandaloneWorkspaceDirectory)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.defaultStandaloneWorkspaceDirectory)
                        .accessibilityValue(settings.defaultStandaloneWorkspaceDirectory)
                    Button("Choose...") { chooseStandaloneWorkspaceDirectory() }
                    Button("Reset to Home") { settings.resetStandaloneWorkspaceDirectoryToHome() }
                }
            }

            Section("New Workspaces") {
                TextField("Branch prefix", text: $settings.newBranchPrefix, prompt: Text("e.g. eshurakov"))
                Text("Prepended to auto-generated branch names for new workspaces.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var appearance: some View {
        Form {
            Stepper(
                "Interface text size: \(Int(settings.interfaceTextSize))",
                value: $settings.interfaceTextSize,
                in: 10...14
            )
            Stepper(
                "Document text size: \(Int(settings.documentTextSize))",
                value: $settings.documentTextSize,
                in: 10...24
            )
            Picker("Interface density", selection: $settings.interfaceDensity) {
                ForEach(AppSettings.InterfaceDensity.allCases) { density in
                    Text(density.title).tag(density)
                }
            }
            Section("Application Shell") {
                LabeledContent("Shell background") { Text("Black (fixed)") }
                LabeledContent("Terminal appearance") { Text("Ghostty configuration") }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var terminal: some View {
        Form {
            Toggle("Audible bell", isOn: $settings.audibleBell)

            Section("Ghostty Configuration") {
                LabeledContent("Configuration path") {
                    Text(GhosttyConfig.standardConfigurationURL.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(GhosttyConfig.standardConfigurationURL.path)
                        .accessibilityValue(GhosttyConfig.standardConfigurationURL.path)
                }
                HStack {
                    Button("Reveal in Finder") { revealGhosttyConfiguration() }
                    Button("Open Configuration") { openGhosttyConfiguration() }
                    Button("Reload Configuration") {
                        GhosttyApp.shared.reloadConfiguration(source: "settings")
                    }
                }
                Text("Font, theme, and background remain configured by Ghostty.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var filesAndChanges: some View {
        Form {
            Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
            Toggle("Wrap source lines", isOn: $settings.wrapSourceLines)
            Toggle("Open Markdown in preview", isOn: $settings.openMarkdownInPreview)
            Toggle("Open SVG in preview", isOn: $settings.openSVGInPreview)
            Picker("Default diff style", selection: $settings.defaultDiffStyle) {
                ForEach(AppSettings.DiffStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            Picker("Default diff overflow", selection: $settings.defaultDiffOverflow) {
                ForEach(AppSettings.DiffOverflow.allCases) { overflow in
                    Text(overflow.title).tag(overflow)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var browser: some View {
        Form {
            Section("Defaults for New Browser Tabs") {
                TextField("Homepage", text: $settings.homepage, prompt: Text("about:blank"))
                Text("Leave empty to open about:blank.")
                    .foregroundStyle(.secondary)
                Picker("Search provider", selection: $settings.searchProvider) {
                    ForEach(BrowserPanelConfiguration.SearchProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                Stepper(
                    "Default zoom: \(Int(settings.defaultZoom * 100))%",
                    value: $settings.defaultZoom,
                    in: 0.5...2,
                    step: 0.1
                )
                Toggle("Enable Web Inspector", isOn: $settings.webInspectorEnabled)
                Picker("Data store", selection: $settings.browserDataStore) {
                    ForEach(BrowserPanelConfiguration.DataStore.allCases) { dataStore in
                        Text(dataStore.title).tag(dataStore)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var agent: some View {
        Form {
            Toggle("Agent completion sound", isOn: $settings.agentCompletionSound)

            Section("Kilo Integration") {
                LabeledContent("Status") { Text(kiloStatusTitle) }
                LabeledContent("Managed configuration") {
                    Text(kiloIntegration.managedConfigPath)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(kiloIntegration.managedConfigPath)
                }
                HStack {
                    Button("Enable") { kiloIntegration.enable() }
                        .disabled(kiloIntegration.status == .busy || kiloIntegration.status == .installed)
                    Button("Disable") { kiloIntegration.disable() }
                        .disabled(kiloIntegration.status == .busy)
                    if kiloIntegration.status == .busy { ProgressView().controlSize(.small) }
                }
                if case .failed(let error) = kiloIntegration.status {
                    Text(error).foregroundStyle(.red)
                }
                Text(
                    "Restart running Kilo sessions after changing this integration. "
                        + "Kilo cannot prove whether every ordinary user message was typed by a person."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var kiloStatusTitle: String {
        switch kiloIntegration.status {
        case .unavailable: "Not enabled"
        case .installed: "Enabled — restart Kilo sessions required"
        case .busy: "Updating"
        case .failed: "Configuration error"
        }
    }

    private func chooseStandaloneWorkspaceDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.defaultStandaloneWorkspaceDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.defaultStandaloneWorkspaceDirectory = url.standardizedFileURL.path
    }

    private func revealGhosttyConfiguration() {
        let url = GhosttyConfig.standardConfigurationURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openGhosttyConfiguration() {
        let url = GhosttyConfig.standardConfigurationURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.open(url)
    }
}
