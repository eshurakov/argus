# Work Modes and Pull Request review

## Status

- Lifecycle: Accepted
- Implementation: Not started
- Last reviewed: 2026-07-26
- Stable-contract target: `docs/SPEC.md`

This proposal defines future behavior. `docs/SPEC.md` remains authoritative for the shipped application until each delivery phase is implemented and promoted.

## Summary

Argus will add a Work Mode picker at the top of the left sidebar. Code Work Mode contains the current Project, Workspace, terminal, Files, and Changes experience. Review Work Mode is a separate environment for reviewing GitHub Pull Requests.

Each Work Mode owns its sidebar selection, center tabs, Right Sidebar state, and restored layout. Switching modes returns the user to the exact context they left. Global Settings and Project identity remain shared.

Review Work Mode discovers Pull Requests that request the active GitHub user's review. Users can also paste a Pull Request URL. A Pull Request opens in one reusable Pull Request Review Tab with changed-file navigation, structured diffs, review conversations, Activity, Checks, Viewed progress, replies, inline drafts, and review submission.

## Goals

- Make Pull Request review a first-class workflow rather than a variation of local Git status.
- Preserve Code Work Mode context while the user reviews a Pull Request.
- Make large change sets easy to navigate by file and Viewed state.
- Put diffs, conversations, and review submission in one tab without opening another window.
- Protect unsent review text across mode switches, restarts, and crashes.
- Work without a local clone and remain useful from cached data while offline.
- Reuse shared Project identity and Argus-owned structured diff rendering where their responsibilities match.

## Non-goals

The first complete version does not:

- support GitLab, Bitbucket, or another hosting provider;
- own GitHub credentials or provide an OAuth sign-in flow;
- replace GitHub's complete Pull Request administration interface;
- edit Pull Request metadata, labels, assignees, milestones, branches, or checks;
- rerun checks, close or reopen Pull Requests, or merge Pull Requests;
- play review sounds, post macOS notifications, or maintain notification history;
- alter Code Work Mode's local Files, Changes, Git Preview, or Workspace behavior;
- clone, fetch, or create a Worktree Workspace merely because a Pull Request was opened; or
- infer a review disposition from comment text or draft count.

## Terminology

### Work Mode

An application-level environment with independent navigation, center tabs, Right Sidebar state, and restoration state.

### Code Work Mode

The current Argus experience: Projects, Workspaces, Panels, terminals, Files, and Changes.

### Review Work Mode

The environment for discovering, reading, discussing, and submitting reviews for Pull Requests.

### Repository Identity

Provider-qualified repository coordinates. For GitHub this includes the host, owner, and repository name. Repository Identity lets Argus recognize a repository before it has a local Project Repository Root.

### Pull Request

A provider-qualified review subject identified by Repository Identity and Pull Request number.

### Review Inbox

Open Pull Requests for which the active GitHub account is currently requested as an individual or eligible team reviewer.

### Saved Pull Request

A Pull Request retained independently of Review Inbox eligibility because the user added or saved it, it has an open tab, or it has local drafts.

### Pull Request Review Tab

A Review Work Mode Top-level Tab for one Pull Request. It owns section selection, selected file, Review Revision, progress, conversations, drafts, and submission state.

### Review Revision

The exact base and head commit pair loaded by a Pull Request Review Tab. Changed files, diffs, line anchors, and draft positions refer to this immutable pair.

### Pending Review

Unsubmitted review state for one Pull Request and Review Revision. It contains new inline draft comments, an optional summary, and a Review Disposition.

### Review Disposition

One of Approve, Comment, or Request Changes.

### Review Session State

Durable Review Work Mode navigation, tabs, layout, progress, Review Revisions, reply drafts, and Pending Reviews.

## Work Mode behavior

### State boundary

A Work Mode is an environment boundary, not a filter over shared tabs.

- Code and Review independently own their sidebar hierarchy and selection.
- Each mode independently owns its Top-level Tabs and Active Tab.
- Each mode independently owns Right Sidebar visibility, width, selected view, and contextual state.
- Switching modes preserves the source mode and restores the destination mode.
- Global Settings are shared.
- Project identity is shared. One repository must not become two Projects merely because it appears in both Work Modes.
- Asynchronous work in one mode must not select, activate, focus, or otherwise mutate the visible state of the other mode.

