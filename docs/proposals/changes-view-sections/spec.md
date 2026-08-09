# Configurable Changes View sections

## Status

- Lifecycle: Implemented
- Implementation: Complete
- Implemented: 2026-08-06
- Last reviewed: 2026-08-07
- Stable contract: Promoted to `docs/SPEC.md` on 2026-08-06

This proposal records the accepted behavior and its implementation history.
The promoted stable behavior is authoritative in `docs/SPEC.md`.

## Summary

Argus adds two independent global settings for the Changes View:

1. **Combine working changes**
2. **Show committed changes against Base Branch**

Both settings default to disabled. The first setting changes only the
presentation and interaction model for working-tree changes. The second adds a
read-only section containing committed changes between a Base Branch and
`HEAD`.

The settings combine as follows:

| Combine working changes | Show base changes | Change Sections, in order |
| --- | --- | --- |
| Off | Off | Staged, Unstaged, Untracked |
| On | Off | Uncommitted |
| Off | On | Staged, Unstaged, Untracked, Against `<base>` |
| On | On | Uncommitted, Against `<base>` |

Working-change sections always precede Against Base. Enabling Against Base is
additive; it never hides or replaces working changes.

## Goals

- Preserve the existing Staged, Unstaged, and Untracked workflow by default.
- Allow users who do not organize their work around the Git index to see one
  deduplicated Uncommitted section.
- Allow committed branch work to remain visible after the working tree becomes
  clean.
- Use a Pull Request-style three-dot comparison against the Base Branch.
- Keep Git Mutations scoped to uncommitted work and keep Against Base read-only.
- Preserve current Workspace ownership, automatic refresh, display bounds,
  confirmation, preview-tab, and focus behavior.
- Keep the feature local and offline: status refresh must not fetch or otherwise
  contact a remote.

## Non-goals

This proposal does not add:

- a Base Branch picker;
- per-Workspace settings;
- automatic `git fetch`, pull, merge, or rebase;
- commit creation, history, or per-commit sections;
- Pull Request discovery or GitHub integration;
- a new diff presentation surface;
- new Session Snapshot state;
- changes to Project main-branch detection during Project creation;
- a combined destructive action that discards every kind of uncommitted work;
  or
- changes to the default Changes View while both settings are disabled.

## Terminology

### Working Changes

The staged, unstaged, and untracked state reported for the Git Status Root.
Working Changes determine whether the titlebar reports a dirty working tree.

### Uncommitted

A Change Section containing one row per unique path with any Working Changes.
The row represents the net content difference between `HEAD` and the working
tree while retaining whether the path has staged, unstaged, or untracked state.

### Base Branch

The branch against which Argus compares committed work. A Named Project uses its
configured `Project.mainBranch`. A Standalone Workspace attempts limited local
detection described below.

The Base Branch is distinct from the current branch and from its upstream
tracking branch.

### Against Base

A read-only Change Section containing the committed path differences from the
merge base of the resolved Base Branch and `HEAD` to `HEAD`.

## Settings behavior

The Files & Changes Settings tab places its common Files preferences first,
then contains these two native toggles in a labeled Changes section after the
diff defaults:

- `Combine working changes`
- `Show committed changes against Base Branch`

Supporting text remains visually attached to each toggle and explains:

- the first toggle combines only Working Changes and does not alter the index;
- the second toggle adds a read-only Against Base section; and
- the comparison uses Git data already stored locally without contacting or
  updating a remote.

The settings use these application properties and `UserDefaults` keys:

```swift
@Published var combineWorkingChangeSections: Bool
// Argus.settings.filesAndChanges.combineWorkingChangeSections

@Published var showBaseBranchChanges: Bool
// Argus.settings.filesAndChanges.showBaseBranchChanges
```

Both properties use `false` as their missing-key fallback. They are persisted
with the other canonical App Settings values.

Changing either setting applies immediately to the selected Workspace. It must
not:

- change the Selected Workspace;
- change the Active Tab or Focused Pane;
- close or replace an existing Git Preview Tab;
- reset the Right Sidebar selection; or
- become part of the Session Snapshot.

## Status request and ownership

Git status output depends on more than the Git Status Root after this feature.
Introduce explicit request configuration rather than reading App Settings from
the service:

