# Pull Request Workspace creation

## Status

- Lifecycle: Accepted
- Implementation: Implemented
- Last reviewed: 2026-08-08
- Stable-contract target: `docs/SPEC.md`

This proposal records the Pull Request Workspace intake design implemented in
the stable application contract. `docs/SPEC.md` is authoritative for shipped
behavior.

## Summary

Argus will let the user create a Worktree Workspace from a GitHub Pull Request
URL or positive Pull Request number in the existing per-Project New Workspace
sheet. Argus will resolve the Pull Request through the active GitHub CLI (`gh`)
authentication context, fetch its exact head commit, create or reuse the local
head branch and worktree, use the Pull Request title as the Workspace display
name, and select the resulting Workspace.

The flow is explicitly scoped to one existing Named Project. A URL must name a
base repository represented by one of that Project's fetch remotes. A bare
number uses the repository selected by `gh` for the Project Repository Root.
Argus will support both same-repository and fork Pull Requests without adding a
new Git remote.

## Goals

- Add Pull Request as a third source for a Worktree Workspace alongside New
  Branch and Existing Branch.
- Accept a canonical GitHub or GitHub Enterprise Pull Request URL or a positive
  Pull Request number.
- Resolve the Workspace display name and local branch name without a separate
  preview or confirmation step.
- Use the Pull Request title as the new Workspace's custom display title and
  the Pull Request head branch as its local branch.
- Fetch the exact Pull Request head, including heads from unconfigured forks.
- Reuse exact existing local branches, worktrees, and Workspaces without
  resetting or renaming conflicting local state.
- Use the active `gh` authentication context without requesting, reading, or
  persisting GitHub credentials.
- Preserve the existing Managed Worktree location, Workspace lifecycle,
  session persistence, and initial Terminal Panel behavior.

## Non-goals

- Global Pull Request intake or automatically choosing, creating, or cloning a
  Project from a URL.
- Supporting GitHub repositories that are not represented by a fetch remote of
  the selected Named Project.
- Supporting GitLab, Bitbucket, or another hosting provider in this release.
- Adding, removing, or rewriting Git remotes to make a fork available.
- Resetting, force-updating, deleting, or automatically renaming an existing
  local branch that does not match the Pull Request head.
- Persisting a durable association between the Workspace and Pull Request.
- Automatically refreshing the Workspace when the Pull Request head or title
  changes.
- Opening a Pull Request Review Tab or otherwise implementing Review Work Mode.
- Editing Pull Request metadata, checking review state, or providing merge and
  review operations.
- Preparing a release, changing the application version, or publishing a
  changelog entry as part of the implementation alone.

## Existing behavior and constraints

The current New Workspace sheet belongs to one Named Project and supports two
branch sources:

1. Create a new local branch with a generated or user-entered name.
2. Select an available existing local or remote branch.

Both paths delegate worktree creation to `WorkspaceManager` and
`WorktreeService`. Worktree Workspaces use
`~/.argus/worktrees/<project-uuid>/<branch-slug>/`, begin with one Terminal
Panel, and persist their branch, Workspace Root, worktree path, and optional
custom title through the existing Session Snapshot.

The implementation must preserve these established constraints:

- All Git operations use spawned `/usr/bin/git` processes.
- Durable Project and Workspace state remains owned by `WorkspaceManager`.
- Provider and Git I/O remain in services rather than SwiftUI views.
- The sheet remains text-only because SF Symbol rasterization during sheet
  presentation has caused a macOS 27 CoreUI crash.
- Asynchronous completion must not create a Workspace for another Project or
  redirect selection after the initiating Project disappears.
- Existing New Branch and Existing Branch behavior must not change.

## Settled product decisions

### Intake scope

Pull Request intake is available only from the existing New Workspace sheet for
one Named Project. The Project row's Add Workspace action and current sheet
presentation remain the entry point. The top-level New Workspace command and
the Catch-all Project continue to create Standalone Workspaces and do not gain
Pull Request intake.

