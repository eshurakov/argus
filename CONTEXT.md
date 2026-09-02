# Context

## Scope

Argus is a personal, single-process macOS terminal workspace manager. This
contract defines domain language and ownership boundaries for workspace,
worktree, terminal, repository-status, UI, persistence, IPC, and agent behavior.

## Contexts

| Context | Owns | Location | Notes |
|---|---|---|---|
| **Work Mode organization** | Application-level Work Mode selection and each Work Mode's independent navigation, content, sidebar, and restoration state | Future work under `docs/proposals/work-modes-review/` | Global Settings and Project identity remain shared across Work Modes. |
| **Workspace organization** | Projects, Workspaces, Panels, top-level tabs, panes, ordering, selection, and focus model within Code Work Mode | `Argus/Models/Project.swift`, `Argus/Models/Workspace.swift`, `Argus/Models/Panel.swift`, `Argus/Services/WorkspaceManager.swift` | UUIDs are identity; display names are not keys. |
| **Worktree management** | Repository validation, branch discovery, worktree creation/removal, managed storage, and orphan discovery | `Argus/Services/WorktreeService.swift` | All git operations use spawned `git` processes; no libgit2. |
| **Terminal runtime** | Global Ghostty engine, terminal surfaces, shell processes, rendering, terminal input, and first-responder behavior | `Argus/Ghostty/`, `Argus/Models/TerminalPanel.swift` | One global `GhosttyApp`; one Terminal Surface per Terminal Panel. |
| **Files and Changes** | Right-sidebar navigation, workspace file tree, Git status snapshot, change actions, filesystem item actions, and file/preview loading | `Argus/Views/GitSidebar/`, `Argus/Models/GitStatus.swift`, `Argus/Services/GitStatus*`, `Argus/Services/GitPreviewService.swift` | Git Status Root never follows a terminal's live working directory. |
| **Pull Request Status** | Read-only provider discovery, Workspace-scoped status, refresh scheduling, and freshness | `Argus/Services/WorkspacePullRequestStatusModel*`, `Argus/Services/GitHubPullRequestService+Status.swift`, `Argus/Models/PullRequestStatus.swift` | Main-window-owned runtime, independent of sidebar visibility and local Git Status Snapshots. |
| **User interface** | Single-window surface placement, tab behavior, interaction affordances, chrome, and accessibility contract | `Argus/Views/`, `docs/UI_DESIGN_PRINCIPLES.md` | Inspectable content belongs in Workspace tabs, not independent windows. |
| **Session persistence** | Session snapshots, restore validation, Project/Workspace reconciliation, and sidebar preferences | `Argus/Models/SessionSnapshot.swift`, `Argus/Services/WorkspaceManager.swift`, `Argus/Views/Sidebar/SidebarState.swift` | Durable state and ephemeral runtime state must remain distinct. |
| **Agent status and integrations** | In-process Agent Status display, Turn Completion Attention, Socket Server routing, and external integration setup | `Argus/Services/AgentStatusStore.swift`, `Argus/Services/AgentStatusRuntime.swift`, `Argus/Services/TurnCompletionAttentionStore.swift`, `Argus/Services/AgentSocketServer.swift`, `Argus/Services/KiloIntegrationService.swift`, `Argus/Services/PiIntegrationService.swift`, `ArgusCLI/` | The Socket Server implements only the agent turn-completion and live Agent Status methods; the Companion CLI remains a scaffold. |

## Canonical Terms

