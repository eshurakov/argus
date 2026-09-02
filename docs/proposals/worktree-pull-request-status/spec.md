# Pull Request status for Worktree Workspaces

## Status

- Lifecycle: Implemented
- Implementation: Design A approved on 2026-08-29 and implemented on 2026-08-30
- Last reviewed: 2026-08-30
- Stable-contract target: `docs/SPEC.md`, Projects and Workspaces and GitHub CLI Pull Request boundary
- Visual comparison: [Interactive HTML designs](designs.html)
- Recommended direction: **A — Inline badge**. B and C are alternatives, not three settings to implement.

A is implemented and promoted into `docs/SPEC.md`, with ownership recorded in ADR 0008. B and C remain historical design comparisons. The original implementation plan below is retained alongside the completed verification results; the stable spec is authoritative for implemented behavior.

## Approved follow-up: batched, quota-aware refresh

Status: implemented and verified on 2026-08-30. The original A presentation remains unchanged; the stable contract is recorded in `docs/SPEC.md` and ADR 0009.

1. Separate branch/candidate discovery from detailed status reads. Discovery remains bounded and conservatively matched; ready known Pull Requests join a GraphQL batch, including associations just discovered in the same refresh cycle.
2. Replace per-Workspace `gh pr view` status reads with bounded `gh api graphql` batches, grouped by GitHub host across Projects. Deduplicate identical Pull Request identities while retaining each Workspace's independent request context and cancellation rules. Large sets use multiple batches rather than unlimited query size.
3. Include `rateLimit { cost remaining resetAt }` in the status response. Keep a process-local host quota pause, reserve a small amount of remaining capacity, and honor provider retry/reset deadlines. A pause gates manual and automatic status work, survives foreground/feature toggles until its deadline, and is visible without a perpetual loading indicator. No extra recurring rate-limit polling is required.
4. Use a 60-second interval for the Selected Workspace's known Pull Request; use 10 minutes for background discovery, confirmed no match, and repository-cache expiry. Selection/expansion reuse recent status instead of bypassing the interval. Increase the normal stale-age allowance to 11 minutes so healthy background rows do not appear stale between scheduled refreshes.
5. Preserve manual Refresh in both the popover and Workspace context menu. It bypasses ordinary caches and scheduling intervals, but not a host quota/rate-limit pause. Keep local Git Status refresh independent.
6. Verify multi-repository batching, bounded query sizes, partial GraphQL errors, unknown/incomplete checks, quota exhaustion/reset, pause bypass attempts, slower cadence, and member removal/branch changes during a shared batch. Re-run the full app-hosted suite and strict formatting; retain the existing intake and persistence tests.

Verification completed: the native app builds and **516 tests pass** (616 cases including parameters) with parallel test execution disabled. Final result: `.build/Logs/Test/Test-Argus-2026.08.30_23-47-54-+0200.xcresult`. Source hashes were checked before and after the full run to exclude concurrent edits. Strict repository-wide formatting and whitespace checks pass; `./scripts/lint.sh` remains blocked because SwiftLint is not installed. No live GitHub requests were made.

The implemented bound is 20 unique Pull Requests per host batch, with one active status batch per host and three actual provider requests globally. Refresh pauses when remaining quota is at or below `max(100, cost + 1)`. Explicit deadlines are honored; primary exhaustion without a reset pauses for an hour, and secondary exhaustion without a deadline starts at 60 seconds and backs off. Manual Refresh shows the resume time and cannot bypass these pauses.

The stable spec and operational/UI contracts have been updated. The following original plan and first implementation results remain as design history.

## Outcome and scope

See which Pull Request belongs to each Worktree Workspace, whether it is open, draft, merged, or closed, and whether checks or review need attention—without leaving the terminal workflow.

First release:

- Named Project Worktree Workspaces, including existing/adopted Worktree Workspaces and those created by Pull Request intake.
- GitHub through the active `gh` authentication context, including GitHub Enterprise when `gh` can resolve the host.
- Number, title, canonical URL, lifecycle, aggregate review decision, aggregate checks, and refresh health.
- A compact status summary with Open Pull Request, Copy Pull Request URL, and Refresh Pull Request status actions.
- A native Files & Changes setting, **Show Pull Request status**, proposed default **on**. Explain that it uses GitHub CLI and contacts GitHub while the main window is active. Turning it off cancels work and removes runtime status. Missing CLI/authentication never blocks local work or launches installation/login automatically.

