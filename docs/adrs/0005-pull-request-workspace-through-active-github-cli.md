# ADR 0005: Create Pull Request Workspaces through the active GitHub CLI

- Status: Accepted
- Date: 2026-08-08

## Context

Code Work Mode needs a small, explicit path from a GitHub Pull Request to a
local Worktree Workspace. Argus is a personal single-user application, so it
already has a local Git checkout and an active GitHub CLI authentication
context. Owning a second credential store would add secrets, lifecycle, and
failure modes that the feature does not need.

Pull Request URLs also cannot be matched safely by local display names or paths
alone. Fork Pull Requests need their exact head commit without requiring a
new remote, while an existing local branch must never be reset implicitly.

## Decision

Argus resolves Pull Request metadata by invoking the user's active `gh` CLI
with bounded, noninteractive arguments. Argus never requests, reads, stores, or
logs GitHub credentials. The command runs in the selected Named Project's
Project Repository Root, so bare Pull Request numbers use the normal `gh`
repository-selection rules.

The transient `RepositoryIdentity` is provider-qualified and normalizes the
GitHub host, owner, and repository name. Pull Request intake accepts a URL only
when its base Repository Identity matches a fetch URL of the initiating Named
Project. Fetch remote selection prefers `origin`, then lexical remote order;
push-only URLs do not qualify.

Worktree preparation fetches the base repository's
`refs/pull/<number>/head`, resolves `FETCH_HEAD^{commit}`, and treats that
commit as authoritative for the attempt. It creates the requested local head
branch only when it is absent, refuses a same-name branch at another commit,
and may set an upstream only after a configured head remote points at the
fetched commit. An unconfigured fork is therefore checked out without adding a
remote.

Pull Request metadata remains transient. The resulting Workspace is an
ordinary Worktree Workspace and uses existing Managed Worktree storage,
Workspace reuse, selection, and Session Snapshot behavior.

## Consequences

- The feature follows the user's existing `gh` login and supports GitHub
  Enterprise hosts without storing provider secrets.
- Bare-number intake remains faithful to `gh repo set-default` and does not
  silently prefer a local remote.
- Fork heads can be checked out exactly, but an unconfigured fork branch has no
  upstream until the user configures one independently.
- Fetching a Pull Request can update `FETCH_HEAD` and remote-tracking state,
  while local branch refs and dirty reused Worktrees remain protected by the
  collision and reuse checks.
- The Worktree Workspace does not remember its Pull Request number, URL, title
  history, or provider association and does not refresh automatically.

## References

- `docs/SPEC.md`
- `CONTEXT.md`
- `docs/proposals/pull-request-workspace/spec.md`
- `Argus/Services/GitHubPullRequestService.swift`
- `Argus/Services/WorktreeService+PullRequest.swift`