| Term | Agent meaning | Use this when | Avoid |
|---|---|---|---|
| **Argus Application** | Native macOS app process that owns all authoritative domain state, UI, and persistence. | Referring to the app or its process-wide behavior. | "server process", "daemon", "backend". |
| **Work Mode** | Application-level environment that owns an independent sidebar hierarchy and selection, center tabs, Right Sidebar state, and restoration state. | Referring to the top-level Code or Review environment selected from the left-sidebar header. | "mode" for a transient view filter or cosmetic layout. |
| **Code Work Mode** | Work Mode containing the current Project, Workspace, Panel, terminal, Files, and Changes workflows. | Referring to the existing Argus experience after Work Modes are introduced. | "coding mode", which implies only terminal or agent activity. |
| **Review Work Mode** | Work Mode organized around finding, reading, discussing, and submitting reviews for Pull Requests. | Referring to the proposed Pull Request review environment. | "PR mode" or a local Git Preview workflow. |
| **Companion CLI** | The external `argus` executable reserved for future application control. It is a nonfunctional scaffold in v1. | Referring to the CLI target or proposed transport behavior. | Describing socket-backed commands as implemented. |
| **Project** | UUID-identified aggregate representing one repository across Work Modes. A Project may initially have only a hosted Repository Identity for Review Work Mode and acquire a local Project Repository Root when Code Work Mode is configured. | Referring to repository grouping, shared identity, and cross-mode association. | "repo" when application identity or UI grouping is intended. |
| **Named Project** | Current stable Code Work Mode form of a Project with an immutable Project ID, local Project Repository Root, main-branch metadata, and child Workspaces. The Review Work Mode proposal generalizes Project identity beyond this local-checkout requirement. | When current local repository ownership or removal behavior matters. | "normal project", "regular project". |
| **Repository Identity** | Stable hosting-provider and repository coordinates used to recognize one hosted repository independently of a local checkout path. | Matching a Pull Request URL to a Project and preventing duplicate cross-mode Projects. | Repository display name or local path as hosted identity. |
| **Pull Request** | Provider-qualified review subject identified by Repository Identity and provider Pull Request number. | Review Work Mode navigation, tabs, refresh, conversations, and review submission. | Local branch, Git Preview Tab, or an unqualified "PR" in domain contracts. |
| **Pull Request Status** | Runtime-only provider lifecycle, aggregate review/check results, and refresh health associated with a Worktree Workspace's currently observed branch and Repository Identity. | Sidebar Pull Request Status icons, read-only provider refresh, and status summaries. | Git Status Snapshot, Agent Status, a durable Pull Request association, or merge readiness. |
| **Review Inbox** | Provider-synchronized set of open Pull Requests for which the active GitHub account is explicitly requested as a reviewer. | Automatic Review Work Mode discovery and refresh. | All open Pull Requests or durable ownership of local review state. |
| **Saved Pull Request** | Pull Request retained in Review Work Mode independently of current Review Inbox eligibility because it was manually added, explicitly saved, has an open review tab, or has local drafts. | Durable review navigation and safe retention. | A bookmark with no review state or an Inbox item that may be dropped unconditionally. |
| **Catch-all Project** | The single synthetic, non-removable Project displayed as "Workspaces" that groups Standalone Workspaces. | Referring to unassigned Workspace organization. | "default project", "misc project", "unassigned project". |
| **Project ID** | Immutable UUID used for identity, cross-references, and managed worktree storage paths. | Keys, persistence, APIs, and paths. | Project display name, repository basename, or slug as identity. |
| **Workspace** | UUID-identified user work context with one Workspace Root, ordered top-level tabs, a Panel registry, and optional Named Project association. | Referring to the unit selected in the left sidebar. | "terminal", "worktree", or "tab" as a synonym. |
| **Empty Workspace** | Existing Workspace with an empty Top-level Tab order and Panel registry, no Active Tab or Focused Pane, and no live Terminal Surfaces. It retains its identity, Workspace Root, Project association, sidebar position, and Files and Changes context. | Retained Workspace state after the final Terminal Tab closes when the global keep-open preference is enabled. | Calling a fresh Workspace "empty" or adding a placeholder Panel. |
| **Fresh Workspace** | Newly created Workspace that starts with one Terminal Tab backed by one Terminal Panel. | New Workspace creation and the fallback created after explicitly closing the last Workspace. | Empty Workspace. |
| **Workspace ID** | Persistent UUID used for Workspace identity, Project cross-references, session restore, and `ARGUS_WORKSPACE_ID`. | Keys, persistence, IPC, and Workspace lookup. | Workspace Number, title, branch, or path as identity. |
| **Standalone Workspace** | Workspace not associated with a Named Project and grouped under the Catch-all Project. | User-facing docs, tasks, and domain behavior for `WorkspaceType.external`. | "external workspace", "loose workspace", "unassigned workspace" except when discussing reconciliation. |
| **Main-checkout Workspace** | Workspace rooted at a Named Project's repository checkout. | Referring to `WorkspaceType.mainCheckout`. | "main workspace"; the checked-out branch need not equal the Project's main branch. |
| **Worktree Workspace** | Workspace rooted at a secondary git worktree. | Referring to `WorkspaceType.worktree`. | "branch workspace" when checkout type matters. |
| **Stack** | A connected set of locally recorded branch-parent relationships from Git configuration, Graphite metadata, or GitHub `gh-stack` tracking. A branch has at most one unambiguous recorded parent; a parent may have multiple dependents. Unparented main/trunk branches separate independent Stacks. | Read-only discovery of related branches across a Named Project's worktrees. | Tool-owned containers as the only grouping authority, arbitrary Git ancestry, or a promise of live GitHub review/queue state. |
| **Stack Group** | Derived left-sidebar grouping of at least two open Workspaces belonging to one Stack, with necessary nonselectable branch references and truthful fork connectors. It does not own Workspaces. | Collapsible stack navigation, parent-before-dependent ordering, and whole-group sidebar reordering. | A parent Workspace, a new Project, or an instruction to restack Git branches. |
| **Managed Worktree** | Secondary worktree stored under `~/.argus/worktrees/<project-uuid>/<branch-slug>/`. | Ownership, cleanup, orphan detection, and storage behavior. | Assuming every Worktree Workspace is managed. |
| **External Worktree** | Existing secondary git worktree outside Argus managed storage. | When location or deletion ownership differs from a Managed Worktree. | `WorkspaceType.external`, which means Standalone Workspace. |
| **Orphaned Worktree** | Managed Worktree found on disk without corresponding Workspace state. | Launch scan, adopt, delete, or dismiss workflows. | Any stale git worktree entry or any External Worktree. |
| **Workspace Root** | Stable filesystem directory for a Workspace, currently stored as `Workspace.currentDirectory`. | Files view roots, Standalone Workspace roots, and generic Workspace filesystem context. | "current directory" or "cwd" without qualification. |
| **Terminal Working Directory** | Live shell directory for one Terminal Panel, exposed through its Terminal Surface. | Shell PWD or pane-local directory behavior. | Workspace Root. |
| **Project Repository Root** | Canonical top-level checkout path stored in `Project.repositoryPath`. | Named Project validation and Main-checkout Workspace behavior. | `.git` directory, git common directory, or repository display name. |
| **Git Status Context** | Workspace classification and paths used to resolve the Git Status Root. | Inputs to root resolution before status or mutation work. | "git context" for loaded branch/status data. |
| **Git Status Root** | Resolved checkout directory used for Git status, Git mutations, previews, and FSEvents. | Any repository-status operation. | Terminal Working Directory or an unqualified `rootPath`. |
| **Panel** | UUID-identified content object with close and focus lifecycle that may back a top-level tab or a pane. | Model and lifecycle code shared by terminal, browser, file, Git preview, and release-notes content. | "tab" or "pane" when layout role matters. |
| **Panel ID** | UUID identifying any Panel instance. | Generic Panel lookup and Workspace ownership. | Surface ID for nonterminal Panels. |
| **Top-level Tab** | Ordered tab-bar unit represented by a root Panel ID and its tab layout. | Selection, reordering, closing, and tab-bar labels. | "Panel" when discussing tab order; `panelOrder` contains only top-level roots. |
| **Pane** | Leaf position in one top-level tab's split layout, backed by a Panel. | Split, focused input, and pane-local close behavior. | A separate model type; every pane is backed by a Panel. |
| **Terminal Panel** | Panel that owns exactly one Terminal Surface and belongs to one Workspace. | Terminal tab or split-pane model behavior. | Terminal Surface when model ownership is intended. |
| **Browser Panel** | Runtime-only Panel that owns browser navigation state, backs a top-level tab, and has no Terminal Surface. | Browser tab, WebKit, and background-focus behavior. | Terminal Panel, Terminal Surface, independent browser window, or persisted v1 Panel state. |
| **Terminal Surface** | Ghostty runtime resource that owns terminal rendering, input, shell process, title, PWD, and focus state. | Ghostty integration and `ARGUS_SURFACE_ID`. | Generic UI "surface" or nonterminal Panel. |
| **Surface ID** | Runtime UUID of a Terminal Surface, intentionally equal to its Terminal Panel ID. | Terminal-scoped IPC, environment variables, and focus events. | Generic Panel ID; Browser, File, and Git Preview Panels have no Terminal Surface. |
| **Selected Workspace** | Application-level Workspace selected in the left sidebar. | `WorkspaceManager.selectedWorkspaceId` and global navigation. | "active workspace" when comparing with Active Tab. |
| **Active Tab** | Top-level Tab currently shown in one Workspace. | Tab selection and tab-bar state. | Selected Workspace or Focused Pane. |
| **Focused Pane** | Panel leaf selected for input inside the Active Tab. | Split-pane focus and close behavior. | Active Tab; AppKit first responder when exact keyboard recipient matters. |
| **Right Sidebar** | Toggleable right column containing the Files and Changes views. | Whole-column layout, visibility, and width. | "right git sidebar" for the current combined surface. |
| **Right-sidebar View** | One selectable navigator inside the Right Sidebar. | Referring generically to Files or Changes. | "panel" or "tab", which collide with Workspace concepts. |
| **Files View** | Right-sidebar View that navigates the selected Workspace's filesystem from its Workspace Root. | Filesystem browsing and Workspace Item actions. | "Files panel", "repository browser", "git files". |
| **Changes View** | Right-sidebar View that presents one Git Status Snapshot as an ordered collection of typed Change Sections. Its default layout is Staged, Unstaged, and Untracked; global Files & Changes settings may present Uncommitted and append Against Base. | Branch status, change rows, and Git actions. | "Git sidebar" when only this view is intended; user-facing "Git Status". |
| **Workspace File Tree** | Lazy filesystem hierarchy shown by the Files View. | Workspace files and directories. | Bare "file tree" or Change Tree. |
| **Workspace Item** | File or directory represented in the Workspace File Tree. | Open, copy, rename, or delete operations that may target either kind. | "file" when directories are valid. |
| **Workspace Item Operation** | Files View operation on a Workspace Item: open, copy, rename, or delete. | Filesystem action code, tests, and docs. | "Git file operation". |
| **Change Tree** | Presentation hierarchy grouping Git File Changes by directory inside one Change Section. | Changes View row organization. | Workspace File Tree. |
| **Git Status Snapshot** | Loaded repository status summary for one Workspace and Git Status Root, produced for one Git Status Request. | Branch, upstream, counts, and changed entries. | Unqualified "status". |
| **Git Status Presentation** | Immutable presentation inputs for one snapshot: whether to combine Working Changes, whether to show Against Base, and the optional configured Base Branch name. | Settings-to-service boundaries and snapshot identity. | Reading App Settings directly from a Git status service. |
| **Git Status Request** | Immutable request containing a Git Status Root path and Git Status Presentation. | Status loading, mutation refreshes, FSEvents refreshes, and stale-result checks. | A root path without the presentation that shaped the result. |
| **Git Status Snapshot Owner** | Pair of Workspace ID and complete Git Status Request that owns one published Git Status Snapshot. | Async ownership and rejecting results from another Workspace or layout. | Workspace ID or root path alone as snapshot identity. |
| **Working Changes** | Staged, unstaged, and untracked state reported for the Git Status Root. Working Changes determine dirty state and remain actionable in every Changes View layout. | Working-tree cleanliness, Uncommitted construction, and Git Mutations. | Committed Against Base entries. |
| **Change Section** | Typed presentation section in a Git Status Snapshot: Staged, Unstaged, Untracked, Uncommitted, or Against Base. A section may be available or unavailable. | Section order, counts, expansion, IDs, and Section Operations. | Generic "file section" or stringly typed `sectionKey` in new domain APIs. |
| **Uncommitted** | Change Section containing one row per unique Working Changes path. Each row represents the net `HEAD`-to-working-tree difference while retaining staged, unstaged, and untracked state flags. | The combined working-change layout and subset-specific actions. | Treating the index as changed by the presentation setting. |
| **Base Branch** | Local branch reference used for the committed comparison. A Recorded Base Branch wins when one is present; otherwise Named Projects use the configured `Project.mainBranch` and Standalone Workspaces use only the documented local origin-HEAD, `main`, and `master` detection. | Against Base resolution and labels. | Current branch, upstream branch, arbitrary remote branch, or a branch fetched implicitly. |
| **Recorded Base Branch** | A branch's locally declared parent, read by one shared metadata reader from `branch.<branch>.base`, Graphite `parentBranchName` objects, or schema-v1 `gh-stack` tracking. A valid explicit configuration value wins; matching tool records coalesce and contradictory tool parents are diagnosed. Grouping retains missing-parent names; Against Base resolves local refs before origin-tracking refs. | Shared Stack relationships and committed comparison base selection. | A base guessed from a branch name or commit ancestry, a remote query, or Git's own inferred parent — Git never writes these declarations. |
| **Against Base** | Read-only Change Section containing committed differences from the merge base of the resolved Base Branch and `HEAD` to `HEAD`. It never contributes to dirty Working Changes state. | Committed branch work, read-only rows, and Base Branch previews. | Uncommitted or upstream status. |
| **Git Diff Source** | Typed comparison source attached to a Git File Change: Staged, Unstaged, Untracked, Uncommitted, or Against Base with its Base Branch name and resolved ref. | Preview loading, blame targets, and action routing. | Inferring comparison semantics from a localized section title. |
| **Git File Change** | One section-specific changed-path entry, including typed section and diff source, status, path, optional original path, diff statistics, and Working Changes state flags. | Identity, row behavior, accessibility, and section counts. | "file" when a path may have separate entries for different comparison contexts. |
| **Git File Status** | Change kind for a Git File Change, such as added, modified, deleted, renamed, or untracked. | Status icon, color, parsing, and accessibility. | Git Status Snapshot or Agent Status. |
| **Change Action** | Any action exposed for a Git File Change, including mutations, preview actions, and copy path. | Describing the complete row action set. | "Git mutation" for diff, blame, or copy path. |
| **Git Mutation** | Stage, unstage, discard, or delete operation that changes index or working-tree state. | Service APIs, confirmation, and post-operation refresh. | Diff, blame, or copy path. |
| **Section Operation** | Git Mutation applied to an entire classic Change Section or to a named Working Changes subset, including entries omitted by display caps. Against Base has none. | Stage all, unstage all, discard all, discard all unstaged, and delete all untracked. | "bulk operation" without section scope. |
| **File Tab** | Top-level Tab backed by a File Panel and identified within a Workspace by Workspace Root plus relative path. | Opening or reusing Workspace file content. | "file preview", independent file window. |
| **Release Notes Tab** | Runtime-only Top-level Tab displaying Argus's bundled release notes in the Selected Workspace. | Reading the Argus application changelog opened from the Help menu. | "What's New window", independent release-notes window, or a Workspace File Tab. |
| **Git Preview Tab** | Top-level Tab backed by a Git Preview Panel and identified within a Workspace by Git Status Root, Preview Kind, and path. | Diff or blame presentation and refresh-in-place. | "preview panel" or floating `NSPanel`. |
| **Pull Request Review Tab** | Review Work Mode Top-level Tab identified by provider-qualified Pull Request identity and owning that Pull Request's selected file, review progress, conversations, drafts, and submission state. | Reading and operating on one Pull Request in Review Work Mode. | One tab per changed file or a local Git Preview Tab. |
| **Review Revision** | Immutable base and head commit pair loaded by one Pull Request Review Tab and used for its changed-file set, diffs, line mappings, and draft positions. | Refresh, stale-head detection, draft reconciliation, and review submission. | Whatever Pull Request head happens to be latest during an operation. |
| **Pending Review** | GitHub-backed, unsubmitted review state for one Pull Request and Review Revision, containing new inline draft comments, an optional summary, and a selected review disposition. | Composing and confirming a Pull Request review submission. | Unsent reply text for an existing conversation or a published review. |
| **Review Disposition** | Submission choice for a Pending Review: Approve, Comment, or Request Changes. | Review summary controls, confirmation, and submission. | Pull Request merge state or a local Git status. |
| **Preview Kind** | Semantic Git preview operation: diff or blame. | Tab identity and action choice. | Preview rendering payload. |
| **Preview Content** | Loaded rendering payload, currently structured diff or ANSI text. | Renderer selection and fallback messages. | Preview Kind. |
| **Session Snapshot** | Codable durable Code Work Mode state written to Argus application support storage and validated as one schema version. Review Work Mode uses independently persisted Review Session State. | Current Code Work Mode save, restore, limits, and reconciliation. | Runtime view state, Review Session State, or Agent Status. |
| **Review Session State** | Durable Review Work Mode navigation, tab, Review Revision, progress, layout, reply-draft, and Pending Review state. User-authored drafts use crash-resilient autosave; provider responses are stored separately as replaceable cache data. | Review Work Mode restore and draft-loss prevention. | GitHub as the sole owner of unsent content or the Code Work Mode Session Snapshot. |
| **Unix Domain Socket** | User-local transport endpoint at `~/.argus/argus.sock` used by implemented integrations. | Local integration transport. | Separate process or network service. |
| **Socket Server** | App-owned component accepting bounded newline-delimited JSON requests over the Unix Domain Socket. | Implemented integration routing. | Separate process, daemon, or Companion CLI. |
| **Socket Request** | Versioned newline-delimited JSON request accepted by the Socket Server. | Implemented integration wire behavior. | Inferring unsupported Companion CLI methods. |
| **Request ID** | Socket protocol correlation identifier unrelated to domain entity IDs. | Correlating responses to implemented Socket Requests. | Project ID, Workspace ID, Panel ID, or Surface ID. |
| **Agent Key** | Unrestricted string identifying an agent in the v1 in-process Agent Status store or a future integration. | Agent Status and proposed agent-agnostic IPC. | Product-specific enum or hard-coded Kilo-only value. |
| **Agent Integration** | External plugin or client that translates an agent process lifecycle into Socket Requests, Agent Status Entries, PID registration, and Agent Notifications. | Integration-side lifecycle and cleanup behavior. | App-owned Agent Tracker or Kilo-only behavior. |
| **Agent Status Entry** | Ephemeral agent telemetry scoped to a Workspace or Terminal Surface. | Agent lifecycle display and cleanup. | Git Status Snapshot, Git File Status, or load state. |
| **Workspace-level Agent Status** | Agent Status Entry without Surface ID that applies across a Workspace. | Workspace-wide telemetry and fallback display. | Per-panel Agent Status. |
| **Per-panel Agent Status** | Agent Status Entry scoped by Surface ID to one Terminal Panel. | Pane-specific agent telemetry. | Generic Panel-scoped state for File or Git Preview Panels. |
| **Turn Completion Event** | Agent-agnostic `agent.turnCompleted` Socket Request identifying an Agent Key, Workspace ID, Surface ID, and integration event ID. | Successful coding-agent turn completion delivery. | Kilo lifecycle details or Agent Status Entry. |
| **Turn Completion Attention** | Runtime-only state indicating that the Top-level Tab containing a completed agent turn has not been viewed. | Tab and Workspace bell indicators and acknowledgment. | Agent Status Entry, history, count, or persistent notification. |
| **Foundation Notification** | In-process `NotificationCenter` event coordinating app UI and Ghostty state. | Internal event wiring. | Agent Notification or public socket method. |
| **Workspace Number** | Global one-based Workspace position in left-sidebar order across all Projects. | Keyboard shortcuts and proposed notification wording. | Project-local index or Workspace ID. |