Not included: Main-checkout or Standalone Workspaces, Pull Request creation/merge/close/review submission, comments, reviewers, check logs, mergeability, automatic fetching/checkouts, notifications, Workspace reordering, durable provider associations, or Review Work Mode. A successful CI/review result must never be labeled “ready to merge.”

## What Agent Manager actually does

Inspected `/Users/evgeny/Projects/kilocode` at `5e02825c8c5318912e39fe0ceee46793589fae3f`. The relevant implementation is **VS Code Agent Manager**, not the CLI's separate PR-link helper.

Paths in this table are relative to that checkout; line references describe the inspected revision.

| Behavior | Evidence |
| --- | --- |
| Runs `gh` in the extension host, independently of the agent/model. Worktree path is the working directory. | `packages/kilo-vscode/src/agent-manager/PRStatusPoller.ts:315–374` |
| Tries bare `gh pr view`, then explicit branch, then an all-state SHA search capped at five results. The SHA fallback requires exact `headRefOid` equality. | `packages/kilo-vscode/src/agent-manager/PRStatusPoller.ts:342–399` |
| Selected worktree every 15 seconds; initial/all-worktree sync every 120 seconds; three concurrent lookups; ten-second positive/negative lookup cache. | `packages/kilo-vscode/src/agent-manager/PRStatusPoller.ts:31–64,203–245,326–340` |
| Pauses on panel hiding; resumes with a catch-up; refreshes on worktree selection/inspection. Errors back off to 30, 60, then 120 seconds. | `packages/kilo-vscode/src/agent-manager/PRStatusPoller.ts:85–184` |
| Sidebar badge shows lifecycle-colored icon and number. An extra indicator prioritizes failed checks, changes requested, then approval. Pending checks also recolor/pulse an open badge. | `packages/kilo-vscode/webview-ui/agent-manager/WorktreeItem.tsx:91–130,336–391` |
| Badge click opens the external URL without selecting the worktree. A separate toolbar action opens a full PR inspector. | `packages/kilo-vscode/webview-ui/agent-manager/WorktreeItem.tsx:355–369`; `packages/kilo-vscode/webview-ui/agent-manager/TabBar.tsx:218–230` |
| Retains prior status on failures and some empty results; no last-success/freshness field. Persists number/URL/state separately, but current live sidebar data is not hydrated from those fields. | `packages/kilo-vscode/src/agent-manager/pr-status-bridge.ts:172–239`; `packages/kilo-vscode/webview-ui/agent-manager/project/store.ts:62–99` |

**Borrow:** compact per-Workspace badges, fast selected/slow background refresh, bounded concurrency, cached-content preservation, and explicit refresh.

**Do not copy:** branch-only cache identity, treating provider failures as no checks/no Pull Request, indefinitely fresh-looking old badges, draft overriding a terminal lifecycle, hover-only/inaccessible click targets, pulse decoration, persistence of provider status, or the full review inspector.

The CLI TUI plugin (`packages/opencode/src/kilocode/plugins/sidebar-pr.tsx:237–281`) only displays number/title and has no periodic polling. It is not the status implementation to port.

## Three visual solutions

The [HTML comparison](designs.html) uses the same sample Workspaces and data in three side-by-side sidebar crops, with a separate Changes View detail crop for C. Following the request for a simpler generation approach, it is one dependency-free HTML file rather than a framework-based or full-window prototype. Select rows, inspect status, change lifecycle/failure fixtures, choose 140/200/280-point sidebar widths, and simulate key-window/Command-overlay states. Open/Copy/Refresh actions are simulations; no provider or clipboard calls occur. The HTML uses CSS end ellipsis as an approximation; the native implementation must use middle truncation for branches. Native focus, VoiceOver, and minimum-width verification remain implementation work.

### A — Inline badge, recommended

Keep the existing two-line Workspace row. Put a small lifecycle icon and `#number` at the trailing edge of the branch line. A separate small signal communicates failed checks, requested changes, pending checks, or approval. The process count stays separate on the title line; the leading attention/Agent Status/type icon remains unchanged.

