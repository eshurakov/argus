# ADR 0009: Host-batched Pull Request Status and quota-aware refresh

- Status: Accepted
- Date: 2026-08-30
- Supersedes: the provider-request scheduling strategy of [ADR 0008](0008-read-only-worktree-pull-request-status.md), retaining its read-only, credential, and Workspace ownership guarantees.

## Context

Per-Workspace status queries scale with the number of Worktrees and share the
user's GitHub API allowance with other tools. Bounding concurrent requests alone
does not bound hourly consumption. GitHub GraphQL can return multiple Pull
Requests across repositories on one host, along with the query's cost and the
remaining quota/reset time.

## Decision

Separate conservative branch/candidate discovery from detailed status reads.
Group ready Pull Request identities by GitHub host and read them through bounded
`gh api graphql` batches. Deduplicate provider identities without combining the
Workspace contexts that own their results. Preserve individual context validation
and partial-error handling; one removed Workspace or inaccessible Pull Request
must not invalidate unrelated batch members.

Use quota information from the response to pause status traffic on that host
before exhausting the remaining allowance, and honor provider retry/reset
instructions. Retain that pause across foreground and feature-toggle transitions
for its lifetime. Do not poll a separate quota endpoint periodically or persist
credentials, provider associations, or quota state in the Session Snapshot.

Reduce automatic polling frequency and retain explicit manual refresh. Manual
refresh bypasses ordinary scheduling/cache delays, not a host quota pause.
Freshness presentation must account for the slower background interval. Exact
intervals, batch bounds, and reserve policy belong in `docs/SPEC.md`.

## Consequences

- Fewer GitHub requests and CLI process launches are needed for multi-Workspace
  refreshes; query complexity still determines GraphQL point cost.
- The runtime owns shared batches and host quota deadlines while keeping local
  discovery, Workspace validation, and provider I/O separate from views.
- Discovery or large target sets can still require multiple requests; batching
  is not a guarantee of a single request for every refresh scenario.
- Cached results remain inspectable during a quota pause, with a clear reason
  and no indefinite spinner. Local Git Status and terminal work remain available.
- No new dependency, provider mutation, Git fetch, Review Work Mode, or durable
  provider state is introduced.

## References

- `docs/SPEC.md`
- `docs/proposals/worktree-pull-request-status/spec.md`
- `Argus/Services/WorkspacePullRequestStatusModel.swift`
- [GitHub CLI API command](https://cli.github.com/manual/gh_api)
- [GitHub GraphQL rate limits](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api)