```swift
struct GitStatusPresentation: Equatable, Hashable, Sendable {
    let combineWorkingChangeSections: Bool
    let showBaseBranchChanges: Bool
    let configuredBaseBranch: String?
}

struct GitStatusRequest: Equatable, Hashable, Sendable {
    let rootPath: String
    let presentation: GitStatusPresentation
}

struct GitStatusSnapshotOwner: Equatable, Hashable, Sendable {
    let workspaceId: UUID
    let request: GitStatusRequest
}
```

`GitStatusRootContext` gains the optional configured Project main branch.
`gitStatusContext(workspace:project:)` supplies it only for a non-Catch-all
Project.

The view model, service protocol, refresh requests, mutation completion
refreshes, pending refresh bookkeeping, and auto-refresh callback all carry the
same request. A setting change therefore creates a new snapshot owner even when
the Workspace and Git Status Root have not changed.

Late results are published only when both the request generation and complete
snapshot owner still match. A result produced for one setting combination must
never appear under another combination.

## Typed Change Sections and diff sources

Replace new string-based Change Section routing with typed values:

```swift
enum GitChangeSectionKind: String, Equatable, Hashable, Sendable {
    case staged
    case unstaged
    case untracked
    case uncommitted
    case againstBase
}

enum GitDiffSource: Equatable, Hashable, Sendable {
    case staged
    case unstaged
    case untracked
    case uncommitted
    case againstBase(baseName: String, resolvedRef: String)
}
```

`GitFileChange` will use `sectionKind` instead of `sectionKey` and will include:

- `hasStagedChanges`;
- `hasUnstagedChanges`;
- `isUntracked`; and
- `diffSource`.

Classic Staged, Unstaged, and Untracked entries set only the state applicable
to that entry. A combined Uncommitted entry may have both staged and unstaged
flags.

The loaded summary exposes an ordered collection of presentation-ready
sections:

```swift
struct GitChangeSection: Equatable, Sendable, Identifiable {
    let kind: GitChangeSectionKind
    let title: String
    let totalCount: Int
    let files: [GitFileChange]
    let state: GitChangeSectionState
}

enum GitChangeSectionState: Equatable, Sendable {
    case available
    case unavailable(message: String)
}
```

The summary retains full staged, unstaged, and untracked counts even when they
are presented through Uncommitted. Those counts drive dirty state and
subset-specific Section Operations.

## Working Changes

Argus continues to obtain authoritative index and working-tree state with:

```text
git status --porcelain=v2 --branch --untracked-files=all
```

Classic sections preserve current parsing, ordering, statistics, actions, and
preview behavior.

### Building Uncommitted

When combination is enabled, create the Uncommitted section from the union of
all staged, unstaged, and untracked paths.

For a repository with `HEAD`, obtain the net tracked-file status and statistics
with NUL-delimited commands equivalent to:

```text
git diff HEAD --name-status -z --find-renames
git diff HEAD --numstat -z --find-renames
```

Merge those results with the porcelain status records:

1. Use the net `HEAD`-to-working-tree status and original path when available.
2. Retain staged and unstaged flags from porcelain status.
3. Append untracked paths with empty old content and current file content.
4. If the same path is staged and unstaged, emit one row with both flags.
5. If staged and unstaged changes cancel in the final working-tree content,
   retain the row because the repository is still dirty; report zero net
   additions/deletions and show an explanatory empty-diff preview.
6. Preserve rename, copy, type-change, unmerged, binary, and unavailable-stat
   behavior.

For an unborn repository, build the union from porcelain status and treat
staged additions and untracked files as empty-old-content additions. Failure to
resolve `HEAD` must not turn an otherwise valid new repository into a status
error.

Uncommitted rows sort and build the Change Tree with the same rules used by
classic sections.

## Base Branch resolution

Base Branch work runs only when `showBaseBranchChanges` is enabled.

### Named Projects

Use the trimmed, non-empty `Project.mainBranch` as the Base Branch name.

Resolve refs without shell interpolation and without network access:

1. `refs/remotes/origin/<base-name>`
2. `refs/heads/<base-name>`

The first verified ref wins. The section title uses the configured branch name,
for example `Against main`, even when the resolved ref is `origin/main`.

### Standalone Workspaces

When no configured Project main branch exists, detect a Base Branch from the
Git Status Root:

1. resolve `refs/remotes/origin/HEAD` and use its target branch;
2. verify local `refs/heads/main`;
3. verify local `refs/heads/master`.

Do not fall back to the current branch; doing so would silently produce an
empty and misleading comparison. Do not scan arbitrary remotes or infer a base
from branch naming.