This boundary is recorded in `docs/adrs/0003-isolate-navigation-and-session-state-by-work-mode.md`.

### Picker and launch

![Work Mode picker and Review Inbox](work-mode-sidebar-wireframe.svg)

- The Work Mode picker sits in the 44-point left-sidebar header.
- It lists Code and Review and shows Review visual attention without requiring the menu to open.
- Argus stores the last selected Work Mode and restores it on launch.
- Selecting a mode restores its sidebar selection, Active Tab, layout, and appropriate keyboard focus.
- Switching modes does not create, close, reorder, or refresh tabs solely because of the switch.
- A standard application menu command and keyboard shortcut expose Work Mode switching. The final shortcut must not conflict with Workspace, Top-level Tab, pane, or sidebar commands.
- If general session restoration is disabled, Argus may omit reopened tabs and transient layout. It must retain Projects, Saved Pull Requests, and all user-authored review drafts.

## Provider and account boundary

The first release supports GitHub through the GitHub CLI (`gh`).

- Argus uses the active authenticated `gh` account for API reads and writes.
- Argus never requests, receives, stores, refreshes, or persists a GitHub token.
- Provider commands run non-interactively. Argus must not embed or capture an interactive authentication prompt.
- If `gh` is missing or unauthenticated, Review Work Mode shows the exact blocked state and the command needed to authenticate.
- Authentication, authorization, rate-limit, network, validation, and not-found errors remain distinct.
- Canonical GitHub and GitHub Enterprise Pull Request URLs are accepted when the active `gh` context supports the host.
- Provider-qualified models must not assume `github.com`, even though GitHub is the only implemented provider.
- One active account per host is supported. Multiple simultaneous accounts for one host are out of scope.

## Project and Pull Request intake

### Opening a URL

A user can paste a Pull Request URL from Review Work Mode.

1. Argus validates the URL and identifies the provider host, Repository Identity, and Pull Request number.
2. Argus loads enough metadata to confirm access and canonical identity.
3. It matches an existing Project by Repository Identity.
4. If no Project matches, it creates a remote-capable Project without cloning.
5. It adds the Pull Request to Saved, selects it, and opens or reuses its Pull Request Review Tab.

An intake operation must not clone, fetch, create a worktree, or modify a local repository. A URL error preserves the entered value and provides an actionable retry path.

### Remote-capable Projects

A Project may exist with Repository Identity and provider metadata before it has a local checkout.

- It appears in Review Work Mode immediately.
- It appears in Code Work Mode only after the user explicitly associates or creates a local checkout and Workspace.
- If an existing Named Project represents the same Repository Identity, Argus adds provider metadata to that Project rather than creating a duplicate.
- Display names and local paths are not sufficient identity for provider matching.

## Review sidebar

### Review Inbox and Saved

Review Work Mode combines provider discovery with durable user intent.

- The Review Inbox contains open Pull Requests where the active account has an individual or eligible team review request.
- Inbox synchronization creates remote-capable Projects when needed.
- Pasting a URL creates a Saved Pull Request even when the active account is not a requested reviewer.
- The user can save an Inbox item or remove a Saved item.
- A Pull Request with an open tab, unsent reply, Pending Review, or other non-discardable local state is Saved regardless of current Inbox eligibility.
- A clean, inactive item may disappear when it no longer qualifies for Inbox.
- Synchronization never closes a tab or deletes local state. Such an item moves to Saved.
- Closed or merged Saved Pull Requests remain visible, marked with their state, until explicitly removed.
- Removing an item with drafts or an open tab requires confirmation that names the state to be deleted.

### Ordering and filtering

- Projects sort alphabetically by display name with Repository Identity as the deterministic tie-breaker. Remote activity does not move whole Projects.
- Inbox appears before Saved inside a Project.
- Inbox Pull Requests sort by latest relevant GitHub activity descending, then Pull Request number.
- Saved Pull Requests are manually reorderable. A newly saved item initially follows latest-activity order.
- Rows show title, number, author, draft/open/merged/closed state, and semantic attention, draft, or failure indicators.
- A Review-wide field filters by Project, Repository Identity, title, number, and author.
- Filters cover Inbox, Saved, Draft, Open, Closed or Merged, and Needs Attention.
- Filtering changes visibility only. It does not change order, selection, membership, tabs, or review state.
- If a filter hides the selected row, its open tab remains active. Clearing the filter reveals the row again.

