import Foundation

@MainActor
final class PullRequestStatusHostBudgetStore {
    static let shared = PullRequestStatusHostBudgetStore()

    struct Budget {
        var quota: PullRequestStatusQuota?
        var pause: PullRequestStatusError?
        var secondaryFailures = 0
        var authenticationFailures = 0
        var authenticationRetryAt: Date?
    }

    var hosts: [String: Budget] = [:]
    var repositories: [String: RepositoryIdentity] = [:]
    var unresolved = Budget()
}

extension WorkspacePullRequestStatusModel {
    func knownHost(_ project: ProjectRuntime) -> String? {
        (project.repository ?? hostBudgets.repositories[project.repositoryPath])?.host
    }

    func hostPause(_ project: ProjectRuntime) -> PullRequestStatusError? {
        if let host = knownHost(project) {
            return activePause(hostBudgets.hosts[host]?.pause)
        }
        return
            (hostBudgets.hosts.values.compactMap { activePause($0.pause) }
            + [activePause(hostBudgets.unresolved.pause)].compactMap { $0 })
            .max { ($0.pauseDeadline ?? .distantPast) < ($1.pauseDeadline ?? .distantPast) }
    }

    func activePause(_ error: PullRequestStatusError?) -> PullRequestStatusError? {
        guard let error, let deadline = error.pauseDeadline, deadline > now() else { return nil }
        return error
    }

    func recordQuota(_ batch: PullRequestStatusBatch, host: String) {
        var budget = hostBudgets.hosts[host] ?? PullRequestStatusHostBudgetStore.Budget()
        budget.quota = batch.quota
        if activePause(budget.pause) == nil { budget.secondaryFailures = 0 }
        hostBudgets.hosts[host] = budget
        let buffer = max(100, batch.quota.cost + 1)
        if batch.quota.remaining <= buffer, batch.quota.resetAt > now() {
            setHostPause(.quotaPaused(until: batch.quota.resetAt), host: host)
        }
        if let retryAfter = batch.retryAfter, retryAfter > now() {
            setHostPause(.rateLimited(retryAfter: retryAfter), host: host)
        }
        publishHostPauses()
    }

    func recordHostFailure(_ error: PullRequestStatusError, host: String?) {
        switch error {
        case .rateLimited, .secondaryRateLimited, .quotaPaused:
            var budget =
                host.map { hostBudgets.hosts[$0] ?? PullRequestStatusHostBudgetStore.Budget() }
                ?? hostBudgets.unresolved
            let deadline: Date
            if case .secondaryRateLimited = error {
                budget.secondaryFailures = min(budget.secondaryFailures + 1, 7)
                let backoff = min(3_600, 60 * pow(2, Double(budget.secondaryFailures - 1)))
                deadline = error.pauseDeadline.flatMap { $0 > now() ? $0 : nil } ?? now().addingTimeInterval(backoff)
            } else {
                deadline = error.pauseDeadline.flatMap { $0 > now() ? $0 : nil } ?? now().addingTimeInterval(3_600)
            }
            if let host {
                hostBudgets.hosts[host] = budget
            } else {
                hostBudgets.unresolved = budget
            }
            let pause: PullRequestStatusError
            switch error {
            case .quotaPaused: pause = .quotaPaused(until: deadline)
            case .secondaryRateLimited: pause = .secondaryRateLimited(retryAfter: deadline)
            default: pause = .rateLimited(retryAfter: deadline)
            }
            setHostPause(pause, host: host)
            publishHostPauses()
        case .unauthenticated:
            guard let host else { return }
            var budget = hostBudgets.hosts[host] ?? PullRequestStatusHostBudgetStore.Budget()
            if budget.authenticationRetryAt.map({ $0 > now() }) != true {
                budget.authenticationFailures = min(budget.authenticationFailures + 1, 3)
                budget.authenticationRetryAt = now().addingTimeInterval(
                    [30, 60, 120][budget.authenticationFailures - 1])
            }
            hostBudgets.hosts[host] = budget
        default:
            break
        }
    }

    func recordHostSuccess(host: String, manual: Bool) {
        guard var budget = hostBudgets.hosts[host],
            manual || budget.authenticationRetryAt.map({ $0 <= now() }) == true
        else { return }
        budget.authenticationRetryAt = nil
        budget.authenticationFailures = 0
        hostBudgets.hosts[host] = budget
    }

    private func setHostPause(_ pause: PullRequestStatusError, host: String?) {
        if let host {
            var budget = hostBudgets.hosts[host] ?? PullRequestStatusHostBudgetStore.Budget()
            if (pause.pauseDeadline ?? .distantPast) >= (budget.pause?.pauseDeadline ?? .distantPast) {
                budget.pause = pause
            }
            hostBudgets.hosts[host] = budget
        } else if (pause.pauseDeadline ?? .distantPast)
            >= (hostBudgets.unresolved.pause?.pauseDeadline ?? .distantPast)
        {
            hostBudgets.unresolved.pause = pause
        }
    }

    func publishHostPauses() {
        for (id, entry) in entries {
            guard let project = projects[entry.target.projectID], let pause = hostPause(project) else { continue }
            var state = states[id] ?? WorkspacePullRequestState()
            state.isRefreshing = false
            state.error = pause
            state.hasLoaded = true
            publish(state, for: id)
        }
    }
}