After selecting a branch name, retain an already resolved remote-HEAD ref when
applicable. Otherwise apply the same origin-first, local-second ref precedence.

### Unavailable Base Branch

The following conditions make only the Against Base section unavailable:

- no Base Branch name can be configured or detected;
- neither the remote-tracking nor local configured ref exists;
- no merge base exists;
- `HEAD` is unborn; or
- the comparison command fails.

Working Changes remain loaded and actionable. The section is shown after the
working sections with a concise message, such as:

- `No base branch was found for this workspace.`
- `The base branch "main" is unavailable locally.`
- `Could not compare this branch with "main": <git detail>`

The section has no row or Section Operations while unavailable. A manual or
automatic refresh retries resolution.

## Against Base computation

After resolving the ref, compute committed changes with NUL-delimited commands
equivalent to:

```text
git diff <resolved-ref>...HEAD --name-status -z --find-renames
git diff <resolved-ref>...HEAD --numstat -z --find-renames
```

The three-dot comparison intentionally uses the merge base so the section
represents work introduced by the current branch after divergence. Working
Changes are excluded; they appear only in the working sections.

Against Base rows:

- use `GitChangeSectionKind.againstBase`;
- carry the resolved ref in `GitDiffSource`;
- retain original paths for renames and copies;
- show status, path, and available addition/deletion statistics; and
- are sorted and grouped through the normal Change Tree.

A path may appear once in Uncommitted and once in Against Base because those
rows describe different comparisons. It may likewise appear in Against Base
and one or both classic working sections.

## Counts, limits, and clean state

Build uncapped section data first, then apply the global 500-entry display cap
in visible section order:

1. Staged, Unstaged, Untracked; or
2. Uncommitted;
3. Against Base, when enabled.

Each section retains its complete `totalCount` even when no rows remain after an
earlier section consumes the display limit. The truncation message reports
change entries rather than claiming every entry is a unique file.

The Right Sidebar Changes badge and branch-bar total use the sum of active
section entry counts. A path represented in two comparison contexts therefore
counts twice. This is intentional because the badge summarizes actionable or
inspectable entries, while each section count remains independently truthful.

Aggregate additions and deletions use the same active entries and may likewise
include both the committed and uncommitted comparison for one path.

Working-tree cleanliness remains:

```text
stagedCount == 0 && unstagedCount == 0 && untrackedCount == 0
```

Against Base entries must not mark the titlebar dirty. When Working Changes are
clean but Against Base contains rows, show the existing `Working tree clean`
state and the populated Against Base section together.

## Change Actions

### Classic sections

Preserve all existing row and Section Operations:

- Staged: Unstage, Diff, Blame, Copy Path; Unstage All.
- Unstaged: Stage, confirmed Discard, Diff, Blame, Copy Path; Stage All and
  confirmed Discard All.
- Untracked: Stage, confirmed Delete, Diff, Copy Path; Stage All and confirmed
  Delete All.

### Uncommitted rows

Derive actions from the row's retained state:

| State | Actions |
| --- | --- |
| Staged only | Unstage, Diff, Blame, Copy Path |
| Unstaged tracked only | Stage, confirmed Discard, Diff, Blame, Copy Path |
| Untracked | Stage, confirmed Delete, Diff, Copy Path |
| Staged and unstaged | Stage, Unstage, confirmed Discard, Diff, Blame, Copy Path |

Stage affects the current path with `git add -- <path>`. Unstage removes the
path's index change. Discard restores only unstaged tracked content to the
index version and does not discard staged content. Delete is offered only when
the path is untracked.

### Uncommitted Section Operations

The combined header and context menu expose subset-specific operations:

- **Stage All** when tracked unstaged or untracked paths exist. It stages all
  Working Changes, including untracked paths.
- **Unstage All** when staged paths exist.
- **Discard All Unstaged** when tracked unstaged paths exist.
- **Delete All Untracked** when untracked paths exist.

When Stage All is applicable, it is the primary header action. When only staged
changes remain, Unstage All becomes primary. The remaining operations live in
the section's secondary menu and context menu.

Discard All Unstaged and Delete All Untracked remain separate destructive
operations. Each confirmation names the exact operation and uses the full
uncapped affected subset count. Argus does not add a single Discard All
Uncommitted operation.

### Against Base

Against Base has no Git Mutations or Section Operations.

