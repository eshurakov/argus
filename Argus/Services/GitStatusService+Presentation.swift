import Foundation

private struct GitStatusDiffStats {
    let staged: [String: GitDiffStat]
    let unstaged: [String: GitDiffStat]
    let untracked: [String: GitDiffStat]
}

struct BaseComparisonResult: Sendable {
    let baseName: String?
    let files: [GitFileChange]
    let state: GitChangeSectionState
}

private struct GitStatusNetComparison {
    let isAvailable: Bool
    let records: [String: GitDiffNameStatusRecord]
    let stats: [String: GitDiffStat]
}

private struct GitStatusUncommittedRows {
    let staged: [String: GitFileChange]
    let unstaged: [String: GitFileChange]
    let untracked: [String: GitFileChange]
}

private struct GitStatusPresentationProjection {
    let rootPath: String
    let rawStatus: GitStatusRawSnapshot
    let request: GitStatusRequest
    let uncommittedFiles: [GitFileChange]
    let base: BaseComparisonResult
    let sections: [GitChangeSection]
    let activeCount: Int
}

func statusSynchronously(request: GitStatusRequest) -> GitStatusLoadState {
    let rootPath = request.rootPath
    do {
        let result = try runGit(args: [
            "-C", rootPath, "status", "--porcelain=v2", "--branch", "--untracked-files=all"
        ])
        let rawStatus = GitStatusPorcelainParser.parseUncapped(result.stdout)
        let unstagedOutput = try? runGit(args: ["-C", rootPath, "diff", "--numstat"]).stdout
        let stagedOutput = try? runGit(args: ["-C", rootPath, "diff", "--cached", "--numstat"]).stdout
        let stats = GitStatusDiffStats(
            staged: GitDiffStatParser.parse(stagedOutput ?? ""),
            unstaged: GitDiffStatParser.parse(unstagedOutput ?? ""),
            untracked: diffStatsForUntrackedFiles(rootPath: rootPath, files: rawStatus.untrackedFiles)
        )
        return .loaded(
            buildPresentationSummary(
                rawStatus: rawStatus,
                request: request,
                rootPath: rootPath,
                stats: stats
            )
        )
    } catch let error as GitStatusServiceError {
        switch error {
        case .notRepository:
            return .notRepository(rootPath: rootPath)
        case .commandFailed(let message):
            return .error(rootPath: rootPath, message: message)
        }
    } catch {
        return .error(rootPath: rootPath, message: error.localizedDescription)
    }
}

private func buildPresentationSummary(
    rawStatus: GitStatusRawSnapshot,
    request: GitStatusRequest,
    rootPath: String,
    stats: GitStatusDiffStats
) -> GitStatusSummary {
    let fullWorking = GitStatusSummary(
        rootPath: rootPath,
        branchName: rawStatus.branchName,
        upstreamName: rawStatus.upstreamName,
        aheadCount: rawStatus.aheadCount,
        behindCount: rawStatus.behindCount,
        stagedCount: rawStatus.stagedFiles.count,
        unstagedCount: rawStatus.unstagedFiles.count,
        untrackedCount: rawStatus.untrackedFiles.count,
        stagedFiles: rawStatus.stagedFiles,
        unstagedFiles: rawStatus.unstagedFiles,
        untrackedFiles: rawStatus.untrackedFiles
    ).applying(
        stagedStats: stats.staged,
        unstagedStats: stats.unstaged,
        untrackedStats: stats.untracked
    )
    let uncommittedFiles =
        request.presentation.combineWorkingChangeSections
        ? buildUncommittedFiles(rootPath: rootPath, rawStatus: rawStatus, stats: stats)
        : []
    let base =
        request.presentation.showBaseBranchChanges
        ? buildAgainstBase(
            rootPath: rootPath,
            presentation: request.presentation,
            currentBranch: rawStatus.branchName
        )
        : BaseComparisonResult(baseName: nil, files: [], state: .available)
    let sections = buildPresentationSections(
        fullWorking: fullWorking,
        uncommittedFiles: uncommittedFiles,
        base: base,
        presentation: request.presentation
    )
    let activeCount =
        sections
        .filter(\.state.isAvailable)
        .reduce(0) { $0 + $1.totalCount }
    return makePresentationSummary(
        GitStatusPresentationProjection(
            rootPath: rootPath,
            rawStatus: rawStatus,
            request: request,
            uncommittedFiles: uncommittedFiles,
            base: base,
            sections: sections,
            activeCount: activeCount
        ))
}

private func makePresentationSummary(_ projection: GitStatusPresentationProjection) -> GitStatusSummary {
    let rawStatus = projection.rawStatus
    return GitStatusSummary(
        rootPath: projection.rootPath,
        branchName: rawStatus.branchName,
        upstreamName: rawStatus.upstreamName,
        aheadCount: rawStatus.aheadCount,
        behindCount: rawStatus.behindCount,
        stagedCount: rawStatus.stagedFiles.count,
        unstagedCount: rawStatus.unstagedFiles.count,
        untrackedCount: rawStatus.untrackedFiles.count,
        stagedFiles: displayedFiles(in: projection.sections, kind: .staged),
        unstagedFiles: displayedFiles(in: projection.sections, kind: .unstaged),
        untrackedFiles: displayedFiles(in: projection.sections, kind: .untracked),
        uncommittedCount: projection.uncommittedFiles.count,
        uncommittedFiles: displayedFiles(in: projection.sections, kind: .uncommitted),
        againstBaseCount: projection.base.files.count,
        againstBaseFiles: displayedFiles(in: projection.sections, kind: .againstBase),
        againstBaseState: projection.base.state,
        sections: projection.sections,
        combineWorkingChangeSections: projection.request.presentation.combineWorkingChangeSections,
        showBaseBranchChanges: projection.request.presentation.showBaseBranchChanges,
        isFileDisplayCapped: projection.activeCount > GitStatusSummary.displayFileLimit,
        totalFileCount: projection.activeCount
    )
}

