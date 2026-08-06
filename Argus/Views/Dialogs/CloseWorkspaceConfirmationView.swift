import SwiftUI

struct CloseWorkspaceRequest: Equatable {
    let id: UUID
    let title: String
    let worktreePath: String
    let requestedByLastTerminalTab: Bool
    let canDeleteWorktree: Bool
}

/// In-view confirmation avoids presenting an alert while a SwiftUI context menu
/// is dismissing, which crashes in macOS 27's vector-glyph renderer.
struct CloseWorkspaceConfirmationView: View {
    let request: CloseWorkspaceRequest
    let onCancel: () -> Void
    let onCloseOnly: () -> Void
    let onDeleteWorktree: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 12) {
                Text("Close Workspace?")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                buttons
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

    private var buttons: some View {
        HStack {
            Spacer()
            Button(request.requestedByLastTerminalTab ? "Keep Terminal" : "Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(request.canDeleteWorktree ? "Close Only" : "Close Workspace", action: onCloseOnly)
                .foregroundStyle(.red)
                .keyboardShortcut(request.canDeleteWorktree ? nil : .defaultAction)
            if request.canDeleteWorktree {
                Button("Delete Worktree and Close", action: onDeleteWorktree)
                    .foregroundStyle(.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var message: String {
        if request.requestedByLastTerminalTab {
            var text =
                "Closing the last terminal tab will close \(request.title). "
                + "Do you want to close the workspace?"
            if request.canDeleteWorktree {
                text += " You can also delete its git worktree at \(request.worktreePath)."
            }
            return text
        }
        return "Do you also want to delete the git worktree for \(request.title) at \(request.worktreePath)?"
    }
}
