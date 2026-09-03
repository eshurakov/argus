import SwiftUI

extension Notification.Name {
    static let showCollectionSheet = Notification.Name("ArgusShowCollectionSheet")
}

struct CollectionSheetRequest: Identifiable {
    let id = UUID()
    var collectionId: UUID?
    var name = ""
}

struct CollectionNameSheet: View {
    let request: CollectionSheetRequest
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    @FocusState private var isNameFocused: Bool

    init(request: CollectionSheetRequest) {
        self.request = request
        _name = State(initialValue: request.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.collectionId == nil ? "New Collection" : "Rename Collection")
                .font(.headline)
            TextField("Collection name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .accessibilityIdentifier("collection-name")
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.collectionId == nil ? "Create" : "Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ProjectCollection.normalizedName(name) == nil)
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear { isNameFocused = true }
    }

    private func save() {
        let saved: Bool
        if let collectionId = request.collectionId {
            saved = workspaceManager.renameCollection(collectionId, name: name)
        } else {
            saved = workspaceManager.createCollection(name: name) != nil
        }
        if saved {
            dismiss()
        } else {
            error = "The Collection is unavailable or the Collection limit has been reached."
        }
    }
}