### Refresh

Review Inbox refresh keeps the current list visible, uses reserved progress chrome, and preserves expansion and selection. Results apply only to the host and account that initiated the request. A stale response must not overwrite a newer one.

## Pull Request Review Tab

### Identity and lifecycle

One Top-level Tab represents one Pull Request, not one file.

- Selecting a Pull Request opens or selects its Pull Request Review Tab.
- Identity is the provider-qualified Pull Request identity.
- Reopening the same Pull Request selects and refreshes the existing tab.
- Multiple Pull Requests may be open as separate tabs.
- Changed-file selection stays inside the tab.
- Review tabs use the shared tab bar for selection, reordering, and closing.
- Closing a tab retains unsent replies and Pending Review content in Review Session State. Explicitly discarding that content requires confirmation. Closing never publishes content.

### Sections

Each tab has Files, Activity, and Checks sections.

- **Files** is the default. It contains file navigation, diff, conversations, Viewed progress, drafts, and review submission.
- **Activity** shows the title, description, and chronological commits, reviews, issue comments, state changes, and provider events.
- **Checks** shows read-only mergeability, review decision, required approvals when available, conflicts, and CI/check status. Detailed results link to GitHub.
- Section selection is tab-local and restored.
- Switching sections preserves Files selection, scroll anchors, and drafts.
- Refresh keeps loaded content visible and shows progress in reserved chrome.
- Administrative and merge operations use an explicit Open on GitHub action.

"Insights" is not a section name because it does not describe a defined capability.

## Files section layout

![Wide Files section with changed files, diff, conversations, and review footer](review-files-wide-wireframe.svg)

All Pull Request-specific content stays inside the Pull Request Review Tab.

- The Files section has resizable changed-files, diff, and conversations regions.
- The global Right Sidebar is hidden by default in Review Work Mode and is not required to review.
- Pane sizes, collapsed state, selected file, and useful scroll anchors are tab-local.
- Resizing and collapse do not reload data, change selection, or steal focus.
- Dividers use the standard enlarged drag target and resize cursor.

### Adaptive layout

![Narrow Files section with tab-local drawers](review-files-narrow-wireframe.svg)

The diff remains primary as space contracts:

1. At wide sizes, changed files, diff, and conversations may remain visible together.
2. The changed-files region collapses first into a tab-local drawer.
3. At narrower sizes, conversations also collapse. Files and Conversations become mutually exclusive tab-local drawers over or beside the persistent diff.
4. Review summary is a compact persistent footer showing draft count and Review Disposition. It expands into a composer rather than reserving a large fixed lower pane.
5. At constrained height, the expanded composer scrolls independently and keeps submission controls reachable.
6. Temporary responsive collapse does not overwrite user-controlled collapse state.
7. Closing a drawer returns focus to the control that opened it or to the associated diff anchor.

Implementation chooses measured thresholds based on usable control and text sizes; fixed pixel breakpoints are not part of the product contract.

## Changed-file navigation

The changed-files navigator supports direct and progress-oriented movement through the Review Revision.

- It filters by path and may compact single-child directory chains.
- Directories sort before files; paths have deterministic ordering.
- Rows show Git change status, addition/deletion statistics when available, Viewed state, published conversation count, unresolved state, and local draft presence.
- Status never relies on color alone.
- Selecting a file replaces the selected diff without opening another Top-level Tab.
- Persistent controls and keyboard commands move to the next or previous changed file and next or previous unviewed file.
- Large sets are virtualized or bounded without making omitted files unreachable.
- Provider truncation is explicit.

### Viewed progress

- The user explicitly marks a file Viewed or Unviewed.
- Selecting, scrolling, or reaching the end of a file never marks it Viewed.
- Argus synchronizes explicit Viewed state to GitHub.
- After successful synchronization, GitHub state is authoritative.
- Offline or failed mutations remain visibly pending and retryable. Argus does not silently revert them or claim success.
- A Review Revision update reconciles renamed and removed paths and reports any progress it cannot map.