## Relationships

- The Argus Application owns one `WorkspaceManager`, one global `GhosttyApp`, and the process-wide Socket Server used by implemented integrations. The Socket Server routes Turn Completion Events and live Agent Status updates into MainActor-owned runtime stores.
- The Argus Application has one selected Work Mode. Code Work Mode and Review Work Mode independently own navigation selection, center tabs, Right Sidebar state, and restoration state while sharing global Settings and Named Project identity.
- A Named Project references an ordered set of Workspaces by Workspace ID.
- A Stack Group projects the shared recorded-parent forest onto a Named Project's open Workspaces. It does not change ownership; verified current checkout paths and branch references supply bindings, while Workspace IDs remain authoritative for selection and lifecycle. Parents precede dependents and siblings retain their real shared parent.
- Stack discovery and Against Base read the same effective branch-base configuration, Graphite parent objects, and schema-v1 gh-stack tracking across common/linked Git directories without invoking stack-management CLIs or contacting GitHub. Explicit configuration wins; conflicts are diagnosed per branch and unrelated valid data remains usable. The fully expanded projection supplies navigation order; only collapsed group keys persist. Recorded relationships are not a live Pull Request target or GitHub review-state query.
- A Project may be created from Repository Identity for Review Work Mode without cloning. It appears in Code Work Mode only after a local checkout and Workspace are configured.
- In the first Review Work Mode release, a Pull Request is hosted by GitHub and all authenticated provider operations use the active GitHub CLI authentication context; Argus does not own or persist GitHub credentials.
- Explicit Pull Request intake in Code Work Mode's per-Named-Project New Workspace sheet may create a Worktree Workspace from a Pull Request URL or number. This intake is separate from opening a Pull Request Review Tab in Review Work Mode and does not create review state.
- Review Work Mode discovers the active account's Review Inbox and groups Pull Requests by Project. Pull Requests with durable user intent or local review state become Saved Pull Requests and are not removed by Inbox synchronization.
- The Catch-all Project groups Standalone Workspaces and is ordered after Named Projects.
- A Workspace has one Workspace Root, owns all of its Panels, orders top-level Panel roots as Top-level Tabs, and stores one split layout per Top-level Tab.
- A Top-level Tab contains one or more Pane leaves; closing the tab closes every Panel in its layout.
- A Terminal Panel owns exactly one Terminal Surface, and their UUIDs are equal during that runtime session.
- A Browser Panel owns browser state, follows the normal top-level tab lifecycle, and must not steal focus while its tab is in the background.
- A nonempty Selected Workspace contains one Active Tab, and the Active Tab contains one Focused Pane. An Empty Workspace contains neither.
- A Main-checkout Workspace resolves its Git Status Root from its Named Project's Project Repository Root.
- A Worktree Workspace resolves its Git Status Root from its worktree path.
- Pull Request Status uses a Worktree Workspace's observed branch/HEAD and verified Repository Identity, not its stored branch label or original intake. `MainWindowView` owns the runtime; services own local input reads and provider I/O.
- A Standalone Workspace resolves its Git Status Root from its Workspace Root.
- A Git Status Request combines one Git Status Root with one Git Status Presentation, and a Git Status Snapshot Owner pairs that request with a Workspace ID.
- A Git Status Snapshot exposes ordered Change Sections. A path may appear in more than one section when it represents different comparison contexts, while Uncommitted itself contains one row per unique Working Changes path.
- A Base Branch comparison is local and offline: it resolves only a Recorded Base Branch, the configured Project main branch, or the documented Standalone Workspace candidates, and it never fetches.
- A Git File Change belongs to one typed Change Section and one Git Diff Source; one path may have separate entries for Working Changes and Against Base.
- Working Changes determine dirty state. Against Base is committed, read-only, and does not make a clean Working Changes state dirty.
- A File Tab and Git Preview Tab belong to the Workspace that initiated them and use that Workspace's normal tab lifecycle.
- The Help menu opens or reuses one runtime-only Release Notes Tab in the Selected Workspace; the tab reads bundled application content rather than a Workspace Item.
- A Pull Request Review Tab belongs to Review Work Mode rather than a Code Workspace. One Pull Request has at most one open review tab, and changed-file selection remains inside that tab.
- A Pull Request Review Tab reads one Review Revision at a time. A newer remote head is announced but does not replace the loaded revision until the user explicitly updates.
- A Pending Review belongs to one Pull Request and Review Revision. Existing-conversation replies publish separately; new inline comments publish with the Pending Review and its Review Disposition.
- A Per-panel Agent Status overrides Workspace-level Agent Status for the same terminal context.
- The Session Snapshot persists Code Work Mode state. Review Session State persists Review Work Mode state independently. Agent Status Entries, agent PIDs, Git Status Snapshots, Pull Request Status, and socket connections are ephemeral.

