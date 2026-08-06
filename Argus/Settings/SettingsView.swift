import AppKit
import SwiftUI

enum SettingsSection: CaseIterable, Identifiable {
    case general
    case appearance
    case terminal
    case filesAndChanges
    case browser
    case agent

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .terminal: "Terminal"
        case .filesAndChanges: "Files & Changes"
        case .browser: "Browser"
        case .agent: "Agent"
        }
    }
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var section: SettingsSection = .general
}

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigationModel

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var kiloIntegration: KiloIntegrationModel
    @EnvironmentObject private var piIntegration: PiIntegrationModel

    var body: some View {
        Group {
            switch navigation.section {
            case .general: general
            case .appearance: appearance
            case .terminal: terminal
            case .filesAndChanges: filesAndChanges
            case .browser: browser
            case .agent: agent
            }
        }
        .frame(width: 560, height: 520)
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
            Picker("Interface text size", selection: $settings.interfaceTextSize) {
                ForEach(10...14, id: \.self) { size in
                    Text("\(size) pt").tag(Double(size))
                }
            }
            Picker("Document text size", selection: $settings.documentTextSize) {
                ForEach(10...24, id: \.self) { size in
                    Text("\(size) pt").tag(Double(size))
                }
            }
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
                Picker("Default zoom", selection: $settings.defaultZoom) {
                    ForEach(5...20, id: \.self) { zoomStep in
                        Text("\(zoomStep * 10)%").tag(Double(zoomStep) / 10)
                    }
                }
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

            Section("Pi Integration") {
                LabeledContent("Status") { Text(piStatusTitle) }
                LabeledContent("Managed extension") {
                    Text(piIntegration.managedExtensionPath)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(piIntegration.managedExtensionPath)
                }
                HStack {
                    Button("Enable") { piIntegration.enable() }
                        .disabled(piIntegration.status == .busy || piIntegration.status == .installed)
                    Button("Disable") { piIntegration.disable() }
                        .disabled(piIntegration.status == .busy)
                    if piIntegration.status == .busy { ProgressView().controlSize(.small) }
                }
                if case .failed(let error) = piIntegration.status {
                    Text(error).foregroundStyle(.red)
                }
                Text("Restart running Pi sessions or use /reload after changing this integration.")
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

    private var piStatusTitle: String {
        switch piIntegration.status {
        case .unavailable: "Not enabled"
        case .installed: "Enabled — restart or reload Pi sessions required"
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
