import Foundation

private struct BaseBranchResolution {
    let name: String?
    let ref: String?
}

func buildAgainstBase(
    rootPath: String,
    presentation: GitStatusPresentation,
    currentBranch: String?
) -> BaseComparisonResult {
    let resolution = resolveBaseBranch(
        rootPath: rootPath,
        presentation: presentation,
        currentBranch: currentBranch
    )
    guard let baseName = resolution.name else {
        return unavailableBase(message: "No base branch was found for this workspace.")
    }
    guard let resolvedRef = resolution.ref else {
        return unavailableBase(
            name: baseName,
            message: "The base branch \"\(baseName)\" is unavailable locally."
        )
    }
    guard verifyGitRef(rootPath: rootPath, ref: "HEAD") else {
        return unavailableBase(
            name: baseName,
            message: "The base branch \"\(baseName)\" cannot be compared before the first commit."
        )
    }
    guard optionalGitOutput(args: ["-C", rootPath, "merge-base", resolvedRef, "HEAD"]) != nil else {
        return unavailableBase(
            name: baseName,
            message: "Could not find a merge base with \"\(baseName)\"."
        )
    }

    return loadAgainstBaseComparison(
        rootPath: rootPath,
        baseName: baseName,
        resolvedRef: resolvedRef
    )
}

private func loadAgainstBaseComparison(
    rootPath: String,
    baseName: String,
    resolvedRef: String
) -> BaseComparisonResult {
    do {
        let names = try runGit(args: [
            "-C", rootPath, "diff", "\(resolvedRef)...HEAD", "--name-status", "-z", "--find-renames"
        ])
        let stats = try runGit(args: [
            "-C", rootPath, "diff", "\(resolvedRef)...HEAD", "--numstat", "-z", "--find-renames"
        ])
        let parsedStats = GitDiffStatParser.parseNUL(stats.stdout)
        let files = GitDiffNameStatusParser.parse(names.stdout).map { record in
            let stat = parsedStats[record.path]
            return GitFileChange(
                path: record.path,
                originalPath: record.originalPath,
                status: record.status,
                additions: stat?.additions,
                deletions: stat?.deletions,
                sectionKind: .againstBase,
                hasStagedChanges: false,
                hasUnstagedChanges: false,
                isUntracked: false,
                diffSource: .againstBase(baseName: baseName, resolvedRef: resolvedRef)
            )
        }
        return BaseComparisonResult(baseName: baseName, files: files, state: .available)
    } catch let error as GitStatusServiceError {
        return unavailableBase(
            name: baseName,
            message: "Could not compare this branch with \"\(baseName)\": \(error.message)"
        )
    } catch {
        return unavailableBase(
            name: baseName,
            message: "Could not compare this branch with \"\(baseName)\": \(error.localizedDescription)"
        )
    }
}

private func resolveBaseBranch(
    rootPath: String,
    presentation: GitStatusPresentation,
    currentBranch: String?
) -> BaseBranchResolution {
    let configuredName = presentation.configuredBaseBranch?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedConfiguredName = configuredName.flatMap { name in name.isEmpty ? nil : name }
    guard normalizedConfiguredName == nil else {
        return BaseBranchResolution(
            name: normalizedConfiguredName,
            ref: normalizedConfiguredName.flatMap { resolveBaseRef(rootPath: rootPath, name: $0) }
        )
    }
    guard let inferredName = inferBaseBranchName(rootPath: rootPath, currentBranch: currentBranch) else {
        return BaseBranchResolution(name: nil, ref: nil)
    }
    let preferredRef = inferredName.preferredRef
    let ref = resolveBaseRef(rootPath: rootPath, name: inferredName.name, preferredRef: preferredRef)
    return BaseBranchResolution(name: inferredName.name, ref: ref)
}

private func inferBaseBranchName(
    rootPath: String,
    currentBranch: String?
) -> (name: String, preferredRef: String?)? {
    if let remoteHead = optionalGitOutput(
        args: ["-C", rootPath, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]
    ), remoteHead.hasPrefix("refs/remotes/origin/") {
        let candidate = String(remoteHead.dropFirst("refs/remotes/origin/".count))
        if !candidate.isEmpty, candidate != currentBranch {
            return (
                name: candidate,
                preferredRef: verifyGitRef(rootPath: rootPath, ref: "refs/remotes/origin/HEAD")
                    ? "refs/remotes/origin/HEAD"
                    : nil
            )
        }
    }
    if currentBranch != "main", verifyGitRef(rootPath: rootPath, ref: "refs/heads/main") {
        return (name: "main", preferredRef: nil)
    }
    if currentBranch != "master", verifyGitRef(rootPath: rootPath, ref: "refs/heads/master") {
        return (name: "master", preferredRef: nil)
    }
    return nil
}

private func resolveBaseRef(rootPath: String, name: String, preferredRef: String? = nil) -> String? {
    if let preferredRef, verifyGitRef(rootPath: rootPath, ref: preferredRef) {
        return preferredRef
    }
    return [
        "refs/remotes/origin/\(name)",
        "refs/heads/\(name)"
    ].first(where: { verifyGitRef(rootPath: rootPath, ref: $0) })
}

private func unavailableBase(name: String? = nil, message: String) -> BaseComparisonResult {
    BaseComparisonResult(baseName: name, files: [], state: .unavailable(message: message))
}