A URL whose base Repository Identity does not match a fetch remote of the
selected Named Project fails in place. Argus does not redirect to a different
Project, even when another Named Project would match.

### Single-step creation

The user selects Pull Request, enters a URL or number, and presses Create. There
is no Load, Resolve, or metadata-preview step. The one operation resolves the
metadata, fetches the head, creates or reuses the worktree and Workspace, and
dismisses the sheet only after success.

The Pull Request input remains visible after failure so the user can correct or
retry it. While the operation runs, the source controls, input, and Create
button are disabled and the existing compact progress treatment is shown.

### Automatic Workspace name

A newly created Workspace receives:

- `title`: the local Pull Request head branch name;
- `branchName`: the same local branch name; and
- `customTitle`: the Pull Request title exactly as returned by GitHub.

Pull Request mode does not show the optional Workspace Name field. The user can
rename the Workspace after creation through the existing rename workflow.

When creation resolves to an existing Workspace, Argus selects it rather than
creating a duplicate. An existing non-empty user-assigned custom title is
preserved. If the Workspace has no custom title, Argus assigns the current Pull
Request title and checkpoints the Session Snapshot.

### Bare Pull Request numbers

A positive integer is interpreted in the Project Repository Root and follows
the repository selection rules of `gh`. This respects an explicit default set
with `gh repo set-default` and the GitHub CLI's normal unambiguous-remote
resolution.

Provider commands run with prompts disabled. If `gh` cannot select one
repository non-interactively, Argus reports that the default repository is
ambiguous and tells the user to run `gh repo set-default <remote>` in the
Project Repository Root. Argus does not silently prefer `origin` or `upstream`
for number lookup.

### Fork Pull Requests

Fork Pull Requests are supported through the base repository's read-only
`refs/pull/<number>/head` ref. This supplies the exact Pull Request head without
requiring the fork to be configured as a local Git remote.

If the Pull Request head Repository Identity already matches a configured fetch
remote, Argus may configure the new local branch to track that remote branch,
but only after confirming that the fetched remote branch points to the same
commit as the Pull Request head. When the fork is not configured, the local
branch intentionally has no upstream. Argus does not add a fork remote.

### Existing branch and worktree collisions

The Pull Request head branch name is the desired local branch name.

- If no local branch has that name, create it at the fetched Pull Request head.
- If the local branch already points to the fetched head, reuse it.
- If that exact branch is already checked out in a worktree, reuse the existing
  worktree path.
- If a Workspace in the selected Project already represents that exact
  worktree, select it instead of creating another Workspace.
- If the local branch points to any other commit, fail with a branch-collision
  error. Do not fast-forward it, reset it, force-update it, or generate a
  substitute name.

Uncommitted files in an exact existing worktree are not modified by intake.
The existing explicit close and worktree-deletion behavior remains unchanged.

## User interface plan

### Source selection

Replace the two-way text link used to toggle branch modes with a native,
text-only segmented picker containing:

- New Branch
- Existing Branch
- Pull Request

The picker must fit the existing sheet without symbols, retain native keyboard
and accessibility behavior, and be disabled while creation is running. New
Branch remains the initial selection.

### Pull Request fields

Pull Request mode shows one section labeled `Pull Request` with a rounded text
field whose placeholder is `URL or number`. The input is trimmed only at its
outer whitespace boundaries; internal URL and number content is not rewritten
by the view.

The optional Workspace Name section is shown only for New Branch and Existing
Branch. Branch generation, branch filtering, and existing-branch loading are
not started while Pull Request mode is selected.

Create is enabled when the trimmed Pull Request input is non-empty and no
operation is running. Pressing Return uses the normal default Create action.
Cancel retains its current semantics outside an operation and remains disabled
while the operation owns repository changes.

### Loading and errors

The existing action-row `ProgressView` and `Creating...` label cover metadata
lookup, fetch, worktree creation, Workspace creation, and selection as one busy
state. Duplicate submission is impossible during this state.