## Diff data and Review Revisions

GitHub is authoritative for Pull Request metadata, changed files, conversations, and base/head commit IDs. Review Work Mode does not require a clone.

- Each tab displays one immutable Review Revision at a time.
- Argus loads old and new file content for the exact commits and passes structured content to the existing Argus-owned renderer where supported.
- A local checkout may be a cache only when its Git objects match the exact Review Revision.
- Working-tree or index content must never alter a Pull Request diff.
- Added, modified, deleted, renamed, copied, binary, generated, and provider-truncated files have explicit states.
- Unsupported, binary, oversized, unavailable, or truncated content shows an in-tab explanation and Open on GitHub fallback rather than a blank or misleading diff.
- Refreshing the same Review Revision preserves loaded content, selection, expansion, scroll, and focus.

### New commits

When GitHub reports a different head commit:

- Argus keeps the loaded Review Revision visible.
- A persistent banner states that new commits are available.
- The user explicitly chooses when to update.
- Before updating, Argus identifies drafts or replies whose anchors may become invalid.
- Safely mappable drafts move to the new Review Revision.
- Unmappable drafts remain available and require edit, remap, or explicit discard.
- Updating never silently loses or publishes text and never changes Work Mode or focus.

## Conversations and authoring

### Published conversations

- The conversations region shows conversations for the selected file and Review Revision.
- It includes author, time, resolved or outdated state, comment history, and available actions.
- Selecting a conversation navigates to its diff anchor when available.
- Selecting an inline marker reveals the corresponding conversation.
- Resolve and Unresolve appear only when GitHub and the account permit them.

### Replies

- A reply composer belongs to one existing conversation.
- Text remains local until the user selects Send.
- Send publishes the reply immediately; it does not wait for Pending Review submission.
- A failed send preserves the text and provides retry.
- Merely typing, closing a composer, switching modes, or reconnecting never publishes a reply.

### New inline comments

- The user starts a comment from an eligible line or selected line range.
- New inline comments are drafts in one Pending Review tied to the exact Review Revision.
- Draft markers are visually and accessibly distinct from published comments.
- Editing or deleting a draft is local until submission.
- Argus rejects unsupported GitHub anchors with an explanation rather than moving the comment silently.

### Review summary and submission

![Expanded review summary and confirmation flow](review-submission-wireframe.svg)

- A Pending Review may have inline drafts, an optional summary, and one Review Disposition.
- The user explicitly chooses Approve, Comment, or Request Changes. Argus never infers it.
- The compact footer shows draft count and selected disposition and expands into the composer.
- Before publishing, confirmation names the Pull Request, disposition, number of inline comments, and whether a summary is included.
- One confirmed action submits the Pending Review and inline comments atomically to the extent GitHub supports.
- Success refreshes conversations and review state, clears only submitted drafts, and keeps the tab open.
- Failure preserves all drafts and reports the specific error with a retry path.
- Closing, switching modes, refreshing, updating revision, going offline, or quitting never silently submits or discards content.

## Review attention

Review Work Mode uses visual attention only.

- The Work Mode picker indicates newly discovered review requests or unseen remote activity.
- Pull Request rows distinguish new commits, conversation/review activity, failed operations, and local drafts with semantic icons and accessible text.
- Attention does not play sound, post a macOS notification, switch modes, select a Pull Request, activate a tab, raise Argus, or change focus.
- Attention clears when the user views the relevant refreshed state. Opening Review Work Mode alone does not clear every item.
- Draft and failed-operation indicators are state, not unread attention, and remain until resolved.
- Repeated updates may collapse into one indicator. There are no numeric unread counts or notification history in the first version.

## Persistence and cache

Review Session State is independent from the Code Work Mode Session Snapshot.

It includes:

- ordered Projects and Pull Requests, membership, and expansion state;
- selected Pull Request;
- ordered review tabs and Active Tab;
- section, Review Revision, selected file, filters, Viewed intent, and useful scroll anchors;
- pane sizes and collapse state;
- unsent replies; and
- Pending Review comments, summary, and Review Disposition.