- No extra row height; closest to Agent Manager and the current Argus hierarchy.
- Activating the badge shows a compact native status popover, without selecting a different Workspace. It contains identity/title, lifecycle, review/check summaries, freshness, and explicit actions—not the PR body, check logs, or review content.
- The branch truncates in the middle before the badge. At sidebar widths below 160 points, collapse the badge to a 20-point icon target; full identity/status remains in help, accessibility, and the context menu.
- Reserve a 68-point trailing metadata slot at ordinary widths for eligible rows so loading/no-match/loaded transitions cannot shift branch text. A longer PR number truncates inside that slot; full identity stays available in the summary.
- Trade-off: the full lifecycle and check counts require inspection, especially in a narrow sidebar.

**Why A:** status is visible across Workspaces even when the Right Sidebar is hidden, without turning navigation into a second task list or changing the Changes View.

### B — Dedicated status line

Keep title and branch, then add a third line: `#142 Open · 1 failed` or `#137 Merged`. Use the same summary/actions as A. Reserve the third line for every eligible Worktree Workspace, including loading/no-match states.

- Most explicit cross-Workspace scan; less dependence on tooltips and icon familiarity.
- Preserves long branch labels better than A.
- Trade-off: approximately 18 extra points per eligible row and more scrolling; a permanent “No Pull Request” line adds noise. Narrow widths still require truncation.

### C — Minimal sidebar indicator + Changes summary

Show only a lifecycle icon in a reserved metadata slot on the Workspace row. Add a compact Pull Request summary below the existing branch bar in the Selected Workspace's Changes View. Keep the icon's popover/context-menu path when the Right Sidebar is hidden or Files is selected.

- Richer status is always readable while inspecting local changes; existing two-line row height is retained.
- The Changes summary shows number/title, lifecycle, review, checks, freshness, and actions. It is not a Change Section and does not affect change counts or dirty state.
- Trade-off: full identity and details are visible for only one Workspace at a time and consume vertical room in the Changes View. More integration work than A.

### Shared interaction contract

- Preserve Turn Completion Attention → Agent Status → Workspace-type icon precedence and the Command-held shortcut overlay. Pull Request state never occupies that leading slot or the running-process badge.
- Use system typography, semantic icons plus labels, black key-window / `#1A1A1A` non-key-window backgrounds, restrained selection, and stable geometry. No pulsing status badges.
- Do not nest a new `Button` inside the existing full-row `Button`. Use sibling controls with a full-row selection hit area and a separate reserved status hit area; preserve reorder/context-menu behavior.
- Status controls have hover, pointing-hand cursor, at least 20×20-point targets, help, keyboard activation, and VoiceOver labels. Escape dismisses a summary and returns focus to its trigger.
- Context menus provide Show/Refresh Pull Request status even for confirmed no-match and failure states; Open/Copy require a validated URL. No operation relies on hover alone.
- Explicit **Open Pull Request** selects the originating Workspace and opens or reuses its matching Browser Tab. Reuse is scoped to that Workspace and canonical URL. Opening is intentional navigation; background refresh never changes selection, Active Tab, Focused Pane, or Right-sidebar View.
- Copy and refresh do not select a Workspace. The existing Refresh changes action remains local-Git-only; provider refresh has a separate named action.

## Data and state contract

Add a small immutable Pull Request status value, separate from `PullRequestWorkspaceMetadata` and `GitStatusSnapshot`:

- Existing `PullRequestIdentity` and `RepositoryIdentity`, validated canonical HTTPS URL, title, head/base branch, head Repository Identity, and head commit.
- Lifecycle: open, draft, merged, closed. `MERGED` and `CLOSED` take precedence over `isDraft`; unknown/missing lifecycle is invalid metadata, never implicitly open.
- Review: approved, changes requested, review required, no review decision, unavailable. Empty/null provider decisions do not prove that review is unnecessary.
- Checks: passed, failed, pending, skipped/neutral, and unknown counts; explicit no checks versus unavailable. CheckRun and StatusContext forms both need normalization. Cancelled, timed-out, action-required, error, and failed checks are unsuccessful; skipped/neutral are not falsely counted as passed. Aggregate precedence: failed → pending → unknown → passed/no checks. Incomplete data must not look fully successful.
- Last successful refresh time and current refresh health, independent of lifecycle.

