import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let navigation = SettingsNavigationModel()

    init(
        settings: AppSettings,
        kiloIntegration: KiloIntegrationModel,
        piIntegration: PiIntegrationModel
    ) {
        let rootView = SettingsView(navigation: navigation)
            .environmentObject(settings)
            .environmentObject(kiloIntegration)
            .environmentObject(piIntegration)
        let contentController = NSHostingController(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = SettingsSection.general.title
        window.contentViewController = contentController
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()

        super.init(window: window)

        let toolbar = NSToolbar(identifier: "ArgusSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .labelOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = toolbarIdentifier(for: .general)
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        select(.general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsSection.allCases.map(toolbarIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let section = section(for: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = section.title
        item.paletteLabel = section.title
        item.toolTip = section.title
        item.target = self
        item.action = #selector(selectToolbarItem(_:))
        return item
    }

    @objc private func selectToolbarItem(_ sender: NSToolbarItem) {
        guard let section = section(for: sender.itemIdentifier) else { return }
        select(section)
    }

    private func select(_ section: SettingsSection) {
        guard let window else { return }
        navigation.section = section
        window.title = section.title
        window.toolbar?.selectedItemIdentifier = toolbarIdentifier(for: section)
    }

    private func toolbarIdentifier(for section: SettingsSection) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("ArgusSettings.\(String(describing: section))")
    }

    private func section(for identifier: NSToolbarItem.Identifier) -> SettingsSection? {
        SettingsSection.allCases.first { toolbarIdentifier(for: $0) == identifier }
    }
}
