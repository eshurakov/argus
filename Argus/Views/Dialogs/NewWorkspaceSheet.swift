// NewWorkspaceSheet.swift
// Argus
//
// Sheet dialog for creating a new workspace within a project.
// Supports creating new branches or checking out existing branches
// as git worktrees.

import SwiftUI

struct NewWorkspaceSheet: View {
    // Keep this sheet text-only: macOS 27 can raise in CUINamedVectorGlyph
    // while SwiftUI rasterizes an SF Symbol during sheet presentation.
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Environment(\.dismiss) private var dismiss

    /// The project to add the workspace to (set by the caller).
    let projectId: UUID

    @State private var workspaceName: String = ""
    @State private var branchMode: BranchMode = .new
    @State private var newBranchName: String = ""
    @State private var selectedExistingBranch: String?
    @State private var branchFilter: String = ""
    @State private var pullRequestInput: String = ""
    @State private var availableBranches: [String] = []
    @State private var isLoadingBranches: Bool = false
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?

    enum BranchMode: String, CaseIterable, Hashable {
        case new = "New Branch"
        case existing = "Existing Branch"
        case pullRequest = "Pull Request"
    }

    private static let sectionLabelFont = Font.system(size: 11, weight: .semibold)

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Text("New Workspace")
                    .font(.system(size: 15, weight: .semibold))
                if let project = workspaceManager.projects.first(where: { $0.id == projectId }) {
                    Text(project.displayName)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Optional workspace name remains a branch-source field. Pull
            // Request titles come from GitHub and are assigned by the manager.
            if branchMode != .pullRequest {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Workspace Name")
                        .font(Self.sectionLabelFont)
                        .foregroundColor(.secondary)
                    TextField("Name (optional)", text: $workspaceName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isCreating)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            // Source section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Source")
                        .font(Self.sectionLabelFont)
                        .foregroundColor(.secondary)

                    Spacer()

                    Picker("Source", selection: $branchMode) {
                        ForEach(BranchMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(isCreating)
                }

                switch branchMode {
                case .new:
                    newBranchInput
                case .existing:
                    existingBranchPicker
                case .pullRequest:
                    TextField("URL or number", text: $pullRequestInput)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.horizontal, 24)
            .disabled(isCreating)

            // Error message
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }

            Spacer(minLength: 16)

            Divider()

            // Action buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)

                Spacer()

                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                }

                Button(isCreating ? "Creating…" : "Create") {
                    createWorkspace()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if newBranchName.isEmpty {
                regenerateBranchName()
            }
            if branchMode == .existing {
                loadBranches()
            }
        }
        .onChange(of: branchMode) { _, newMode in
            guard !isCreating else { return }
            switch newMode {
            case .new:
                if newBranchName.isEmpty {
                    regenerateBranchName()
                }
            case .existing:
                if availableBranches.isEmpty && !isLoadingBranches {
                    loadBranches()
                }
            case .pullRequest:
                break
            }
        }
    }
}

extension NewWorkspaceSheet {
    // MARK: - Subviews

    @ViewBuilder
    private var newBranchInput: some View {
        HStack(spacing: 4) {
            TextField("Branch name", text: $newBranchName)
                .textFieldStyle(.plain)
            Button("Regenerate") {
                regenerateBranchName()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .help("Generate a new random branch name")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )

        if !newBranchName.isEmpty && newBranchName.contains(" ") {
            Text("Branch names cannot contain spaces")
                .font(.system(size: 11))
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var existingBranchPicker: some View {
        if isLoadingBranches {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading branches...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        } else if availableBranches.isEmpty {
            Text("No available branches")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        } else {
            TextField("Filter branches", text: $branchFilter)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredAvailableBranches, id: \.self) { branch in
                        Button(
                            action: {
                                selectedExistingBranch = branch
                            },
                            label: {
                                HStack {
                                    Text(branch)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    if selectedExistingBranch == branch {
                                        Text("Selected")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                        )
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selectedExistingBranch == branch ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                    }
                }
            }
            .frame(maxHeight: 96)
        }
    }

    // MARK: - Computed

    private var canCreate: Bool {
        if isCreating { return false }
        switch branchMode {
        case .new:
            let trimmed = newBranchName.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.contains(" ")
        case .existing:
            return selectedExistingBranch != nil
        case .pullRequest:
            return !pullRequestInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var filteredAvailableBranches: [String] {
        let filter = branchFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return availableBranches }
        return availableBranches.filter { branch in
            branch.localizedCaseInsensitiveContains(filter)
        }
    }

    // MARK: - Actions

    /// Shows a random suggestion immediately, then silently swaps it for a
    /// collision-free alternative in the background if needed — as long as
    /// the user hasn't already started typing their own name.
    private func regenerateBranchName() {
        let prefix = workspaceManager.settings.newBranchPrefix
        let candidate = RandomBranchNameGenerator.generate(prefix: prefix)
        newBranchName = candidate

        guard let project = workspaceManager.projects.first(where: { $0.id == projectId }) else { return }
        Task {
            guard
                let verified = try? await workspaceManager.worktreeService.suggestAvailableBranchName(
                    preferring: candidate,
                    prefix: prefix,
                    repositoryPath: project.repositoryPath
                ),
                verified != candidate,
                newBranchName == candidate
            else { return }
            newBranchName = verified
        }
    }

    private func loadBranches() {
        guard let project = workspaceManager.projects.first(where: { $0.id == projectId }) else { return }
        isLoadingBranches = true
        Task {
            defer { isLoadingBranches = false }
            do {
                let branches = try await workspaceManager.worktreeService.listWorkspaceBranchChoices(
                    repositoryPath: project.repositoryPath
                )
                availableBranches = branches
                if let selectedExistingBranch,
                    !branches.contains(selectedExistingBranch)
                {
                    self.selectedExistingBranch = nil
                }
            } catch {
                availableBranches = []
                errorMessage = error.localizedDescription
            }
        }
    }

    private func createWorkspace() {
        guard branchMode != .existing || selectedExistingBranch != nil else { return }
        isCreating = true
        errorMessage = nil

        Task {
            defer { isCreating = false }
            switch branchMode {
            case .pullRequest: await createPullRequestWorkspace()
            case .new, .existing: await createBranchWorkspace()
            }
        }
    }

    private func createPullRequestWorkspace() async {
        let trimmedInput = pullRequestInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await workspaceManager.createWorkspace(
                fromPullRequest: trimmedInput,
                in: projectId
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createBranchWorkspace() async {
        guard let branchSelection = branchSelection else { return }
        let trimmedName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await workspaceManager.addWorkspaceToProject(
            projectId,
            branchName: branchSelection.branchName,
            createNewBranch: branchSelection.createNewBranch,
            customTitle: trimmedName.isEmpty ? nil : trimmedName
        )

        if result != nil {
            dismiss()
        } else {
            showBranchCreationError()
        }
    }

    private var branchSelection: (branchName: String, createNewBranch: Bool)? {
        switch branchMode {
        case .new:
            return (newBranchName.trimmingCharacters(in: .whitespaces), true)
        case .existing:
            guard let selectedExistingBranch else { return nil }
            return (selectedExistingBranch, false)
        case .pullRequest:
            return nil
        }
    }

    private func showBranchCreationError() {
        switch workspaceManager.lastWorkspaceCreationError {
        case .branchAlreadyExists(let branchName):
            errorMessage = "Branch '\(branchName)' already exists"
        default:
            errorMessage =
                workspaceManager.lastWorkspaceCreationError?.localizedDescription
                ?? "Failed to create workspace"
        }
    }
}