## Agent Rules

- Read `docs/SPEC.md` before changing behavior; it governs correctness.
- Read `docs/UI_DESIGN_PRINCIPLES.md` before changing UI behavior or placement.
- Use Project ID, Workspace ID, and Panel ID for identity; never use a mutable display name as a key.
- Use `~/.argus/worktrees/<project-uuid>/<branch-slug>/` for Managed Worktree paths.
- Use **Standalone Workspace** in prose; `WorkspaceType.external` is a legacy code spelling, not the canonical concept name.
- Do not infer git scope from Terminal Working Directory; resolve and pass the Git Status Root.
- Do not assume every Workspace has a git context; a Standalone Workspace may be an ordinary directory.
- Do not use Panel, Top-level Tab, Pane, and Terminal Surface interchangeably.
- Use Ghostty's per-surface close-confirmation heuristic for running-process prompts; do not scan process groups or invent a second process-liveness API.
- Say **Selected Workspace**, **Active Tab**, and **Focused Pane** for their distinct state levels.
- Qualify "status" as Git Status Snapshot, Git File Status, Pull Request Status, Agent Status Entry, or a specific load state.
- Qualify "notification" as Agent Notification, Foundation Notification, macOS notification, or TTS announcement.
- Qualify "root" as Workspace Root, Project Repository Root, Git Status Root, or managed storage root.
- Qualify "file tree" as Workspace File Tree or Change Tree.
- Use **Workspace Item Operation** for Files View actions and **Git Mutation** or **Change Action** for Changes View actions.
- Use **Change Section**, **Git Status Presentation**, **Git Status Request**, and **Git Status Snapshot Owner** for typed Changes View domain boundaries; do not route new behavior through section titles or `sectionKey` strings.
- Use **Working Changes**, **Uncommitted**, **Base Branch**, and **Against Base** exactly as defined in Canonical Terms. Do not call Against Base an upstream or dirty change.
- Keep inspectable content in Workspace tabs; do not introduce an independent content window without changing the spec and UI contract.
- Preserve the initiating Workspace across asynchronous file, status, and preview work; completion must not redirect global selection.
- Keep durable domain state in models/managers and I/O behavior in services; views may own transient presentation state only.
- Use spawned `git` commands for git behavior and FSEvents for recursive repository watching.
- Keep the Companion CLI transport-only; it must not read session files or own application state.
- Socket and telemetry requests must not activate the app or change focus unless the request explicitly selects a Workspace or focuses a Panel.
- Live Agent Status Socket Requests use a reporting session ID and positive sequence number. The Agent Status runtime ignores duplicate or older updates and keeps status/order state ephemeral.
- Resolve environment fallbacks such as `ARGUS_SURFACE_ID` in the client or integration before sending a Socket Request.
- Treat Agent Status Entries and agent PIDs as ephemeral; never restore them from a Session Snapshot.
- Do not cache Surface IDs across application restarts.
- Use global sidebar order for Workspace Number; never calculate it per Project.
- When current code and the spec disagree, treat it as contract drift and reconcile both before changing behavior.

