import Combine
import Foundation

extension Workspace {
    /// Adds a panel to this workspace at the end of the tab order.
    func addPanel(_ panel: any Panel) {
        panels[panel.id] = panel
        observeBrowserPanel(panel)
        panelOrder.append(panel.id)
        tabLayouts[panel.id] = .leaf(panel.id)
        if activePanelId == nil {
            activePanelId = panel.id
        }
    }

    @discardableResult
    func addTerminalPanel(workingDirectory: String? = nil) -> TerminalPanel {
        let panel = TerminalPanel(
            workspaceId: id,
            workingDirectory: workingDirectory ?? currentDirectory
        )
        panels[panel.id] = panel
        panelOrder.append(panel.id)
        tabLayouts[panel.id] = .leaf(panel.id)
        selectPanel(panel.id)
        return panel
    }

    @discardableResult
    func openFilePanel(rootPath: String, relativePath: String) -> FilePanel {
        let standardizedRootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        if let existing = panels.values.compactMap({ $0 as? FilePanel }).first(where: {
            $0.rootPath == standardizedRootPath && $0.relativePath == relativePath
        }) {
            selectPanel(existing.id)
            return existing
        }

        let panel = FilePanel(rootPath: standardizedRootPath, relativePath: relativePath)
        panels[panel.id] = panel
        insertAfterActiveTab(panel.id)
        tabLayouts[panel.id] = .leaf(panel.id)
        selectPanel(panel.id)
        return panel
    }

    @discardableResult
    func addBrowserPanel(
        url: URL? = nil,
        configuration: BrowserPanelConfiguration = .default
    ) -> BrowserPanel {
        let panel = BrowserPanel(currentURL: url, configuration: configuration)
        panels[panel.id] = panel
        observeBrowserPanel(panel)
        insertAfterActiveTab(panel.id)
        tabLayouts[panel.id] = .leaf(panel.id)
        selectPanel(panel.id)
        return panel
    }

    @discardableResult
    func openReleaseNotesPanel() -> ReleaseNotesPanel {
        if let existing = panels.values.compactMap({ $0 as? ReleaseNotesPanel }).first {
            selectPanel(existing.id)
            return existing
        }

        let panel = ReleaseNotesPanel()
        panels[panel.id] = panel
        insertAfterActiveTab(panel.id)
        tabLayouts[panel.id] = .leaf(panel.id)
        selectPanel(panel.id)
        return panel
    }

    @discardableResult
    func openGitPreviewPanel(rootPath: String, preview: GitPreview) -> GitPreviewPanel {
        let standardizedRootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        if let existing = panels.values.compactMap({ $0 as? GitPreviewPanel }).first(where: {
            $0.rootPath == standardizedRootPath
                && $0.preview.kind == preview.kind
                && $0.preview.path == preview.path
        }) {
            existing.update(preview: preview)
            selectPanel(existing.id)
            return existing
        }

        let panel = GitPreviewPanel(rootPath: standardizedRootPath, preview: preview)
        panels[panel.id] = panel
        insertAfterActiveTab(panel.id)
        tabLayouts[panel.id] = .leaf(panel.id)
        selectPanel(panel.id)
        return panel
    }

    func updateOpenFilePanel(rootPath: String, oldPath: String, newPath: String) {
        let standardizedRootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        for panel in panels.values.compactMap({ $0 as? FilePanel })
        where panel.rootPath == standardizedRootPath && panel.relativePath == oldPath {
            panel.updatePath(rootPath: standardizedRootPath, relativePath: newPath)
        }
    }

    private func insertAfterActiveTab(_ panelId: UUID) {
        if let tabId = activeTabId,
            let activeIndex = panelOrder.firstIndex(of: tabId)
        {
            panelOrder.insert(panelId, at: activeIndex + 1)
        } else {
            panelOrder.append(panelId)
        }
    }