### Draft durability

- User-authored text uses debounced atomic autosave while editing.
- Argus also saves synchronously at meaningful tab, mode, and application lifecycle boundaries.
- A crash or forced replacement may lose only the final in-flight edit interval, not the full review session.
- Provider responses, rendered diffs, and avatars are replaceable cache data. They are stored separately from authoritative local drafts.
- Schema reconciliation preserves recoverable text even if surrounding provider metadata is stale.
- Invalid metadata must not cause silent whole-file draft loss.
- Removing a Project or Pull Request with drafts requires destructive confirmation.

### Offline behavior

Review Work Mode supports reading and drafting from the last complete cached Review Revision.

- Cached content remains navigable with a persistent stale/offline label and last successful refresh time when known.
- Users may compose replies, inline drafts, summary, disposition, and intended Viewed state offline.
- Sending, resolving, submitting, and authoritative Viewed synchronization require connectivity and authentication.
- Provider mutations never auto-publish when connectivity returns.
- The user explicitly retries after Argus refreshes state and validates the Review Revision.
- Conflicts preserve local text and require remapping, editing, or explicit discard.
- A partial refresh never replaces a complete cache with incomplete data.
- A Pull Request with no complete cache shows a recoverable blocked state while retaining any local drafts.

## Loading, empty, and failure states

Every asynchronous Review surface defines initial loading, background refresh, empty, error, stale, and loaded states.

- Initial loading names the object being loaded.
- Refresh retains useful content and reserves space for progress.
- Duplicate operations are disabled while running.
- Empty Inbox explains how to refresh or paste a Pull Request URL.
- No filter matches preserves the filter and offers Clear filters.
- Missing `gh`, unauthenticated host, authorization failure, not found, rate limit, network failure, stale revision, invalid anchor, and provider truncation have distinct states.
- Errors include provider detail when it helps recovery without exposing credentials.
- Failed writes preserve optimistic intent and authored text until retry or explicit discard.
- Background completion stays attached to the Pull Request and Review Revision that initiated it.

## Accessibility and keyboard behavior

- The Work Mode picker, Project rows, Pull Request rows, section controls, changed-file rows, diff markers, conversation threads, drawers, and review footer expose native button, menu, list, or disclosure semantics as appropriate.
- Icon-only controls have tooltips and accessibility labels.
- Attention, status, Viewed state, draft state, and errors do not rely on color alone.
- Focus order follows the visible layout: sidebar, tab/sections, files, diff, conversations, review footer.
- Collapsed regions leave persistent, keyboard-reachable controls.
- Opening a conversation from a marker moves focus only after an explicit user action.
- Refresh, synchronization, and remote activity do not move focus.
- Text in descriptions, diffs, comments, and errors remains selectable.
- Standard commands cover mode switching, section switching, next/previous changed file, next/previous unviewed file, file filter focus, conversation navigation, and opening the review summary.
- Exact shortcut chords are assigned during implementation after checking the complete command table.

## Security and data handling

- All provider input is untrusted. URLs, Markdown, diff content, paths, author names, avatars, comments, and check output must not execute local code or escape their renderer boundary.
- `gh` arguments are passed as process arguments, not composed into a shell command.
- HTML/Markdown rendering uses a constrained Argus-owned WebKit bridge with no arbitrary navigation or script injection from provider content.
- Open on GitHub validates the destination against the Pull Request's authenticated provider host.
- Logs and error UI must not expose tokens, authorization headers, or unrelated `gh` configuration.
- Local caches and Review Session State use user-only filesystem permissions appropriate for potentially private source and comments.
- Removing cache data and removing user-authored drafts are separate operations. Cache cleanup must never delete drafts.

## Delivery plan

The target is delivered in three usable increments. `docs/SPEC.md` is updated after each increment with only implemented behavior.

### Phase 1: Review foundation

- Work Mode picker and isolated Code/Review state.
- Last-mode launch and independent restore.
- `gh` availability and authentication states.
- Review Inbox and Pull Request URL intake.
- Remote-capable Projects and shared Repository Identity.
- Pull Request Review Tabs with Files, Activity, and Checks.
- Review Revision loading and structured per-file diffs.
- Changed-file filtering and navigation.
- Explicit GitHub Viewed synchronization.
- Read-only cached offline review.
- Visual attention for discovered requests and remote updates.