The sidebar's auxiliary signal uses failed checks → changes requested → pending checks → approval. Merged/closed suppress that signal. Refresh failure/expired data replaces the auxiliary signal with a stale marker, while retaining the known lifecycle and showing the detailed reason in the summary.

| Load state | Presentation and behavior |
| --- | --- |
| Disabled/ineligible | No provider work or status affordance. |
| Initial loading | Small reserved loading indicator; no row resizing. |
| Confirmed no match | Quiet empty slot in A/C; “No Pull Request” in B and the summary. This is only a successful, complete discovery result. |
| Loaded | Lifecycle plus independent review/check data and last-success time. |
| Refreshing | Keep prior status, with progress inside reserved geometry; coalesce duplicate requests. |
| Failed after success | Retain matching-context data with “Stale” and “Last checked …”; never display it as current or healthy. |
| Failed without data | Muted unavailable indicator and actionable summary; no modal/toast storm. |
| Ambiguous/incomplete lookup | “Multiple matching Pull Requests” / “Lookup limit reached”; do not pick the first result or label it no match. |
| Missing/unregistered worktree or detached HEAD | Clear the prior association and explain the local condition; no speculative network search. |

Missing CLI, authentication, unsupported/unresolved repository, timeout, invalid data, rate limiting, and general provider failure remain distinguishable where the CLI output makes that distinction reliable. Recovery text may suggest `brew install gh`, `gh auth login`, or `gh repo set-default <remote>`; Argus never runs these mutating/setup commands itself.

## Association and discovery

A Worktree Workspace represents the **currently checked-out branch**, not whichever Pull Request originally created it. Stored `Workspace.branchName` and Terminal Working Directory are not authoritative inputs.

1. Reconcile eligible Workspace IDs against current Named Projects. Resolve canonical worktree paths through `WorktreeService.listWorktrees`, one `git worktree list --porcelain` per due Project. Read actual branch/HEAD; reject missing, detached, or unregistered targets. Do not run full Git Status for every Workspace.
2. Resolve the provider repository through `gh repo view --json nameWithOwner,url` in the **Project Repository Root**, honoring the active CLI/default-repository context. Validate the returned Repository Identity against the Project's fetch URLs, never push-only URLs. Do not silently choose `origin` over a different configured default or infer GitHub support from a URL shape. An unsupported host or unverifiable default remains unavailable.
3. Discover candidates with argument arrays, explicit repository and branch, all lifecycle states, and a bound:

   ```text
   gh pr list --repo <host/owner/repository> --head <actual-branch> --state all --limit 50 --json <identity-and-lifecycle-fields>
   ```

   Discovery fields: `number,title,url,state,isDraft,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository`. `--head` does not support `owner:branch`; filter head Repository Identity locally. Exactly 50 results means the result may be truncated and must not be treated as an exhaustive candidate set.
4. Require an exact branch match and validated base Repository Identity. If an upstream identifies a head repository, require that identity. Without an upstream, same-repository candidates may match by branch; a fork candidate requires exact local HEAD equality or a previously validated same-context association. This permits ordinary locally-ahead branches without requiring local HEAD to equal the provider head, while avoiding arbitrary same-name fork matches.
5. Choose a unique eligible open/draft candidate before terminal candidates. Multiple eligible open candidates are ambiguous. If there are no open candidates, retain a previously validated same-context Pull Request, or choose a unique merged/closed candidate whose head equals local HEAD. Do not attach an old closed Pull Request to a newly reused branch solely because its name matches. If terminal candidates exist but cannot be validated, report unavailable association rather than confirmed no match.
6. Query the chosen Pull Request by number and explicit repository:

   ```text
   gh pr view <number> --repo <host/owner/repository> --json <status-fields>
   ```

   Status fields add `baseRefName,reviewDecision,statusCheckRollup`. Validate returned identity/branch again. Use the same bounded query for refreshes; no body, comments, reviewers, or individual check-log requests. If a specific optional-field permission/version failure permits a core-only retry, keep checks/review explicitly unavailable. Authentication/network failures must not trigger a misleading “successful” fallback.