    private func observeBrowserPanel(_ panel: any Panel) {
        guard let browser = panel as? BrowserPanel else { return }
        panelCancellables[browser.id] = browser.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

extension Workspace {
    @discardableResult
    func splitActiveTerminal(direction: PanelSplitDirection) -> TerminalPanel? {
        guard let activePanelId,
            let activeTerminal = panels[activePanelId] as? TerminalPanel,
            let tabId = activeTabId
        else { return nil }

        let panel = TerminalPanel(
            workspaceId: id,
            workingDirectory: activeTerminal.directory.isEmpty ? currentDirectory : activeTerminal.directory
        )
        panels[panel.id] = panel
        let split = PanelLayoutNode.split(
            direction: direction,
            ratio: 0.5,
            first: .leaf(activePanelId),
            second: .leaf(panel.id)
        )
        tabLayouts[tabId] = layout(for: tabId).replacingLeaf(activePanelId, with: split)
        selectPanel(panel.id)
        return panel
    }

    func removePanel(_ panelId: UUID) {
        closePane(panelId)
    }

    func closeTab(_ tabId: UUID) {
        guard let removedIndex = panelOrder.firstIndex(of: tabId) else { return }
        let leafIds = layout(for: tabId).leaves
        let removedPanels = leafIds.compactMap { panels.removeValue(forKey: $0) }
        for leafId in leafIds {
            terminalCustomTitles.removeValue(forKey: leafId)
            panelCancellables.removeValue(forKey: leafId)
        }
        panelOrder.remove(at: removedIndex)
        tabLayouts.removeValue(forKey: tabId)
        removedPanels.forEach { $0.close() }

        if let activePanelId, leafIds.contains(activePanelId) {
            let nextIndex = min(removedIndex, panelOrder.count - 1)
            if panelOrder.indices.contains(nextIndex) {
                selectPanel(panelOrder[nextIndex])
            } else {
                self.activePanelId = nil
            }
        }
    }

    func closePane(_ panelId: UUID) {
        guard panels[panelId] != nil,
            let tabId = panelOrder.first(where: { layout(for: $0).contains(panelId) })
        else { return }
        let oldLayout = layout(for: tabId)
        guard oldLayout.leaves.count > 1 else {
            closeTab(tabId)
            return
        }
        guard let newLayout = oldLayout.removingLeaf(panelId) else { return }

        let removedPanel = panels.removeValue(forKey: panelId)
        panelCancellables.removeValue(forKey: panelId)
        let tabTitle = terminalCustomTitles.removeValue(forKey: panelId)
        replaceTabRootIfNeeded(
            panelId,
            tabId: tabId,
            layout: newLayout,
            tabTitle: tabTitle
        )
        removedPanel?.close()
        if activePanelId == panelId, let nextId = newLayout.leaves.first {
            selectPanel(nextId)
        }
    }

    func closeActivePaneOrTab() {
        guard let activePanelId else { return }
        closePane(activePanelId)
    }

    func selectPanel(_ panelId: UUID) {
        let focusPanelId =
            panelOrder.contains(panelId)
            ? layout(for: panelId).leaves.first ?? panelId
            : panelId
        guard panels[focusPanelId] != nil else { return }
        if activePanelId == focusPanelId {
            panels[focusPanelId]?.focus()
            return
        }
        if let previousId = activePanelId, let previous = panels[previousId] {
            previous.unfocus()
        }
        activePanelId = focusPanelId
        panels[focusPanelId]?.focus()
    }

    func selectPreviousTab() {
        guard let activeTabId,
            let activeIndex = panelOrder.firstIndex(of: activeTabId),
            !panelOrder.isEmpty
        else { return }
        let previousIndex = (activeIndex - 1 + panelOrder.count) % panelOrder.count
        selectPanel(panelOrder[previousIndex])
    }

    func selectNextTab() {
        guard let activeTabId,
            let activeIndex = panelOrder.firstIndex(of: activeTabId),
            !panelOrder.isEmpty
        else { return }
        selectPanel(panelOrder[(activeIndex + 1) % panelOrder.count])
    }

    func reorderPanel(from source: Int, to destination: Int) {
        guard source >= 0, source < panelOrder.count,
            destination >= 0, destination <= panelOrder.count,
            source != destination
        else { return }
        let panelId = panelOrder.remove(at: source)
        panelOrder.insert(panelId, at: min(destination, panelOrder.count))
    }

    private func replaceTabRootIfNeeded(
        _ panelId: UUID,
        tabId: UUID,
        layout: PanelLayoutNode,
        tabTitle: String?
    ) {
        guard panelId == tabId,
            let tabIndex = panelOrder.firstIndex(of: tabId),
            let replacementTabId = layout.leaves.first
        else {
            tabLayouts[tabId] = layout
            return
        }
        panelOrder[tabIndex] = replacementTabId
        tabLayouts.removeValue(forKey: tabId)
        tabLayouts[replacementTabId] = layout
        if let tabTitle, panels[replacementTabId] is TerminalPanel {
            terminalCustomTitles[replacementTabId] = tabTitle
        }
    }
}

extension Workspace {
    func renameTerminalPanel(_ panelId: UUID, title newTitle: String) {
        guard panelOrder.contains(panelId), panels[panelId] is TerminalPanel else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            terminalCustomTitles.removeValue(forKey: panelId)
        } else {
            terminalCustomTitles[panelId] = trimmed
        }
    }

    func updateTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && title != trimmed {
            title = trimmed
        }
    }

    func setCustomTitle(_ newTitle: String?) {
        customTitle = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
