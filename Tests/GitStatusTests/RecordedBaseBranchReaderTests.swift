import Foundation
import Testing

@testable import Argus

// Bound concurrent Git fixture setup so it cannot starve async process tests.
@Suite(.serialized)
struct RecordedBaseBranchReaderTests {
    @Test
    func configOnlyUsesEffectiveLastValuesAndPreservesMissingParentNames() throws {
        let fixture = try RecordedParentRepository()
        try fixture.git(["config", "--add", "branch.feature/api.v2.base", "older-parent"])
        try fixture.git(["config", "--add", "branch.feature/api.v2.base", "missing/parent.v1"])
        try fixture.git(["config", "branch.next.base", "feature/api.v2"])
        try fixture.git(["config", "branch.main.base", "root"])
        try fixture.git(["config", "branch.feature/api.v2.remote", "unrelated-value"])
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["feature/api.v2": "missing/parent.v1", "next": "feature/api.v2", "main": "root"])
        #expect(snapshot.trunkBranches.isEmpty)
        #expect(snapshot.issue == nil)
    }

    @Test
    func commonConfigurationIncludesGlobalValuesButLocalLastValueWins() throws {
        let fixture = try RecordedParentRepository()
        try fixture.git(["config", "--file", fixture.globalConfig.path, "branch.global-only.base", "global-parent"])
        try fixture.git(["config", "--file", fixture.globalConfig.path, "branch.child.base", "global-parent"])
        try fixture.git(["config", "--add", "branch.child.base", "first-local-parent"])
        try fixture.git(["config", "--add", "branch.child.base", "last-local-parent"])
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["global-only": "global-parent", "child": "last-local-parent"])
        #expect(snapshot.issue == nil)
    }

    @Test(arguments: [false, true])
    func worktreeOverridesBindToTheirCurrentBranchIndependentOfStartingCheckout(_ separate: Bool) throws {
        let fixture = try RecordedParentRepository()
        if separate {
            try fixture.git([
                "init", "--separate-git-dir", fixture.directory.appendingPathComponent("git data\nwith spaces ").path
            ]
            )
        }
        let linked = try fixture.addWorktree(branch: "topic/child")
        try fixture.git(["config", "extensions.worktreeConfig", "true"])
        try fixture.git(["config", "branch.topic/child.base", "common-parent"])
        try fixture.git(["config", "branch.unchecked.base", "common-only"])
        try fixture.git(["config", "--worktree", "branch.unchecked.base", "not-current"])
        try fixture.git(["config", "--worktree", "branch.topic/child.base", "wrong-checkout"])
        try fixture.git(["config", "--worktree", "branch.main.base", "main-parent"])
        try fixture.git(["config", "--worktree", "branch.topic/child.base", "linked-parent"], checkout: linked)
        let snapshot = try fixture.read()
        #expect(snapshot.parents == (try fixture.read(checkout: linked)).parents)
        #expect(snapshot.parents == ["main": "main-parent", "topic/child": "linked-parent", "unchecked": "common-only"])
        #expect(snapshot.worktrees.contains(GitWorktreeBranch(path: fixture.repository.path, branch: "main")))
        #expect(snapshot.worktrees.contains(GitWorktreeBranch(path: linked.path, branch: "topic/child")))
        #expect(snapshot.issue == nil)
        try fixture.git(["config", "branch.topic/child.base", "bad..parent"])
        #expect(try fixture.read() == snapshot)
        try fixture.git(["config", "branch.topic/child.base", "common-parent"])
        try fixture.git(["switch", "-c", "topic/changed"], checkout: linked)
        try fixture.git(["config", "--worktree", "branch.topic/changed.base", "changed-parent"], checkout: linked)
        let changed = try fixture.read()
        #expect(changed.parents == (try fixture.read(checkout: linked)).parents)
        #expect(changed.parents["topic/child"] == "common-parent")
        #expect(changed.parents["topic/changed"] == "changed-parent")
    }

    @Test
    func separateDirectoryInventoryVerifiesInitiatorWithoutInventingMain() throws {
        let fixture = try RecordedParentRepository()
        let metadata = fixture.directory.appendingPathComponent("separate metadata ")
        try fixture.git(["init", "--separate-git-dir", metadata.path])
        let linked = try fixture.addWorktree(branch: "child")
        try fixture.git(["config", "extensions.worktreeConfig", "true"])
        try fixture.git(["config", "--worktree", "branch.main.base", "main-parent"])
        try fixture.git(["config", "--worktree", "branch.child.base", "linked-parent"], checkout: linked)
        let rootSnapshot = try fixture.read()
        #expect(
            rootSnapshot.worktrees == [
                GitWorktreeBranch(path: fixture.repository.path, branch: "main"),
                GitWorktreeBranch(path: linked.path, branch: "child")
            ])
        let linkedSnapshot = try fixture.read(checkout: linked)
        #expect(linkedSnapshot.worktrees == [GitWorktreeBranch(path: linked.path, branch: "child")])
        #expect(linkedSnapshot.parents == rootSnapshot.parents)
        #expect(linkedSnapshot.parents == ["main": "main-parent", "child": "linked-parent"])
        let nested = fixture.repository.appendingPathComponent("nested directory")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        #expect(try fixture.read(checkout: nested) == rootSnapshot)
        try fixture.git(["config", "--worktree", "core.worktree", fixture.repository.path])
        let located = try fixture.read(checkout: linked)
        #expect(located.worktrees == rootSnapshot.worktrees)
        #expect(located.parents == rootSnapshot.parents)
    }

    @Test
    func malformedMainWorktreeConfigDoesNotBlockHealthyLinkedMetadata() throws {
        let fixture = try RecordedParentRepository()
        let linked = try fixture.addWorktree(branch: "child")
        let commonDirectory = try fixture.gitDirectory()
        try fixture.git(["config", "extensions.worktreeConfig", "true"])
        try fixture.git(["config", "branch.child.base", "common-parent"])
        try fixture.git(["config", "--worktree", "branch.child.base", "linked-parent"], checkout: linked)
        try fixture.graphite("independent", parent: "other")
        try Data("[branch \"main\"\n".utf8).write(to: commonDirectory.appendingPathComponent("config.worktree"))
        #expect(try fixture.git(["status", "--porcelain"], checkout: linked).isEmpty)
        #expect(try fixture.git(["config", "--get", "branch.child.base"], checkout: linked) == "linked-parent")
        let before = try fixture.files()
        let snapshot = try fixture.read(checkout: linked)
        #expect(snapshot.parents == ["child": "linked-parent", "independent": "other"])
        #expect(snapshot.worktrees.contains(GitWorktreeBranch(path: linked.path, branch: "child")))
        #expect(!snapshot.diagnostics.isEmpty)
        #expect(try fixture.files() == before)
    }

    @Test
    func failedInventoryRecoversOtherVerifiedRegistrationsButNotPrunableCheckouts() throws {
        let fixture = try RecordedParentRepository()
        let child = try fixture.addWorktree(branch: "child")
        let parent = try fixture.addWorktree(branch: "parent")
        let removed = try fixture.addWorktree(branch: "removed")
        let commonDirectory = try fixture.gitDirectory()
        try fixture.git(["config", "extensions.worktreeConfig", "true"])
        try fixture.git(["config", "--worktree", "branch.child.base", "parent"], checkout: child)
        try fixture.git(["config", "--worktree", "branch.parent.base", "trunk"], checkout: parent)
        try FileManager.default.removeItem(at: removed)
        try Data("[broken\n".utf8).write(to: commonDirectory.appendingPathComponent("config.worktree"))
        let before = try fixture.files()
        let snapshot = try fixture.read(checkout: child)
        #expect(Set(snapshot.worktrees.map(\.path)) == [child.path, parent.path])
        #expect(snapshot.parents == ["child": "parent", "parent": "trunk"])
        #expect(try fixture.files() == before)
    }

    @Test
    func globalGitDirectoryAndOnBranchIncludesUseEachRegisteredCheckout() throws {
        let fixture = try RecordedParentRepository()
        let linked = try fixture.addWorktree(branch: "topic/child")
        let scoped = fixture.directory.appendingPathComponent("conditional-config")
        let onBranch = fixture.directory.appendingPathComponent("on-branch-config")
        let gitDirectory = try fixture.gitDirectory(checkout: linked)
        try fixture.git(["config", "--file", scoped.path, "branch.topic/child.base", "gitdir-parent"])
        try fixture.git([
            "config", "--file", fixture.globalConfig.path,
            "includeIf.gitdir:\(gitDirectory.path).path", scoped.path
        ])
        try fixture.git(["config", "--file", onBranch.path, "branch.topic/child.base", "onbranch-parent"])
        try fixture.git(["config", "includeIf.onbranch:topic/*.path", onBranch.path])
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["topic/child": "onbranch-parent"])
        #expect(snapshot == (try fixture.read(checkout: linked)))
        try fixture.git(["config", "--unset", "includeIf.onbranch:topic/*.path"])
        let globalOnly = try fixture.read()
        #expect(globalOnly.parents == ["topic/child": "gitdir-parent"])
        #expect(globalOnly == (try fixture.read(checkout: linked)))
    }

    @Test
    func duplicateCheckoutsDiagnoseDifferentEffectiveExplicitParents() throws {
        let fixture = try RecordedParentRepository()
        let first = try fixture.addWorktree(branch: "child")
        let second = try fixture.addWorktree(branch: "child", directoryName: "duplicate", existing: true)
        try fixture.git(["config", "extensions.worktreeConfig", "true"])
        try fixture.git(["config", "branch.child.base", "common"])
        try fixture.git(["config", "branch.descendant.base", "child"])
        try fixture.git(["config", "--worktree", "branch.child.base", "first-parent"], checkout: first)
        try fixture.git(["config", "--worktree", "branch.child.base", "second-parent"], checkout: second)
        try fixture.graphite("child", parent: "tool-parent")
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["descendant": "child"])
        #expect(Set(snapshot.conflicts.keys) == ["child"])
        #expect(snapshot.issue?.contains("'child'") == true)
        #expect(snapshot.issue?.contains("'first-parent'") == true)
        #expect(snapshot.issue?.contains("'second-parent'") == true)
        #expect(snapshot == (try fixture.read(checkout: second)))
        try fixture.git(["config", "--worktree", "branch.child.base", "first-parent"], checkout: second)
        let matching = try fixture.read()
        #expect(matching.parents == ["child": "first-parent", "descendant": "child"])
        #expect(matching.issue == nil)
    }
}