7. Publish only for the captured Workspace ID, Project ID, Project Repository Root, canonical worktree path, Repository Identity, actual branch, and generation. Revalidate current local branch/HEAD before applying a network result; if either changed, discard it and queue rediscovery. Removed/reclassified Workspaces or removed Projects receive no late result.
8. Discovery also runs during background sweeps for already-associated branches so a newly opened Pull Request can supersede a previous merged/closed one. Confirmed no match clears an old association; failed or incomplete discovery does not.

Limits are deliberate: no SHA-wide provider search, detached-HEAD inference, or durable manual-link workflow in this version. A renamed branch, an untracked fork branch advanced locally after a restart, or a terminal Pull Request whose head no longer matches may remain unassociated. Show that limitation rather than guessing. Current-session associations survive ordinary local commits but are cleared by an observed branch/repository change.

## Runtime and refresh

Use **one `@MainActor` observable runtime model**, owned above conditional sidebar views in `MainWindowView`. Keep data keyed by Workspace ID and immutable request context internally. Do not add one timer per row, attach networking to the process-count `TimelineView`, or piggyback on every FSEvents change.

| Trigger/policy | Proposed behavior |
| --- | --- |
| First eligible Workspace / restore | Discover all eligible Worktree Workspaces; no restored provider badge before validation. |
| Selected Workspace | Refresh known Pull Request every 15 seconds after completion. Confirmed no-match discovery is at most once per 60 seconds unless explicitly refreshed. |
| All eligible Workspaces | Rediscover and refresh every 120 seconds, including collapsed Projects; selected work is prioritized. |
| Selection / Project expansion | Refresh if older than ten seconds; share any in-flight request. |
| Manual status refresh | Bypass result/repository caches, re-resolve current context, and rediscover; disable duplicate refresh controls while running. |
| New Workspace / completed PR intake | Queue discovery through the same path; do not retain extra intake metadata in the Session Snapshot. |
| Main window hidden, minimized, or app inactive | Suspend scheduling; cancel in-flight provider work and retain timestamped data. |
| Foreground / wake | Revalidate local contexts and refresh due results, then resume one scheduler. |
| Concurrency | At most three provider commands globally across Projects; keep local Git Status work independent. |
| Cache | Ten-second successful-result coalescing; 60-second confirmed-no-match cache; repository resolution at most 120 seconds, invalidated on explicit refresh, foreground, or observed remote/config changes. |
| Provider failures | Per-Project retry floor of 30, then 60, then 120 seconds; success resets it. An identified rate-limit retry deadline takes precedence. Manual retry is possible except before a known rate-limit deadline. |
| Missing `gh` | Cache executable absence for 30 seconds; do not spawn one failed lookup per Workspace. |
| Freshness | Failed refreshes are immediately stale. Data older than 150 seconds is visibly stale even without an explicit error. No launch-time persistence of cached status. |
| Cleanup | Cancel and prune on Workspace removal, Project removal, changed context, feature disable, and window teardown. |

A fresh local branch observation should supply the row's displayed branch through the runtime projection; do not mutate custom Workspace titles or overload durable branch metadata to store provider state. Local branch changes invalidate the old badge before another lookup. Context validation and a per-target in-flight registry prevent overlapping automatic/manual requests from racing.

The active `gh` context is used on each command. External account changes have no instantaneous event source: manual refresh/foreground invalidates discovery caches, and normal refresh converges. Credentials and auth tokens are never read, persisted, logged, or exposed to views.

## Implementation plan

### 1. Read-only provider status boundary

- Add `Argus/Models/PullRequestStatus.swift` for status, refresh/load state, and pure normalization.
- Extend `GitHubPullRequestService.swift` with repository resolution, bounded branch discovery, and number-based status queries. Reuse `RepositoryIdentity` / `PullRequestIdentity` from `PullRequestWorkspace.swift` and the existing `GitHubCommandRunning` injection boundary.
- Share only the executable/environment/diagnostic helpers needed by intake and status. Keep the 30-second timeout, 1 MiB per-stream bound, argument arrays, cancellation, and noninteractive environment. No generic provider framework or subprocess rewrite.
- Add fake-command tests in `Tests/WorktreeTests/PullRequestStatusServiceTests.swift` for fields/arguments, all lifecycle and check forms, closed-draft precedence, errors, no match, cap/ambiguity, repository validation, forks, and reused branch names.
- Preserve all existing Pull Request intake tests and exact-head checkout behavior.