## Ambiguities

| Ambiguous term or conflict | Problem | Canonical decision |
|---|---|---|
| Project vs repository | A Project is an application aggregate; a repository is its hosted or local Git resource. | Use **Project** for aggregate behavior, **Repository Identity** for hosted identity, and **Project Repository Root** for a local checkout path. Use **Named Project** when current stable Code Work Mode behavior requires a local checkout. |
| Project identity across Work Modes | Review can know a hosted repository before Code has a local checkout, while the stable Named Project model currently requires a Project Repository Root. | Use one Project ID and Repository Identity across Work Modes. Do not clone implicitly or create duplicate Projects; add local checkout state only when Code Work Mode is configured. |
| Workspace vs worktree | A Workspace may be mistaken for its backing checkout. | A Workspace always has a Workspace Root; only Worktree Workspaces map to secondary git worktrees, and Standalone Workspaces may have no git context. |
| Panel vs tab vs pane vs surface | Current comments and APIs sometimes use these as synonyms. | Use layout and runtime definitions in Canonical Terms; a Panel can back a Top-level Tab or Pane, while only Terminal Panels own Terminal Surfaces. |
| `currentDirectory` | Name suggests live shell PWD but implementation uses it as stable Workspace filesystem context. | Call it **Workspace Root** in prose; use **Terminal Working Directory** for live PWD. |
| Right git sidebar | Current UI hosts Files and Changes, while spec and persistence names still assume git-only content. | Use **Right Sidebar** for the column and **Changes View** for Git status; retain legacy code keys only where migration requires them. |
| File tree | Files and Changes build unrelated hierarchies. | Use **Workspace File Tree** for filesystem enumeration and **Change Tree** for grouped changed paths. |
| Status | Means repository summary, per-file kind, agent telemetry, or load state. | Always use a qualified canonical status term. |
| Repository root | Can mean checkout root, `.git`, common dir, Workspace Root, or Git Status Root. | Name the exact root; **Project Repository Root** is checkout top-level, not git metadata. |
| External | `WorkspaceType.external` means Standalone Workspace, while an External Worktree is an existing worktree outside managed storage. | Use **Standalone Workspace** and **External Worktree** as separate concepts. |
| Preview panel | `GitPreviewPanel` is a Panel model, not an AppKit presentation surface. | User-facing concept is **Git Preview Tab**; no floating preview window. |
| Selection and focus | "Active" is used for Workspace, tab, Panel, and first responder. | Use Selected Workspace, Active Tab, Focused Pane, and AppKit first responder separately. |
| Empty Workspace | A retained Workspace with no Terminal content could be confused with the fresh Workspace fallback. | **Empty Workspace** means an existing Workspace with zero Top-level Tabs and zero Panels; **Fresh Workspace** means a newly created Workspace with one Terminal Tab. |
| Split panes | A Top-level Tab and its terminal Pane layout are distinct layers. | A Top-level Tab may own a split tree of terminal Panes. |
| Diff/blame presentation | Git Preview content could be confused with a transient preview surface. | Use **Git Preview Tab** in the initiating Workspace. |
| Panel taxonomy | Historical docs described Terminal/Browser only. | Treat Panel as extensible; v1 implements Terminal, Browser, File, Git Preview, and Release Notes Panels. |
| Base branch vs upstream | A committed comparison base is not necessarily the current branch's tracking branch and must remain local and deterministic. | Use **Base Branch** for the recorded, configured, or narrowly detected comparison branch. Recorded parents resolve local-first; configured/detected fallbacks resolve origin-first. Never use the current branch as its own fallback and never fetch. |
| Recorded base vs name inference | Reading a declared parent is not guessing from a branch's name or ancestry. | Use the shared **Recorded Base Branch** reader for configuration, Graphite parent objects, and gh-stack edges. Explicit configuration wins, contradictory tool records are diagnosed, and only recorded names receive local-first ref resolution. |
| Working vs committed changes | A path can have both Working Changes and committed branch differences without those rows describing the same content comparison. | Use **Working Changes** and **Uncommitted** for index/working-tree state; use **Against Base** for merge-base-to-`HEAD` committed differences. |
| Managed path identity | Managed Worktree paths need a stable Project partition. | Project UUID is the canonical path partition: `<project-uuid>/<branch-slug>`. |
| Catch-all membership | Fresh Standalone Workspaces may have nil `projectId`; restore reconciliation may assign Catch-all Project ID. | Unresolved data-model inconsistency; use Catch-all Project membership conceptually and do not change reference authority without a dedicated decision. |
| Worktree ownership | `WorkspaceType.worktree` does not distinguish Managed Worktree from External Worktree, yet deletion behavior depends on ownership. | Unresolved model gap; never infer safe deletion solely from workspace type or non-nil worktree path. |
| Branch collision | Branch names and Managed Worktree storage slugs have different collision behavior. | V1 rejects duplicate branch names; only storage-path slug collisions receive numeric suffixes. |
| Files feature authority | Files View and File Tab behavior includes global preferences whose scope must not be inferred from general Files semantics. | `docs/SPEC.md` defines both stable Files behavior and the limited scope of Files defaults. |
| Panel persistence | Persistence requirements differ by Panel type. | V1 restores Terminal Panels and their Terminal Working Directories; Browser, File, Git Preview, split layout, and tab/focus state are runtime-only. |
| Socket wire schema | The Socket Server implements version-one agent turn-completion and live Agent Status methods. | Keep the wire schema agent-neutral, bounded, validated against current Workspace ownership, and separate from Companion CLI command design. |
| Agent notification | Could mean IPC event, Foundation event, macOS notification, TTS, or deferred in-app history. | Use the qualified notification terms in Canonical Terms. |