This phase is useful for reading and tracking reviews but does not claim reply or review-submission support.

### Phase 2: Review conversations

- Published file conversations and diff anchors.
- Conversation navigation and markers.
- Explicit replies with durable unsent text.
- Resolve/Unresolve where permitted.
- Conversation activity attention and failure recovery.

### Phase 3: Review authoring

- New inline draft comments.
- Pending Review summary and Review Disposition.
- Confirmed review submission.
- Crash-resilient draft autosave.
- Offline drafting.
- Review Revision update and draft remapping/conflict handling.

Review authoring must not ship without its durability and revision-safety requirements.

## Verification

### Domain and persistence

Cover:

- provider-qualified Project and Pull Request identity;
- URL matching without duplicate Projects;
- remote-capable Project transition to local Code use;
- independent Code and Review restoration;
- Inbox-to-Saved transitions;
- no draft loss during synchronization, mode switch, tab close, or schema reconciliation;
- atomic autosave and recovery after interrupted writes; and
- cache cleanup that leaves drafts untouched.

### Provider boundary

Use a fake command runner for most cases and the real `gh` boundary for a small integration suite. Cover:

- missing and unauthenticated `gh`;
- GitHub and Enterprise host resolution;
- private repository access;
- pagination, rate limits, cancellation, stale responses, and partial failures;
- noninteractive execution and argument escaping;
- Review Inbox queries and team requests;
- replies, resolve state, Viewed mutations, and review submission; and
- provider errors that retain local intent.

### Review Revision and diffs

Cover:

- exact base/head content extraction;
- no working-tree or index leakage;
- added, modified, deleted, renamed, binary, oversized, and truncated files;
- changed head detection without automatic replacement;
- selected-file and scroll preservation on same-revision refresh; and
- safe and unsafe draft remapping.

### UI contract

Cover:

- Work Mode state isolation and focus restoration;
- one reusable tab per Pull Request;
- Files, Activity, and Checks state preservation;
- wide and narrow adaptive layouts;
- full hit areas, hover, cursor, tooltips, accessibility labels, and stable geometry;
- explicit Viewed behavior without auto-marking;
- diff/conversation bidirectional navigation;
- confirmation before review submission or destructive draft removal; and
- no focus or selection mutation from background activity.

Manual verification covers pointer, keyboard, VoiceOver, dark and light appearance, window resizing, offline transitions, and private repository content.

## Acceptance criteria

The full proposal is complete when:

- Code and Review operate as independent, restorable environments under one Work Mode picker.
- Argus restores the last selected Work Mode without losing the other mode's state.
- The active `gh` account supplies GitHub access without Argus storing credentials.
- Review Inbox discovery and pasted URLs produce one Project per Repository Identity without implicit cloning.
- Pull Requests can move safely between Inbox and Saved without losing tabs or drafts.
- One reusable Pull Request Review Tab provides Files, Activity, and Checks.
- Changed files are filterable and navigable, and Viewed state changes only through explicit user action.
- Diffs display an exact Review Revision and do not change automatically when new commits arrive.
- Wide and constrained windows keep the diff usable and preserve file, conversation, and draft state.
- Published conversations and diff anchors navigate in both directions.
- Replies publish only through an explicit Send action.
- New inline comments remain drafts until one confirmed Pending Review submission.
- Review submission supports Approve, Comment, and Request Changes and preserves drafts on failure.
- User-authored review text survives mode switches, restart, and all but the final in-flight autosave interval after a crash.
- Cached content supports offline reading and drafting without automatic mutation replay.
- Review activity remains visual and never changes mode, tab, focus, or application activation.
- Unsupported content and all material provider failures have honest, recoverable states.

## Promotion

After each phase ships, add its stable behavior to `docs/SPEC.md` and update `docs/UI_DESIGN_PRINCIPLES.md` where Work Mode or review interaction patterns become project-wide rules. Keep this proposal until all phases are implemented or superseded.
