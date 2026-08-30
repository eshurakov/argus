import Foundation

enum GitStatusServiceError: Error {
    case notRepository
    case commandFailed(String)

    var message: String {
        switch self {
        case .notRepository: "Not a git repository"
        case .commandFailed(let message): message
        }
    }
}

func performOperationSynchronously(
    _ operation: GitStatusFileOperation,
    rootPath: String,
    paths: [String]
) throws {
    let literalPaths = paths.map(literalGitPathspec)
    switch operation {
    case .stage:
        _ = try runGit(args: ["-C", rootPath, "add", "--"] + literalPaths)
    case .unstage:
        try unstage(rootPath: rootPath, pathspecs: literalPaths)
    case .discard:
        _ = try runGit(args: ["-C", rootPath, "restore", "--"] + literalPaths)
    case .delete:
        for path in paths {
            try deletePath(rootPath: rootPath, path: path)
        }
    case .addToGitignore:
        for path in paths {
            try addPathToGitignore(rootPath: rootPath, path: path)
        }
    }
}

func performSectionOperationSynchronously(
    _ operation: GitStatusFileOperation,
    rootPath: String,
    sectionKind: GitChangeSectionKind
) throws {
    switch sectionKind {
    case .staged:
        try performStagedSectionOperation(operation, rootPath: rootPath)
    case .unstaged:
        try performUnstagedSectionOperation(operation, rootPath: rootPath)
    case .untracked:
        try performUntrackedSectionOperation(operation, rootPath: rootPath)
    case .uncommitted:
        try performUncommittedSectionOperation(operation, rootPath: rootPath)
    case .againstBase:
        throw unsupportedSectionOperation()
    }
}

private func performStagedSectionOperation(
    _ operation: GitStatusFileOperation,
    rootPath: String
) throws {
    guard operation == .unstage else { throw unsupportedSectionOperation() }
    try unstage(rootPath: rootPath, pathspecs: ["."])
}

private func performUnstagedSectionOperation(
    _ operation: GitStatusFileOperation,
    rootPath: String
) throws {
    switch operation {
    case .stage:
        _ = try runGit(args: ["-C", rootPath, "add", "-u", "--", "."])
    case .discard:
        _ = try runGit(args: ["-C", rootPath, "restore", "--", "."])
    default:
        throw unsupportedSectionOperation()
    }
}

private func performUntrackedSectionOperation(
    _ operation: GitStatusFileOperation,
    rootPath: String
) throws {
    switch operation {
    case .stage:
        let untrackedPaths = try allUntrackedPaths(rootPath: rootPath)
        if !untrackedPaths.isEmpty {
            _ = try runGit(args: ["-C", rootPath, "add", "--"] + untrackedPaths)
        }
    case .delete:
        _ = try runGit(args: ["-C", rootPath, "clean", "-fd", "--", "."])
    default:
        throw unsupportedSectionOperation()
    }
}

private func performUncommittedSectionOperation(
    _ operation: GitStatusFileOperation,
    rootPath: String
) throws {
    switch operation {
    case .stage:
        _ = try runGit(args: ["-C", rootPath, "add", "--", "."])
    case .unstage:
        try unstage(rootPath: rootPath, pathspecs: ["."])
    case .discard:
        _ = try runGit(args: ["-C", rootPath, "restore", "--", "."])
    case .delete:
        _ = try runGit(args: ["-C", rootPath, "clean", "-fd", "--", "."])
    case .addToGitignore:
        throw unsupportedSectionOperation()
    }
}

private func unsupportedSectionOperation() -> GitStatusServiceError {
    .commandFailed("Unsupported section file operation")
}

private func literalGitPathspec(_ path: String) -> String {
    ":(literal)\(path)"
}

private func unstage(rootPath: String, pathspecs: [String]) throws {
    if verifyGitRef(rootPath: rootPath, ref: "HEAD") {
        _ = try runGit(args: ["-C", rootPath, "restore", "--staged", "--"] + pathspecs)
    } else {
        // Before the first commit every index entry is an addition. Removing it
        // from the index preserves the working-tree file and implements Unstage.
        _ = try runGit(
            args: ["-C", rootPath, "rm", "-r", "--cached", "--force", "--ignore-unmatch", "--"]
                + pathspecs
        )
    }
}

private func allUntrackedPaths(rootPath: String) throws -> [String] {
    let result = try runGit(args: ["-C", rootPath, "ls-files", "--others", "--exclude-standard", "-z"])
    return result.stdout
        .split(separator: "\u{0}", omittingEmptySubsequences: true)
        .map { literalGitPathspec(String($0)) }
}
