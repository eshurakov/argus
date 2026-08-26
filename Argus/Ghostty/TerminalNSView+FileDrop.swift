import AppKit

extension TerminalNSView {
    private static let fileURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true
    ]

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let target = fileDropTarget(atWindowPoint: sender.draggingLocation),
            let ghosttySurface = target.surface?.surface,
            let urls = droppedFileURLs(from: sender)
        else { return false }

        window?.makeFirstResponder(target)

        // Insert quoted paths without executing them, matching other terminals.
        let text = urls.map { shellQuotedPath($0.path) }.joined(separator: " ") + " "
        text.withCString { pointer in
            ghostty_surface_text(ghosttySurface, pointer, UInt(text.utf8.count))
        }
        return true
    }

    /// Resolves the terminal view a drop at `windowPoint` belongs to.
    ///
    /// Every Terminal Tab of a Workspace stays mounted in one ZStack frame, so
    /// AppKit hands the drag to the frontmost view — the last Top-level Tab —
    /// whichever Tab is Active. Route the drop to the view of the Active Tab
    /// under the pointer, which also picks the right Pane inside a split.
    func fileDropTarget(atWindowPoint windowPoint: NSPoint) -> TerminalNSView? {
        if isInActiveTab { return self }
        guard let rootView = window?.contentView else { return nil }
        return Self.activeTabTerminalViews(in: rootView).first { view in
            view.bounds.contains(view.convert(windowPoint, from: nil))
        }
    }

    private static func activeTabTerminalViews(in view: NSView) -> [TerminalNSView] {
        var views: [TerminalNSView] = []
        if let terminalView = view as? TerminalNSView,
            terminalView.isInActiveTab,
            !terminalView.isHiddenOrHasHiddenAncestor
        {
            views.append(terminalView)
        }
        for subview in view.subviews {
            views.append(contentsOf: activeTabTerminalViews(in: subview))
        }
        return views
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedFileURLs(from: sender) != nil,
            fileDropTarget(atWindowPoint: sender.draggingLocation) != nil
        else { return [] }
        return .copy
    }

    private func droppedFileURLs(from sender: NSDraggingInfo) -> [URL]? {
        guard
            let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: Self.fileURLReadingOptions
            ) as? [URL],
            !urls.isEmpty
        else { return nil }
        return urls
    }
}

private func shellQuotedPath(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