## Context Boundaries

- **Workspace organization** owns Project and Workspace identity, membership, ordering, Panel lifecycle, and selection state.
- **Worktree management** owns repository validation, branch operations, explicit Code Work Mode Pull Request head preparation, Managed Worktree creation/removal, managed storage, and orphan cleanup; it does not own Workspace Item Operations or Git Mutations.
- **Terminal runtime** owns Ghostty resources and shell state; Workspace organization references terminal runtime through Terminal Panels and IDs.
- **Files and Changes** owns Workspace Item Operations and Git Mutations, may read Workspace context, must resolve I/O roots explicitly, and publishes inspectable content through Workspace tab APIs.
- **Pull Request Status** is a read-only consumer of Workspace/worktree context; it owns neither Git Mutations nor Review Work Mode state.
- **User interface** owns presentation and transient interaction state, not repository, worktree, Workspace, or session truth.
- **Session persistence** owns serialized durable state and reconciliation; it must exclude live process, socket, Git status, and Agent status state.
- Future integration proposals must keep the Companion CLI transport-only, the Socket Server app-owned, and authoritative domain state in the Argus Application.
- Cross-context references use stable IDs and explicit service APIs; views must not infer identity from labels or paths.

## Decision References

- `docs/SPEC.md` is authoritative for product behavior and non-negotiable architecture constraints.
- `docs/UI_DESIGN_PRINCIPLES.md` governs UI placement, interaction affordances, focus preservation, and accessibility.
- `docs/adrs/README.md` defines where accepted architecture decisions are recorded and how they are superseded.
- `docs/adrs/0002-render-structured-diffs-with-native-swift-diffs.md` defines ownership and runtime boundaries for structured diff rendering.
- `docs/adrs/0009-share-tool-agnostic-recorded-parents.md` supersedes ADRs 0007 and 0008 with shared local parent resolution, explicit-config precedence, partial diagnostics, and fork-aware Stack grouping. Their offline/reference/lifecycle constraints remain applicable.
- `docs/adrs/0008-read-only-worktree-pull-request-status.md` permits automatic read-only Pull Request Status while preserving ADR 0005's intake and credential guarantees.
- `docs/adrs/0009-host-batched-pull-request-status.md` records shared host batches, quota-aware pauses, and independent Workspace ownership of results.
- `docs/proposals/` contains future behavior and is not authoritative for the current application until a proposal is implemented and promoted into the spec.
