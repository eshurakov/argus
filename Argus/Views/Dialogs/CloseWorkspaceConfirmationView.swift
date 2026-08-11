import SwiftUI

struct CloseWorkspaceRequest: Equatable {
    let id: UUID
    let title: String
    let worktreePath: String
    let requestedByLastTerminalTab: Bool
    let canDeleteWorktree: Bool
    let runningProcessCount: Int
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
            var text = "Closing the last terminal tab will close \(request.title)."
            text += processConsequenceSentence
            text += " Do you want to close the workspace?"
            if request.canDeleteWorktree {
                text += " You can also delete its git worktree at \(request.worktreePath)."
            }
            return text
        }
        if request.canDeleteWorktree && request.runningProcessCount > 0 {
            return
                "Closing \(request.title) will terminate \(processPhrase). "
                + "Do you also want to delete its git worktree at \(request.worktreePath)?"
        }
        if request.canDeleteWorktree {
            return "Do you also want to delete the git worktree for \(request.title) at \(request.worktreePath)?"
        }
        return "Closing \(request.title) will terminate \(processPhrase)."
    }

    private var processConsequenceSentence: String {
        switch request.runningProcessCount {
        case 0:
            return ""
        case 1:
            return " That will terminate a running process."
        default:
            return " That will terminate \(request.runningProcessCount) running processes."
        }
    }

    private var processPhrase: String {
        request.runningProcessCount == 1
            ? "a running process"
            : "\(request.runningProcessCount) running processes"
    }
}