Rows offer:

- Diff;
- Blame when the path exists at `HEAD`; and
- Copy Path.

Deleted Against Base paths omit Blame instead of opening a predictably failing
preview.

## Preview behavior

Git Preview Tabs remain in the initiating Workspace and retain their current
identity: Preview Kind, Git Status Root, and path. Opening another comparison
for an already-open path refreshes that tab in place.

### Uncommitted Diff

Load:

- old content from `HEAD:<original-path>`;
- new content from the working-tree path;
- empty old content for untracked or unborn-`HEAD` additions; and
- empty new content for deletions.

The preview represents the complete net uncommitted result rather than only the
index or only the unstaged portion.

If staged and unstaged changes cancel, show an in-tab message explaining that
the path has Git state but no net `HEAD`-to-working-tree content difference.

### Against Base Diff

Resolve the merge-base commit for the stored Base Branch ref and `HEAD`, then
load:

- old content from `<merge-base>:<original-path>`;
- new content from `HEAD:<path>`;
- empty content on the absent side for additions and deletions.

Use the existing binary, maximum-size, maximum-line-length, and failure
handling.

Against Base blame runs against `HEAD` explicitly so later uncommitted content
does not alter the committed comparison.

Classic preview semantics remain unchanged.

## Refresh and failure behavior

- Enabling or disabling either setting refreshes the current Git Status
  Snapshot using a new owner.
- A Git Mutation refreshes with the same complete request that initiated it.
- An FSEvents refresh uses the latest active request.
- A branch or ref change received during cooldown retains the existing deferred
  refresh behavior.
- A base-only failure does not replace loaded Working Changes with the
  whole-view error state.
- Switching Workspaces or settings rejects stale status and preview results.
- Refresh preserves expanded sections, expanded Change Tree directories,
  scroll position, and focus when the underlying Workspace does not change.
- Separate expansion state is retained for all five Change Section kinds during
  the runtime session, so toggling a setting off and back on restores that
  section's previous state.

## UI and accessibility

The Changes View renders `GitStatusSummary.sections` rather than hard-coding
three calls by title.

- Working sections appear before Against Base.
- Empty available sections remain collapsible and show a zero count consistently
  with existing section behavior.
- An unavailable Against Base section remains visible while its setting is
  enabled.
- Expand/collapse-all operates only on currently present, available sections.
- Section actions are selected by typed section kind and underlying counts, not
  localized display titles.
- Directory IDs and row IDs include the typed section kind so identical paths
  in different comparison contexts do not collide.
- Hover-revealed row actions retain reserved geometry.
- Every new icon-only action has hover feedback, a pointing-hand cursor, help
  text, and an accessibility label.
- Accessibility values identify both the Git File Status and relevant staged,
  unstaged, untracked, or Against Base context.
- The unavailable-base message exposes the failed branch name and error detail
  without relying on color.

## Implementation plan

The chunks below are sequential. Each chunk must compile and pass its focused
tests before the next chunk begins. Intermediate chunks may keep the new
behavior inaccessible from Settings, but both settings must remain default-off
so incomplete behavior cannot alter the stable default workflow.

### Chunk 1: Settings, terminology, and request identity

**Dependencies:** None.

**Implementation**

- Add the two persisted App Settings properties and canonical keys in
  `Argus/Settings/AppSettings.swift`.
- Add default and round-trip persistence coverage in
  `Tests/SettingsTests/AppSettingsTests.swift`.
- Extend `GitStatusRootContext` with the optional configured Project main
  branch and supply it from `gitStatusContext(workspace:project:)`.
- Introduce `GitStatusPresentation` and `GitStatusRequest`.
- Change `GitStatusSnapshotOwner` to own the complete request.
- Thread the request through view-model refresh, initialization, mutations,
  pending refreshes, auto-refresh, and legacy test helpers.
- Include both setting values when the Changes View and Right Sidebar construct
  refresh requests.
- Add the Base Branch, Uncommitted, and Against Base terms to `CONTEXT.md`,
  noting that the stable spec remains unchanged until promotion.

**Focused verification**

- Missing settings keys produce `false`.
- `true` and `false` values round-trip independently.
- Each of the four setting combinations produces a distinct request/owner.
- A late result from a previous setting combination is rejected.
- Git Mutations and FSEvents retain the active request.
- Existing root resolution and titlebar ownership tests remain green.

**Completion gate**

