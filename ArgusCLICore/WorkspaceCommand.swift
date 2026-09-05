import ArgumentParser
import ArgusIPC
import Foundation

struct WorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Inspect and create Argus Workspaces.",
        subcommands: [WorkspaceListCommand.self, WorkspaceCreateCommand.self]
    )
}

struct WorkspaceListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List Projects and their Workspaces, including Stack Groups.",
        discussion: """
            Prints Projects in left-sidebar order. The gutter shows each \
            Workspace Number, and \(WorkspaceListRenderer.selectedMarker) marks the Selected Workspace. \
            Stack Groups are printed as trees, including branch references that \
            have no open Workspace.
            """
    )

    static let responseTimeout: TimeInterval = 15

    @Flag(name: .long, help: "Print the raw JSON result instead of the rendered listing.")
    var json = false

    func run() throws {
        try ArgusCommandOutput.reportingFailures {
            let result = try ArgusCommandOutput.client(timeout: Self.responseTimeout).send(
                ArgusSocketRequest(
                    id: UUID().uuidString,
                    method: .workspaceList,
                    params: WorkspaceListParameters()
                ),
                expecting: WorkspaceListResult.self
            )
            if json {
                try ArgusCommandOutput.printJSON(result)
            } else {
                for line in WorkspaceListRenderer().lines(for: result) {
                    print(line)
                }
            }
        }
    }
}

struct WorkspaceCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a Worktree Workspace in a Project.",
        discussion: """
            Every option is optional. Without --branch, Argus generates an \
            available branch name from the Settings branch prefix. Without \
            --from, the new branch starts from the Project repository's \
            current HEAD, exactly as the in-app New Workspace sheet does. With \
            --from, it starts from that Workspace's branch and Argus records \
            the parent so both Workspaces group as a Stack.

            Argus resolves every reference. Use '.' for the Project or \
            Workspace that owns the terminal you are running in. The new \
            Workspace does not become the Selected Workspace.
            """
    )

    static let responseTimeout: TimeInterval = 300

    @Option(name: .long, help: "Project name or ID. Defaults to this terminal's Project.")
    var project: String?

    @Option(name: .long, help: "Base Workspace to stack onto: name, branch, ID, or '.'.")
    var from: String?

    @Option(
        name: .long,
        help: "New branch name. Optional; Argus otherwise generates an available name."
    )
    var branch: String?

    @Option(name: .long, help: "Custom Workspace name. Defaults to the branch name.")
    var name: String?

    @Flag(name: .long, help: "Print the raw JSON result instead of a summary.")
    var json = false

    func run() throws {
        try ArgusCommandOutput.reportingFailures {
            let environment = ProcessInfo.processInfo.environment
            let result = try ArgusCommandOutput.client(timeout: Self.responseTimeout).send(
                ArgusSocketRequest(
                    id: UUID().uuidString,
                    method: .workspaceCreate,
                    params: WorkspaceCreateParameters(
                        project: project,
                        base: from,
                        branch: branch,
                        name: name,
                        contextWorkspaceId: environment[ArgusSocketClient.workspaceIdVariable],
                        contextDirectory: FileManager.default.currentDirectoryPath
                    )
                ),
                expecting: WorkspaceCreateResult.self
            )
            if json {
                try ArgusCommandOutput.printJSON(result)
            } else {
                for line in Self.summary(for: result) {
                    print(line)
                }
            }
        }
    }

    static func summary(for result: WorkspaceCreateResult) -> [String] {
        var lines = [
            "Created Workspace \"\(result.workspace.title)\" in \(result.projectName)",
            "  branch  \(result.branch)"
        ]
        if let baseBranch = result.baseBranch {
            let state =
                result.recordedBaseBranch
                ? "recorded as the base branch"
                : "not recorded — this Workspace will not group as a Stack"
            lines.append("  base    \(baseBranch) (\(state))")
        }
        lines.append("  path    \(result.workspace.worktreePath ?? result.workspace.root)")
        return lines
    }
}