private func buildPresentationSections(
    fullWorking: GitStatusSummary,
    uncommittedFiles: [GitFileChange],
    base: BaseComparisonResult,
    presentation: GitStatusPresentation
) -> [GitChangeSection] {
    var remaining = GitStatusSummary.displayFileLimit
    var sections: [GitChangeSection] = []

    func appendSection(
        kind: GitChangeSectionKind,
        files: [GitFileChange],
        totalCount: Int,
        state: GitChangeSectionState = .available
    ) {
        guard case .available = state else {
            sections.append(
                GitChangeSection(
                    kind: kind,
                    title: kind == .againstBase ? "Against \(base.baseName ?? "Base")" : kind.title,
                    totalCount: 0,
                    files: [],
                    state: state
                ))
            return
        }
        let displayFiles = Array(files.prefix(max(remaining, 0)))
        remaining -= displayFiles.count
        sections.append(
            GitChangeSection(
                kind: kind,
                title: kind == .againstBase ? "Against \(base.baseName ?? "Base")" : kind.title,
                totalCount: totalCount,
                files: displayFiles,
                state: state
            ))
    }

    if presentation.combineWorkingChangeSections {
        appendSection(kind: .uncommitted, files: uncommittedFiles, totalCount: uncommittedFiles.count)
    } else {
        appendSection(kind: .staged, files: fullWorking.stagedFiles, totalCount: fullWorking.stagedCount)
        appendSection(kind: .unstaged, files: fullWorking.unstagedFiles, totalCount: fullWorking.unstagedCount)
        appendSection(kind: .untracked, files: fullWorking.untrackedFiles, totalCount: fullWorking.untrackedCount)
    }
    if presentation.showBaseBranchChanges {
        appendSection(kind: .againstBase, files: base.files, totalCount: base.files.count, state: base.state)
    }
    return sections
}

private func displayedFiles(in sections: [GitChangeSection], kind: GitChangeSectionKind) -> [GitFileChange] {
    sections.first(where: { $0.kind == kind })?.files ?? []
}

private func buildUncommittedFiles(
    rootPath: String,
    rawStatus: GitStatusRawSnapshot,
    stats: GitStatusDiffStats
) -> [GitFileChange] {
    let netComparison = loadNetComparison(rootPath: rootPath)
    let rows = GitStatusUncommittedRows(
        staged: Dictionary(uniqueKeysWithValues: rawStatus.stagedFiles.map { ($0.path, $0) }),
        unstaged: Dictionary(uniqueKeysWithValues: rawStatus.unstagedFiles.map { ($0.path, $0) }),
        untracked: Dictionary(uniqueKeysWithValues: rawStatus.untrackedFiles.map { ($0.path, $0) })
    )
    return uniqueChangedPaths(in: rawStatus).map {
        makeUncommittedFile(path: $0, rows: rows, stats: stats, netComparison: netComparison)
    }
}

private func loadNetComparison(rootPath: String) -> GitStatusNetComparison {
    guard verifyGitRef(rootPath: rootPath, ref: "HEAD"),
        let nameStatus = try? runGit(
            args: ["-C", rootPath, "diff", "HEAD", "--name-status", "-z", "--find-renames"]
        ),
        let numstat = try? runGit(
            args: ["-C", rootPath, "diff", "HEAD", "--numstat", "-z", "--find-renames"]
        )
    else {
        return GitStatusNetComparison(isAvailable: false, records: [:], stats: [:])
    }
    let records = Dictionary(
        uniqueKeysWithValues: GitDiffNameStatusParser.parse(nameStatus.stdout).map { ($0.path, $0) }
    )
    return GitStatusNetComparison(
        isAvailable: true,
        records: records,
        stats: GitDiffStatParser.parseNUL(numstat.stdout)
    )
}

private func uniqueChangedPaths(in rawStatus: GitStatusRawSnapshot) -> [String] {
    var seen: Set<String> = []
    return (rawStatus.stagedFiles + rawStatus.unstagedFiles + rawStatus.untrackedFiles).compactMap { file in
        seen.insert(file.path).inserted ? file.path : nil
    }
}

private func makeUncommittedFile(
    path: String,
    rows: GitStatusUncommittedRows,
    stats: GitStatusDiffStats,
    netComparison: GitStatusNetComparison
) -> GitFileChange {
    let staged = rows.staged[path]
    let unstaged = rows.unstaged[path]
    let untracked = rows.untracked[path]
    let net = netComparison.records[path]
    let status =
        staged?.status == .unmerged || unstaged?.status == .unmerged
        ? .unmerged
        : net?.status ?? untracked?.status ?? unstaged?.status ?? staged?.status ?? .modified
    let isCanceledNetDiff = netComparison.isAvailable && net == nil && untracked == nil
    let statistic =
        isCanceledNetDiff
        ? GitDiffStat(additions: 0, deletions: 0, isBinary: false)
        : netComparison.stats[path] ?? stats.untracked[path] ?? stats.unstaged[path] ?? stats.staged[path]
    return GitFileChange(
        path: path,
        originalPath: net?.originalPath ?? unstaged?.originalPath ?? staged?.originalPath,
        status: status,
        additions: statistic?.additions,
        deletions: statistic?.deletions,
        sectionKind: .uncommitted,
        hasStagedChanges: staged != nil,
        hasUnstagedChanges: unstaged != nil,
        isUntracked: untracked != nil,
        diffSource: .uncommitted,
        isNetDiffEmpty: isCanceledNetDiff
    )
}