The application builds, existing default behavior is unchanged, and request
identity is ready to distinguish all four layouts.

### Chunk 2: Typed sections with classic-behavior parity

**Dependencies:** Chunk 1.

**Implementation**

- Add `GitChangeSectionKind`, `GitDiffSource`, `GitChangeSection`, and
  `GitChangeSectionState`.
- Replace `GitFileChange.sectionKey` with typed section and diff-source values.
- Add staged, unstaged, and untracked state flags to Git File Changes.
- Adapt the porcelain parser, statistics application, Change Tree IDs, row
  action routing, section operation routing, preview loader, and tests.
- Make `GitStatusSummary` expose ordered sections while retaining the full
  working subset counts required for dirty state and Section Operations.
- Move display-cap application to the ordered-section projection without
  changing classic priority or totals.
- Keep the UI on the classic three sections in this chunk.

**Focused verification**

- Every existing parser/service/preview behavior has typed equivalents.
- Default requests still return Staged, Unstaged, and Untracked in that order.
- Existing actions invoke the same Git commands and confirmations.
- Change Tree IDs remain stable within a section and distinct across sections.
- The 500-entry cap and uncapped section counts match current behavior.

**Completion gate**

All existing Changes tests pass without string-based section dispatch in new
domain or service APIs.

### Chunk 3: Combined Uncommitted status and operations

**Dependencies:** Chunk 2.

**Implementation**

- Add a NUL-delimited name-status parser suitable for `git diff` rename and
  copy records.
- Build the unique Uncommitted path union from porcelain, `HEAD`-to-working-tree
  name status, numstat, and untracked statistics.
- Handle mixed staged/unstaged paths, canceled net diffs, unmerged paths,
  binary files, spaces, tabs, renames, deletions, and unborn `HEAD`.
- Produce the Uncommitted section when combination is enabled and omit the
  three classic sections from the presentation projection.
- Add row action selection from retained working-state flags.
- Add Stage All including untracked files, Unstage All, Discard All Unstaged,
  and Delete All Untracked with exact subset counts.
- Add the complete Uncommitted diff loader and explanatory canceled-diff state.

**Focused verification**

- Staged-only, unstaged-only, untracked, and mixed paths produce one row each.
- A staged/unstaged path appears once and exposes Stage, Unstage, and Discard.
- Stage All includes untracked files; other Section Operations affect only
  their named subset.
- Destructive confirmations use uncapped subset counts.
- Combined diffs load `HEAD` to working tree for modifications, additions,
  deletions, and renames.
- New repositories and canceled net diffs remain recoverable.
- Combine-on/base-off returns only Uncommitted.

**Completion gate**

The combination flag is behaviorally complete through the service, actions,
previews, and tests, while its UI toggle may remain hidden until Chunk 5.

### Chunk 4: Base resolution, Against Base status, and previews

**Dependencies:** Chunk 2. May proceed after Chunk 2 in parallel with Chunk 3,
but integration waits for both.

**Implementation**

- Implement configured and Standalone Base Branch selection.
- Implement origin-first, local-second ref verification with no fetch.
- Add three-dot Against Base name-status and numstat loading.
- Represent no branch, missing ref, missing merge base, unborn `HEAD`, and
  command failure as an unavailable section rather than a whole-view error.
- Add Against Base diff loading from merge-base to `HEAD`.
- Make Against Base blame explicit to `HEAD` and omit it for deleted paths.
- Append Against Base after whichever working sections are active.

**Focused verification**

- Named Projects use their configured main branch.
- `origin/<base>` wins when local and remote refs diverge.
- The local branch is used when the remote-tracking ref is absent.
- Standalone detection follows remote HEAD, local main, local master.
- The current branch is never silently used as its own base.
- Three-dot output includes only committed branch changes.
- Uncommitted paths do not leak into Against Base.
- Base failures preserve loaded, actionable Working Changes.
- Base-off requests do not run base detection or comparison commands.
- Base-on/combine-off returns classic sections followed by Against Base.

**Completion gate**

Against Base is complete and non-mutating, including offline ref resolution,
failure isolation, and previews.

### Chunk 5: Dynamic Changes View and Settings controls

**Dependencies:** Chunks 3 and 4.

**Implementation**

- Add both native toggles and supporting copy to Files & Changes Settings.
- Render the ordered section collection instead of three hard-coded sections.
- Replace separate expansion booleans with state keyed by
  `GitChangeSectionKind`.
