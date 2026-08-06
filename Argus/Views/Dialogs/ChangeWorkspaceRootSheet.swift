import AppKit
import SwiftUI

struct ChangeWorkspaceRootSheetRequest: Identifiable {
    let id = UUID()
    let workspaceId: UUID
}

struct ChangeWorkspaceRootSheet: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Environment(\.dismiss) private var dismiss

    let workspaceId: UUID

    @State private var path = ""
    @State private var errorMessage: String?
    @FocusState private var pathIsFocused: Bool

    private var workspace: Workspace? {
        workspaceManager.workspaces.first { $0.id == workspaceId }
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Change Workspace Root")
                    .font(.headline)

                if let workspace {
                    Text(workspace.displayTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Path")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                HStack(spacing: 8) {
                    TextField("Enter an absolute path or ~/path", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .focused($pathIsFocused)
                        .onSubmit(apply)

                    Button("Browse…", action: browseForDirectory)
                }

                Text("Enter an existing directory. Paths beginning with ~ are supported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()

                Button("Cancel", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)

                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedPath.isEmpty || workspace == nil)
            }
        }
        .padding(24)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if path.isEmpty {
                path = workspace?.currentDirectory ?? ""
            }
            pathIsFocused = true
        }
    }

    private func browseForDirectory() {
        guard let workspace else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workspace.currentDirectory)
        panel.message = "Select the Workspace Root for \(workspace.displayTitle)"

        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }
        path = directoryURL.path
        errorMessage = nil
    }

    private func apply() {
        guard !trimmedPath.isEmpty else {
            errorMessage = "Enter a directory path."
            return
        }

        guard workspaceManager.setStandaloneWorkspaceRoot(workspaceId, path: trimmedPath) else {
            errorMessage = "That path is not an existing directory."
            return
        }

        dismiss()
    }
}

private struct ChangeWorkspaceRootSheetPresentation: ViewModifier {
    @Binding var request: ChangeWorkspaceRootSheetRequest?
    let workspaceManager: WorkspaceManager

    func body(content: Content) -> some View {
        content
            .sheet(item: $request) { request in
                ChangeWorkspaceRootSheet(workspaceId: request.workspaceId)
                    .environmentObject(workspaceManager)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showChangeWorkspaceRootSheet)) { notification in
                guard let workspaceId = notification.userInfo?["workspaceId"] as? UUID else { return }
                request = ChangeWorkspaceRootSheetRequest(workspaceId: workspaceId)
            }
    }
}

extension View {
    func changeWorkspaceRootSheet(
        request: Binding<ChangeWorkspaceRootSheetRequest?>,
        workspaceManager: WorkspaceManager
    ) -> some View {
        modifier(
            ChangeWorkspaceRootSheetPresentation(
                request: request,
                workspaceManager: workspaceManager
            )
        )
    }
}