Errors remain inside the sheet below the source section. Error copy identifies
the failed boundary and includes useful provider or Git detail without exposing
credentials. The input, selected source, and current Project remain unchanged.
The Create action becomes available for retry after the operation ends.

## Domain types and service boundaries

### Repository Identity

Add a transient, provider-qualified `RepositoryIdentity` value with:

- provider (`github` in this release);
- lowercased host;
- lowercased owner; and
- lowercased repository name without a trailing `.git`.

Identity comparison is case-insensitive for the host, owner, and repository.
The original canonical URL remains available separately for display and
diagnostics. Repository Identity is not added to `ProjectSnapshot` by this
feature.

### Pull Request input

Add a parsed `PullRequestInput` enum:

```swift
enum PullRequestInput: Equatable, Sendable {
    case number(Int)
    case url(URL)
}
```

Parsing rules are deterministic:

- Trim leading and trailing whitespace and newlines.
- Accept digits only as a positive integer greater than zero.
- Accept an HTTPS URL shaped as
  `https://<host>/<owner>/<repository>/pull/<positive-number>`.
- Permit a copied URL's query, fragment, or trailing Pull Request subpath such
  as `/files`; identity and number come only from the canonical path prefix.
- Reject embedded credentials, non-HTTPS schemes, missing path components,
  non-numeric numbers, zero, and arbitrary branch text.

### Pull Request metadata

Add a Sendable `PullRequestWorkspaceMetadata` value containing:

- provider-qualified Pull Request identity;
- canonical Pull Request URL;
- Pull Request title;
- base Repository Identity;
- head Repository Identity when GitHub still exposes it;
- head branch name;
- head commit object ID; and
- whether GitHub reports a cross-repository head.

The service rejects empty titles, invalid head branch names, missing base
identity, and missing or malformed commit IDs rather than passing partial
metadata to worktree creation.

### GitHubPullRequestService

Add a non-MainActor `GitHubPullRequestService` with an injectable command runner
and a primary API equivalent to:

```swift
func resolve(
    _ input: PullRequestInput,
    repositoryPath: String
) async throws -> PullRequestWorkspaceMetadata
```

The production service locates an executable `gh` in this order:

1. Entries in the application process's `PATH`.
2. `/opt/homebrew/bin/gh`.
3. `/usr/local/bin/gh`.

It invokes `gh pr view` with an argument array, never through a shell. It asks
only for the JSON fields required by `PullRequestWorkspaceMetadata`, including
`number`, `title`, `url`, `headRefName`, `headRefOid`, `headRepository`,
`headRepositoryOwner`, and `isCrossRepository`.

The command inherits the normal environment with these noninteractive
overrides:

- `GH_PROMPT_DISABLED=1`
- `GH_PAGER=cat`
- `NO_COLOR=1`
- `GIT_TERMINAL_PROMPT=0`

Stdout and stderr are capped at 1 MiB each. The command times out after 30
seconds, terminates promptly when its Task is cancelled, and drains both pipes
without waiting for one pipe to close before reading the other. The service
never invokes `gh auth token`, `gh auth status --show-token`, or an equivalent
credential-exporting command.

### Remote identity resolution

Extend `WorktreeService` with a read-only remote resolver that lists remote
names and all fetch URLs for the Project Repository Root. Normalize and compare
these GitHub URL shapes:

- `https://host/owner/repository.git`
- `ssh://git@host/owner/repository.git`
- `git@host:owner/repository.git`

The PR's base Repository Identity must match at least one fetch URL. When
multiple remote names match the same identity, use `origin` if present and
otherwise the lexicographically first remote. This choice affects only the
fetch transport; it does not affect bare-number lookup.

Resolve the optional head remote using the same rules. Push-only URLs do not
establish Repository Identity for intake.

### Pull Request worktree preparation

Add a focused WorktreeService API equivalent to:

