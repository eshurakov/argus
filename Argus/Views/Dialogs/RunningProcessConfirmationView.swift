import SwiftUI

enum RunningProcessCloseScope: Equatable {
    case pane(workspaceId: UUID, panelId: UUID)
    case tab(workspaceId: UUID, tabId: UUID)
    case surface(workspaceId: UUID, surfaceId: UUID)
    case application
}

struct RunningProcessCloseRequest: Equatable {
    let scope: RunningProcessCloseScope
    let processCount: Int
}

/// In-view confirmation avoids presenting an alert while a SwiftUI context menu
/// is dismissing, which crashes in macOS 27's vector-glyph renderer.
struct RunningProcessConfirmationView: View {
    let request: RunningProcessCloseRequest
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button(confirmTitle, action: onConfirm)
                        .foregroundStyle(.red)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(maxWidth: 420)
            .background(ChromeColors.contentBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(ChromeColors.separator, lineWidth: 1)
            }
            .shadow(radius: 16)
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var title: String {
        switch request.scope {
        case .application:
            return "Quit Argus?"
        case .tab where request.processCount > 1:
            return "Close Tab?"
        case .pane, .tab, .surface:
            return "Close Terminal?"
        }
    }

    private var confirmTitle: String {
        switch request.scope {
        case .application:
            return "Quit"
        case .tab where request.processCount > 1:
            return "Close Tab"
        case .pane, .tab, .surface:
            return "Close Terminal"
        }
    }

    private var message: String {
        switch request.scope {
        case .application:
            if request.processCount == 1 {
                return "A terminal still has a running process. Quitting will terminate that process."
            }
            return "One or more terminals still have a running process. Quitting will terminate those processes."
        case .tab where request.processCount > 1:
            return
                "This tab has \(request.processCount) terminals with running processes. "
                + "Closing it will terminate those processes."
        case .pane, .tab, .surface:
            return "This terminal still has a running process. Closing it will terminate that process."
        }
    }
}
