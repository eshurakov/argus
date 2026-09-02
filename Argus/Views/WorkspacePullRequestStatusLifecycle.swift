import AppKit
import SwiftUI

struct WorkspacePullRequestStatusLifecycle: NSViewRepresentable {
    let model: WorkspacePullRequestStatusModel
    let targets: [WorkspacePullRequestTarget]
    let selectedWorkspaceID: UUID?
    let isEnabled: Bool

    func makeNSView(context: Context) -> StatusLifecycleView {
        StatusLifecycleView()
    }

    func updateNSView(_ nsView: StatusLifecycleView, context: Context) {
        nsView.configure(model: model, targets: targets, selectedWorkspaceID: selectedWorkspaceID, isEnabled: isEnabled)
    }

    static func dismantleNSView(_ nsView: StatusLifecycleView, coordinator: Void) {
        nsView.detach()
    }

    final class StatusLifecycleView: NSView {
        private weak var model: WorkspacePullRequestStatusModel?
        private var targets: [WorkspacePullRequestTarget] = []
        private var selectedWorkspaceID: UUID?
        private var isEnabled = false
        private var isSleeping = false
        private var observers: [NSObjectProtocol] = []
        private var workspaceObservers: [NSObjectProtocol] = []
        private var updateTask: Task<Void, Never>?

        func configure(
            model: WorkspacePullRequestStatusModel,
            targets: [WorkspacePullRequestTarget],
            selectedWorkspaceID: UUID?,
            isEnabled: Bool
        ) {
            guard
                self.model !== model || self.targets != targets
                    || self.selectedWorkspaceID != selectedWorkspaceID || self.isEnabled != isEnabled
            else { return }
            self.model = model
            self.targets = targets
            self.selectedWorkspaceID = selectedWorkspaceID
            self.isEnabled = isEnabled
            scheduleUpdate()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard window != nil else {
                model?.update(
                    targets: targets, selectedWorkspaceID: selectedWorkspaceID, isEnabled: isEnabled, isActive: false)
                return
            }
            observeApplicationAndWindow()
            observeSleep()
            scheduleUpdate()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func detach() {
            updateTask?.cancel()
            updateTask = nil
            removeObservers()
            model?.stop()
            model = nil
        }

        private func observeApplicationAndWindow() {
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification
            ]
            observers = names.map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleUpdate() }
                }
            }
        }

        private func observeSleep() {
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers = [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    let isSleeping = notification.name == NSWorkspace.willSleepNotification
                    MainActor.assumeIsolated {
                        self?.isSleeping = isSleeping
                        self?.scheduleUpdate()
                    }
                }
            }
        }

        private func scheduleUpdate() {
            updateTask?.cancel()
            updateTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self else { return }
                let environment = ProcessInfo.processInfo.environment
                let isTest =
                    environment["XCTestConfigurationFilePath"] != nil
                    || environment["ARGUS_UNDER_TEST"] == "1"
                    || environment["ARGUS_DISABLE_SESSION_RESTORE"] == "1"
                let active =
                    !isTest && !isSleeping && NSApp.isActive && !NSApp.isHidden
                    && window?.isVisible == true && window?.isMiniaturized == false
                model?.update(
                    targets: targets, selectedWorkspaceID: selectedWorkspaceID,
                    isEnabled: isEnabled, isActive: active
                )
            }
        }

        private func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            workspaceObservers.removeAll()
        }

        isolated deinit {
            updateTask?.cancel()
            removeObservers()
        }
    }
}