```swift
func createPullRequestWorktree(
    projectId: UUID,
    repositoryPath: String,
    metadata: PullRequestWorkspaceMetadata
) async throws -> PullRequestWorktreeResolution
```

`PullRequestWorktreeResolution` returns the actual local branch name, canonical
worktree path, fetched head object ID, and whether an existing worktree was
reused.

The operation performs these steps:

1. Resolve and validate the base remote against the selected Project.
2. Run `git fetch --no-tags <base-remote> refs/pull/<number>/head` without a
   destination ref.
3. Resolve `FETCH_HEAD^{commit}` and treat that commit as the authoritative
   head for this creation attempt. A head change between the `gh` read and Git
   fetch therefore produces a Workspace at the newer valid Pull Request ref
   rather than a stale checkout.
4. Validate the desired head branch with `git check-ref-format --branch`.
5. Inspect any local branch and registered worktree before changing refs.
6. Fail if an existing local branch does not equal the fetched head.
7. Otherwise create the missing local branch at the fetched head or reuse the
   exact branch.
8. If a configured head remote exists, refresh its remote-tracking head and set
   the local upstream only when it resolves to the same commit.
9. Reuse an exact existing worktree, or create the normal Managed Worktree with
   the existing slug and collision rules.

The fetch may update normal remote-tracking state, but it must not update an
existing local branch. If this operation created a local branch and later fails
before creating or reusing a worktree, it removes that branch only when it
still points to the fetched commit and is not checked out. It never cleans up
pre-existing branches or worktrees.

### WorkspaceManager orchestration

Inject `GitHubPullRequestService` into `WorkspaceManager` with a production
default, alongside the existing WorktreeService dependency. Add a throwing API
equivalent to:

```swift
@discardableResult
func createWorkspace(
    fromPullRequest input: String,
    in projectId: UUID
) async throws -> Workspace
```

The manager:

1. Parses the input and confirms that the Project exists and is not the
   Catch-all Project.
2. Rejects a new Workspace when the 128-Workspace limit is already reached.
3. Captures the initiating Project ID and Project Repository Root before
   leaving the MainActor for provider and Git work.
4. Resolves Pull Request metadata and prepares the worktree through services.
5. Revalidates that the same Project still exists with the same Project
   Repository Root before changing Workspace state.
6. Selects an existing Workspace when its Project, branch, and canonical
   worktree path match the resolution. It preserves an existing custom title
   or assigns the PR title when none exists.
7. Otherwise creates a Worktree Workspace using the resolved branch and path,
   sets its custom title to the PR title, appends it to the Project, selects it,
   and synchronously checkpoints the Session Snapshot.

The method throws typed errors rather than using only the manager's shared
`lastWorkspaceCreationError`. Existing branch-based creation may retain its
current compatibility surface; the sheet maps both paths into the same visible
error area.

If a newly created Managed Worktree cannot be attached to Workspace state after
service success, the manager attempts normal worktree removal. If cleanup also
fails, existing Orphaned Worktree discovery remains the recovery path and the
original error remains visible.

## Error model

Add a typed `PullRequestWorkspaceError: LocalizedError` that preserves useful
detail while keeping UI mapping stable. It must distinguish at least:

- empty or malformed input;
- missing GitHub CLI, with an installation hint;
- unauthenticated GitHub CLI, with `gh auth login --hostname <host>` guidance
  when the host is known;
- ambiguous or unavailable default repository for a bare number, with
  `gh repo set-default` guidance;
- inaccessible, missing, or invalid Pull Request metadata;
- unsupported or mismatched base Repository Identity;
- unavailable or invalid Pull Request head;
- conflicting local branch, including its name;
- provider timeout or cancellation;
- Git fetch failure; and
- worktree creation or cleanup failure.

Do not classify errors solely through one full stderr string when a command,
exit status, parsed input, or missing executable provides a stronger signal.
Provider stderr may be retained as bounded diagnostic detail, but error copy
must not log environment variables or credentials.

## Persistence and compatibility

No Session Snapshot schema change is required. The existing Workspace snapshot
already persists:

- Workspace ID and Project association;
- Workspace type;
- Workspace Root and worktree path;
- branch name;
- derived and custom title; and
- Terminal Panel restoration data.

Pull Request number, URL, base Repository Identity, head commit, and provider
metadata remain transient intake data. Restarting Argus restores an ordinary
Worktree Workspace. It does not re-query GitHub or update the local branch.

Existing snapshots, Projects, Workspaces, and branch-created worktrees require
no migration. Existing APIs keep their behavior unless they are explicitly
used by the new Pull Request path.

## Documentation and architecture records

Implementation must update the durable repository documentation in the same
change:

- Promote implemented behavior into `docs/SPEC.md` under Projects and
  Workspaces, Git worktrees, and the conditional GitHub CLI boundary.
- Update `CONTEXT.md` to state that explicit Pull Request intake in Code Work
  Mode may create a Worktree Workspace and is separate from opening a Pull
  Request in Review Work Mode.
- Add ADR 0005 recording the decision to use the active GitHub CLI context,
  provider-qualified Repository Identity, Project-remote validation, and GitHub
  Pull Request refs for fork checkout without credential ownership.
- Add `gh` as an optional runtime requirement in `README.md` and document
  `brew install gh`, `gh auth login`, and `gh repo set-default` troubleshooting
  in `docs/DEVELOPMENT.md`.
- Keep this proposal linked from `docs/proposals/README.md`, moving it from
  current proposals to completed proposals when the stable contract is
  promoted.

Do not update `CHANGELOG.md` until the feature is being pushed, as required by
the repository's push workflow.

## Implementation sequence

### 1. Provider domain and command boundary

- Add Repository Identity, Pull Request input parsing, metadata, and typed
  errors.
- Implement the injectable bounded command runner and GitHubPullRequestService.
- Cover parsing, executable discovery, exact arguments and environment, JSON
  decoding, timeout, cancellation, and provider failures before connecting UI.

### 2. Git remote and Pull Request head preparation

- Add fetch-remote URL normalization and Repository Identity matching.
- Implement Pull Request head fetch, commit resolution, branch validation,
  collision behavior, optional upstream setup, and worktree reuse/creation.
- Add local Git integration fixtures, including synthetic
  `refs/pull/<number>/head` refs in bare remotes.

### 3. Workspace orchestration

- Inject the provider service into WorkspaceManager.
- Add the throwing Pull Request creation API, stale-Project revalidation,
  Workspace reuse, PR-title assignment, rollback, selection, and checkpoint.
- Verify that no new snapshot fields or migration are introduced.

### 4. Sheet integration

- Replace the two-way source toggle with the three-way text picker.
- Add Pull Request input, visibility rules, validation, single-step creation,
  progress, and typed error presentation.
- Preserve all New Branch and Existing Branch interactions and source-contract
  protections.

### 5. Documentation and full validation

- Update the spec, context, ADR, setup documentation, and proposal index.
- Regenerate `Argus.xcodeproj` through `./scripts/build.sh generate` after adding
  source and test files; do not edit the project file manually.
- Run focused provider, Worktree, Workspace, session, and UI contract tests.
- Run the complete `./scripts/test.sh` suite and inspect the final worktree for
  unintended generated or unrelated changes.

## Test plan

### Input and Repository Identity

- Positive Pull Request number parses successfully.
- Zero, negative-looking input, decimals, whitespace-only input, and arbitrary
  branch text fail.
- Canonical GitHub and GitHub Enterprise HTTPS URLs parse.
- URL query, fragment, and `/files` suffix preserve the same identity.
- HTTP, embedded credentials, incomplete paths, and non-Pull Request URLs fail.
- HTTPS, `ssh://`, and SCP-style Git URLs normalize to the same identity.
- Host, owner, repository casing and `.git` suffixes do not create false
  mismatches.
- Push-only URLs do not make a Project eligible.

### GitHub CLI boundary