- Update expand/collapse-all for currently available sections.
- Route header actions, context menus, row actions, counts, unavailable state,
  truncation copy, and accessibility through typed section data.
- Ensure primary/secondary Uncommitted Section Operations follow the rules in
  this proposal.
- Update the Right Sidebar badge and branch-bar count to use active section
  entry totals.
- Verify that setting changes refresh without navigation or focus changes.

**Focused verification**

- All four combinations render the exact section order from the summary table.
- Both toggles apply immediately and persist after recreating App Settings.
- Working sections always precede Against Base.
- Against Base remains visible with useful text when unavailable.
- Clean Working Changes plus populated Against Base show both the clean state
  and committed rows.
- Same-path rows in working and base sections have distinct IDs.
- Expansion state survives refresh and toggling.
- Hover geometry, context-menu parity, disabled behavior, help, and
  accessibility satisfy the UI contract.

**Completion gate**

The complete feature is user-accessible and all automated feature tests pass.

### Chunk 6: Stable-contract promotion and release-quality verification

**Dependencies:** Chunk 5.

**Implementation**

- Update `docs/SPEC.md` with both settings, all four section layouts, Base
  Branch resolution, action rules, limits, previews, and failure behavior.
- Update `docs/UI_DESIGN_PRINCIPLES.md` so its sidebar rule allows the two
  configured working layouts and optional Against Base section.
- Reconcile final terminology and ownership in `CONTEXT.md`.
- This proposal was marked Implemented after code and verification were complete.
- Do not add an ADR unless implementation introduces a new cross-cutting
  architecture decision beyond this accepted design.

**Automated verification**

Run:

```sh
./scripts/test.sh
```

The full suite must cover:

- both setting defaults and independent persistence;
- the four layout combinations;
- status parsing and statistics for every section kind;
- Base Branch precedence and Standalone detection;
- mixed staged/unstaged deduplication;
- row and Section Operations;
- destructive confirmations and uncapped scope;
- preview content for every diff source;
- display caps and unavailable states;
- stale-result rejection and Workspace ownership; and
- titlebar dirty-state independence from Against Base.

**Manual verification**

Exercise all four layouts in:

- a Named Project feature Worktree Workspace;
- a Main-checkout Workspace on its configured main branch;
- a Standalone Workspace with `origin/HEAD`;
- a Standalone Workspace with only local `main`;
- a repository with no detectable Base Branch;
- a detached-`HEAD` checkout; and
- an unborn repository.

For each relevant case, verify:

- section order, counts, Change Tree compaction, and truncation copy;
- live filesystem and ref refresh;
- same-path entries in working and base contexts;
- stage, unstage, discard, and delete behavior;
- confirmation text and affected counts;
- diff and blame content plus tab reuse;
- clean/dirty titlebar state;
- narrow and wide Right Sidebar layouts;
- light and dark appearance;
- pointer hover and cursor behavior;
- keyboard and VoiceOver access; and
- no Workspace, tab, pane, scroll, or focus theft during refresh.

**Completion gate**

The stable contract describes exactly the shipped behavior, the full suite
passes, manual acceptance is recorded, and no incomplete proposal behavior
remains.

## Acceptance criteria

The proposal is complete when all of the following are true:

- Both settings exist in Files & Changes Settings and default to off.
- The settings persist and combine independently.
- The default layout is unchanged.
- Combination produces one Uncommitted row per unique path.
- Against Base is additive, read-only, and ordered after Working Changes.
- Base resolution follows the configured precedence without network access.
- Missing base state does not block Working Changes.
- All existing and new Git Mutations retain correct scope and confirmation.
- Diff and blame previews use the correct comparison source.
- Against Base does not affect dirty working-tree state.
- Counts, caps, async ownership, accessibility, and focus behavior satisfy the
  stable contracts.
- `docs/SPEC.md`, `CONTEXT.md`, and `docs/UI_DESIGN_PRINCIPLES.md` are promoted
  together with the completed implementation.

## References

- Superset computes its branch comparison using an origin Base Branch and a
  three-dot diff:
  <https://github.com/superset-sh/superset/blob/main/apps/desktop/src/lib/trpc/routers/changes/workers/git-task-handlers.ts>
- GitHub documents three-dot comparison as the Pull Request-style view of
  changes introduced since branch divergence:
  <https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/about-comparing-branches-in-pull-requests>