**Done when:** deterministic fixtures exercise discovery and status without credentials or repository mutation; an empty result cannot conceal a failure.

### 2. Workspace-scoped runtime ownership

- Add `Argus/Services/WorkspacePullRequestStatusModel.swift`, with injected provider, worktree discovery, and clock/scheduling inputs following `GitStatusAutoRefreshTests` patterns.
- Own one instance in `MainWindowView.swift`, independent of either sidebar's visibility. Reconcile inventory, Project membership, selection, feature setting, and native foreground/wake lifecycle.
- Use existing worktree discovery and fetch-remote helpers; add only the narrow read-only head/upstream observations needed for matching. Keep local Git operations out of the provider concurrency gate.
- Implement due-time scheduling, per-target coalescing, context generations, branch revalidation, stale data, retry policy, and both Workspace/Project cleanup paths.
- Add `WorkspacePullRequestStatusModelTests` covering unselected branch switches, overlap, cancellation, remove/recreate races, independent Projects, cache expiry, negative results, pause/resume, backoff, and no mutation/focus changes.

**Done when:** status remains correctly associated after switching branches or Workspaces mid-request, and no background work changes navigation or repository state.

### 3. Recommended sidebar UI and actions

- Update `SidebarView+WorkspaceRow.swift` for A's reserved metadata slot and current-branch projection, preserving process counts, icon precedence, and shortcut overlays.
- Add a small shared native badge/summary view; keep provider I/O out of views. Do not implement B/C as settings.
- Add context-menu actions in `SidebarView+Projects.swift`, including status inspection/retry when no Pull Request is loaded.
- Add a source-Workspace-scoped Open Pull Request path, delivered in `WorkspaceManager+PullRequestStatus.swift` using the existing browser configuration from `WorkspaceManager+Navigation.swift`; reuse an existing Browser Tab by validated canonical URL within that Workspace. No new Panel kind or persistence change.
- Add the setting in `AppSettings.swift` and native Files & Changes form in `SettingsView.swift`.
- Protect interaction contracts in existing Workspace/Turn Completion UI contract suites and add meaningful action/ownership tests. Manually check pointer, keyboard, VoiceOver, 80/160/200/320-point widths, long labels, increased contrast, both appearances, and key/non-key windows.

**Done when:** every state is inspectable without selecting an unrelated Workspace, stale data is unambiguous, and status does not compete with Agent Status or running-process counts.

### 4. Verify and promote the accepted contract

- Keep the Session Snapshot schema unchanged; test that no status/cache/request fields are serialized and restored sessions start unvalidated. Continue using isolated test Session Snapshots.
- Record the accepted automatic, read-only refresh decision in a new ADR superseding the no-automatic-refresh consequence of ADR 0005; retain the original record and its intake/collision guarantees.
- Update `CONTEXT.md` with the agreed Pull Request status ownership and terms, `docs/SPEC.md` with implemented behavior, and `docs/DEVELOPMENT.md` with optional `gh` status setup. Update the UI contract only for accepted new interaction rules.
- Mark this proposal Implemented only after app behavior and verification are complete, then promote the stable contract. Do not treat the HTML as executable application coverage.

## Verification commands for implementation

Use `project.yml` as the Xcode source of truth and generate the project after adding Swift files. `swift test` does not run the app-hosted suites.

```sh
./scripts/build.sh generate
./scripts/lint.sh
xcodebuild test -project Argus.xcodeproj -scheme Argus -destination 'platform=macOS,arch=arm64' -only-testing:ArgusTests/PullRequestStatusServiceTests -only-testing:ArgusTests/WorkspacePullRequestStatusModelTests -only-testing:ArgusTests/PullRequestWorkspaceTests -only-testing:ArgusTests/WorkspacePresentationUIContractTests -only-testing:ArgusTests/TurnCompletionUIContractTests -only-testing:ArgusTests/SessionSnapshotTests CODE_SIGNING_ALLOWED=NO
./scripts/test.sh
```