- The service finds `gh` through an injected PATH and both Homebrew defaults.
- A missing executable produces the installation error without starting a
  process.
- Number and URL inputs produce exact argument arrays and use the Project
  Repository Root as the working directory.
- Prompts, paging, color, and terminal Git authentication are disabled.
- Valid JSON decodes all required metadata, including fork heads.
- Missing fields, malformed JSON, oversized output, nonzero exit, timeout, and
  cancellation produce their typed failures.
- Unauthenticated and ambiguous-default errors provide the required commands.
- Tests confirm that no token-exporting command is invoked and no secret is
  included in diagnostics.

### Worktree behavior

- A same-repository PR creates the requested local branch at the exact PR head
  and a Managed Worktree under the Project ID.
- A fork PR succeeds from the base remote's Pull Request ref when the fork has
  no configured remote.
- A configured matching head remote supplies an upstream only when it points to
  the fetched PR head.
- A missing head remote does not add a remote and leaves the branch without an
  upstream.
- Branches containing slashes retain their Git branch name while using the
  existing safe Managed Worktree slug.
- An exact existing local branch is reused.
- An exact existing worktree path is reused without modifying dirty files.
- An existing same-name branch at another commit fails without changing its
  ref or worktree.
- Fetch or worktree failure rolls back only a branch created by the current
  attempt.
- A URL for a repository not represented by the selected Project fails before
  branch or worktree creation.

### Workspace behavior

- A new Workspace uses the PR title as custom display title and the head branch
  as its branch and derived title.
- The new Workspace belongs to the initiating Project, is selected, begins with
  one Terminal Panel, and checkpoints the Session Snapshot.
- An exact existing Workspace is selected rather than duplicated.
- Reuse preserves an existing custom title and applies the PR title only when
  no custom title exists.
- A Project removed or changed during asynchronous work receives no Workspace.
- Catch-all Project intake and the Workspace-count limit fail without provider
  or Git mutations.
- Saving and restoring retains the ordinary Worktree Workspace state without
  Pull Request metadata or a provider refresh.

### User interface contracts

- The sheet exposes exactly New Branch, Existing Branch, and Pull Request as
  text source choices.
- Pull Request mode shows URL or number input and hides Workspace Name and both
  branch controls.
- Existing source modes retain their current fields and behavior.
- Empty input disables Create; valid non-empty input uses the default action.
- Creation disables duplicate input and shows stable progress without changing
  sheet geometry.
- Success dismisses the sheet; every failure retains mode and input and exposes
  retry.
- The sheet remains free of SF Symbol image creation.
- Native labels, keyboard behavior, disabled state, and error text remain
  accessible in light and dark appearances.

### Validation commands

Run focused tests during implementation, then finish with:

```sh
./scripts/lint.sh
./scripts/test.sh
git diff --check
git status --short
```

If the Kilo or Pi JavaScript harnesses alone fail under Xcode because its
sanitized PATH cannot find Node, rerun validation with an explicit Node path
before treating that environment failure as a product regression.

## Acceptance criteria

The feature is complete when all of the following are true:

1. From any Named Project, a user can select Pull Request, enter a matching URL
   or unambiguous number, press Create once, and receive a selected Worktree
   Workspace named with the Pull Request title on its head branch.
2. Same-repository and unconfigured-fork Pull Requests both check out the exact
   provider head without Argus storing credentials or adding remotes.
3. A wrong-Project URL, missing or unauthenticated `gh`, ambiguous bare number,
   inaccessible PR, or conflicting local branch leaves existing Workspace,
   branch, worktree, and Project state intact and shows an actionable error.
4. Exact existing branches, worktrees, and Workspaces are reused without
   destructive updates or duplicate Workspace state.
5. Existing New Branch, Existing Branch, Standalone Workspace, worktree
   deletion, and Session Snapshot behavior continue to pass their regressions.
6. The stable spec, canonical context, architecture record, setup documentation,
   generated Xcode project, focused tests, and complete repository validation
   are updated together with the implementation.
