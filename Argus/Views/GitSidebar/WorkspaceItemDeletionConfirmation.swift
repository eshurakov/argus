import SwiftUI

struct WorkspaceItemDeletionRequest: Equatable {
    let item: WorkspaceFileTreeNode
    let rootPath: String
    let initiatingRequest: WorkspaceFileTreeRequest
}

/// In-view confirmation avoids the macOS 27 CoreUI crash triggered when an
/// AppKit alert renders during a dismissing SwiftUI context menu.
struct WorkspaceItemDeletionConfirmation: View {
    let request: WorkspaceItemDeletionRequest
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 12) {
                Text("Delete \(itemKind)?")
                    .font(.headline)

                Text("This will permanently delete \(request.item.path) from disk.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Delete", action: onConfirm)
                        .foregroundStyle(.red)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(maxWidth: 360)
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
    }

    private var itemKind: String {
        switch request.item.content {
        case .directory:
            "Folder"
        case .file:
            "File"
        }
    }
}