The Xcode test build supplies Swift typechecking; the full script also checks formatting, SwiftLint, and the Companion CLI scaffold. Native verification reused the existing local GhosttyKit archive through an ignored worktree symlink and copied the already-pinned package cache into this worktree's isolated `.build` directory. No dependencies were downloaded and the running application was not replaced or relaunched.

## Implementation results — 2026-08-30

- Implemented the read-only service/decoder, one Workspace-scoped runtime, A's native badge/popover/context actions, source-Workspace Browser Tab reuse, and the independently persisted default-on setting.
- Added provider, local Git input, scheduling/ownership, presentation, navigation, settings, and snapshot-isolation tests. Review regressions cover ambiguous branch/tag names, unrelated remote changes, Workspace-local error isolation, pending-only upstream reads, and duplicate publication suppression.
- The full native app build/typecheck and **463 tests passed** (557 cases including dynamic parameters). Result: `.build/Logs/Test/Test-Argus-2026.08.30_01-24-08-+0200.xcresult`.
- The first full test run failed only because Xcode's test-host PATH lacked Node for two existing Kilo/Pi harness tests. Both harnesses passed directly; all native tests then passed with a test-only `TEST_RUNNER_PATH` exposing the installed Node runtime. No harness code was changed.
- Repository-wide strict `swift-format lint` and whitespace checks passed. `./scripts/lint.sh` was attempted but cannot finish because SwiftLint is not installed. Native pointer/VoiceOver checks and live authenticated GitHub verification were not performed; provider verification uses deterministic fixtures.
- Implementation refinements: an unavailable-data cue precedes approval; rollups reaching 100 contexts remain incomplete; target-specific errors retry per Workspace rather than blocking its Project; changed fetch remotes retain an explicitly stale association until identity revalidation; local upstream reads are limited to pending targets.
- Stable contracts were promoted to `docs/SPEC.md`, `CONTEXT.md`, and the UI contract; ADR 0008 supersedes only ADR 0005's no-automatic-refresh consequence. Session Snapshot schema, explicit intake safety, local Git Status behavior, and the Companion CLI remain unchanged.

## Planning artifact verification — 2026-08-29

- Browser checks passed for all 14 fixture states, stable row heights, no-match inspection, Escape/focus restoration, stale refresh and late-result handling, originating-Workspace navigation, narrow badges, Command overlay, and non-key-window backgrounds.
- Desktop and 390-pixel mobile layouts had no page overflow; browser console/error checks were clean and no HTTP resources were requested.
- Whitespace checks passed for the proposal and HTML.
- `./scripts/lint.sh` was attempted but blocked: SwiftLint is not installed in this environment. Native app build/typechecking/tests were not run for these documentation-only changes.

## Argus source map

| Boundary | Existing code |
| --- | --- |
| Current sidebar composition and icon precedence | `Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift:8–97,99–176` |
| Workspace context menu | `Argus/Views/Sidebar/SidebarView+Projects.swift:235–272` |
| Stable root-owned state/lifecycle | `Argus/Views/MainWindowView.swift:91–98,133–164,209–213` |
| Existing CLI safety boundary | `Argus/Services/GitHubPullRequestService.swift:253–400,402–498` |
| Provider-qualified identities | `Argus/Services/PullRequestWorkspace.swift:8–121` |
| Read-only actual worktree discovery | `Argus/Services/WorktreeService+Discovery.swift:4–11,255–293` |
| Fetch-remote validation and fork intake | `Argus/Services/WorktreeService+PullRequest.swift:4–54,202–285` |
| Source-scoped browser navigation precedent | `Argus/Services/WorkspaceManager+Navigation.swift:111–125` |
| Optional C placement, separate from local branch bar | `Argus/Views/GitSidebar/GitSidebarView+Content.swift:59–79,133–184` |
| Existing intake decision to supersede in part | `docs/adrs/0005-pull-request-workspace-through-active-github-cli.md:40–56` |

## Provider references

- [GitHub CLI: `gh pr list`](https://cli.github.com/manual/gh_pr_list) — explicit all-state selection, result bound, JSON fields, and the `--head` owner-prefix limitation.
- [GitHub CLI: `gh repo set-default`](https://cli.github.com/manual/gh_repo_set-default) — active default-repository semantics; Argus must not change this setting itself.
