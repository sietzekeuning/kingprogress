import Foundation
import Observation

/// Watches GitHub for workflow runs and keeps the list of cards. One
/// instance, owned by the app delegate; the views observe `actions`.
@MainActor
@Observable
final class RunMonitor {
    // How long a finished run keeps its card on screen before it slides away.
    static let completedLinger: TimeInterval = 20
    // How long a dismissed run stays dismissed. New runs get a new key, so
    // they always come back on their own.
    private static let dismissedMemory: TimeInterval = 6 * 60 * 60
    private static let expectedDurationCache: TimeInterval = 30 * 60 // re-measure a workflow's usual runtime twice an hour
    private static let expectedDurationSamples = 3 // take the last 3 successful runs as the yardstick
    // Idle repos cost nothing (conditional requests come back 304, which
    // GitHub does not charge), so the interval only has to respect the runs
    // we are actively following.
    private static let pollIdle: TimeInterval = 15
    private static let pollActive: TimeInterval = 8
    private static let runsPerRepo = 5
    private static let repoListCache: TimeInterval = 10 * 60

    let settings: AppSettings
    let verbose = ProcessInfo.processInfo.environment["KINGPROGRESS_VERBOSE"] == "1"

    /// The cards, newest first.
    private(set) var actions: [TrackedRun] = []
    private(set) var isSignedIn = false

    /// Fires after every change to `actions`, for the popup window.
    var onActionsChanged: (() -> Void)?
    /// The stored token turned out to be revoked.
    var onTokenRevoked: (() -> Void)?
    /// A device-flow sign-in finished in the background.
    var onDeviceLogin: ((Result<Account, Error>) -> Void)?

    private var client: GitHubClient?
    private var running: [String: TrackedRun] = [:]
    private var dismissed: [String: Date] = [:]
    private var expectedDurations: [String: (value: TimeInterval?, fetchedAt: Date)] = [:]
    private var runsCache: [String: (etag: String?, runs: [WorkflowRun])] = [:]
    private var repoCache: (fetchedAt: Date, repos: [RepoSummary])?
    private var pollTask: Task<Void, Never>?
    private var sweepInFlight = false
    private var lingerTimer: Timer?
    private var deviceTask: Task<Void, Never>?
    private var conditionalHits = 0
    private var isDemo = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Who is signed in. Demo and snapshot runs can pretend.
    var account: Account? {
        demoAccount ?? settings.account
    }

    var myLogin: String? {
        account?.login
    }

    private var demoAccount: Account?
    private var demoRepos: [RepoSummary]?

    // MARK: - Lifecycle

    func start() {
        guard let token = settings.token else {
            log("not signed in yet")
            return
        }

        let client = GitHubClient(token: token)
        self.client = client
        isSignedIn = true
        startMonitoring()

        // A token stored by an older build has no account attached, and we
        // need the login to make "only my runs" mean anything. It also tells
        // us early when a token has been revoked.
        Task {
            do {
                settings.setAccount(try await client.validateToken())
            } catch let error as GitHubError where error.status == 401 {
                log("the stored token is no longer valid - signing out")
                signOut()
                onTokenRevoked?()
            } catch {
                log("could not verify the stored token: \(error.localizedDescription)")
            }
        }
    }

    /// Validate a token, remember it, and start watching.
    @discardableResult
    func applyToken(_ token: String) async throws -> Account {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = GitHubClient(token: token)
        let account = try await client.validateToken()

        settings.token = token
        settings.setAccount(account)
        self.client = client
        repoCache = nil
        runsCache.removeAll()
        isSignedIn = true
        startMonitoring()

        log("signed in as \(account.login)")
        return account
    }

    func signOut() {
        // A device-login poll still in flight would sign us back in the
        // moment it resolves.
        cancelDeviceLogin()
        settings.token = nil
        settings.setAccount(nil)
        client = nil
        repoCache = nil
        runsCache.removeAll()
        running.removeAll()
        dismissed.removeAll()
        stopMonitoring()
        isSignedIn = false
        publish()
    }

    func stop() {
        stopMonitoring()
        cancelDeviceLogin()
    }

    // MARK: - Device flow

    func startDeviceLogin() async throws -> DeviceCode {
        let clientId = settings.clientId

        guard !clientId.isEmpty else {
            throw AuthError("No OAuth App client id is configured for this build.", code: "no_client_id")
        }

        cancelDeviceLogin()

        let device = try await GitHubAuth.requestDeviceCode(clientId: clientId)

        // Runs in the background; the login screen shows the code meanwhile.
        deviceTask = Task { [weak self] in
            do {
                let token = try await GitHubAuth.pollForDeviceToken(clientId: clientId, device: device)
                guard let self, !Task.isCancelled else { return }
                let account = try await self.applyToken(token)
                self.onDeviceLogin?(.success(account))
            } catch {
                guard let self, !Task.isCancelled else { return }
                if (error as? AuthError)?.code != "cancelled" {
                    self.onDeviceLogin?(.failure(error))
                }
            }
        }

        return device
    }

    func cancelDeviceLogin() {
        deviceTask?.cancel()
        deviceTask = nil
    }

    // MARK: - Cards

    func dismiss(_ key: String) {
        guard running[key] != nil || dismissed[key] != nil else {
            return
        }

        // Remember the dismissal so an action that is still running does not
        // pop straight back in on the next poll. A new run gets a new key, so
        // the next one still shows up.
        dismissed[key] = Date()
        running[key] = nil
        publish()
    }

    func dismissAll() {
        for key in running.keys {
            dismissed[key] = Date()
        }
        running.removeAll()
        publish()
    }

    /// Asks GitHub to cancel a run. The card says "cancelling" until a poll
    /// sees GitHub's verdict: GitHub takes a few seconds to wind the jobs
    /// down, so the next sweep is nudged rather than the answer awaited.
    func cancel(_ key: String) async {
        guard var action = running[key], action.state.isActive, !action.cancelling else {
            return
        }

        action.cancelling = true
        action.cancelError = nil
        running[key] = action
        publish()
        log("cancelling \(action.repo) \(action.name) (run \(action.runId))")

        if isDemo {
            try? await Task.sleep(for: .seconds(1.5))
            complete(key, conclusion: "cancelled")
            return
        }

        guard let client else {
            return
        }

        do {
            try await client.cancelRun(owner: action.owner, repo: action.repoName, runId: action.runId)
            try? await Task.sleep(for: .seconds(2))
            await sweep()
        } catch {
            log("could not cancel run \(action.runId) for \(action.repo): \(error.localizedDescription)")
            guard var failed = running[key] else { return }
            failed.cancelling = false
            failed.cancelError = error.localizedDescription
            running[key] = failed
            publish()

            // The message has done its job after a few seconds.
            try? await Task.sleep(for: .seconds(8))
            if var later = running[key], later.cancelError == failed.cancelError {
                later.cancelError = nil
                running[key] = later
                publish()
            }
        }
    }

    private func complete(_ key: String, conclusion: String) {
        guard var action = running[key] else { return }
        action.status = .completed
        action.conclusion = conclusion
        action.completedAt = Date()
        action.duration = Date().timeIntervalSince(action.startedAt)
        action.currentJob = nil
        action.currentStep = nil
        action.jobsCompleted = action.jobsTotal
        running[key] = action
        publish()
    }

    private func publish() {
        actions = running.values.sorted { $0.startedAt > $1.startedAt }
        updateLingerTimer()
        onActionsChanged?()
    }

    // Completed runs stick around for `completedLinger` so the result is
    // actually readable, then leave on their own.
    @discardableResult
    private func pruneCompleted() -> Bool {
        let now = Date()
        var changed = false

        for (key, action) in running {
            if let completedAt = action.completedAt, now.timeIntervalSince(completedAt) >= Self.completedLinger {
                running[key] = nil
                changed = true
            }
        }

        return changed
    }

    private func pruneDismissed() {
        let now = Date()
        dismissed = dismissed.filter { now.timeIntervalSince($0.value) <= Self.dismissedMemory }
    }

    /// A cheap local ticker that retires finished cards once their linger is
    /// up. Only runs while there is a finished card to retire.
    private func updateLingerTimer() {
        let needed = running.values.contains { $0.completedAt != nil }

        if needed, lingerTimer == nil {
            lingerTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.pruneCompleted() {
                        self.publish()
                    }
                }
            }
        } else if !needed, let timer = lingerTimer {
            timer.invalidate()
            lingerTimer = nil
        }
    }

    // MARK: - Settings that affect polling

    func setWatchedRepos(_ repos: [String]) {
        settings.setWatchedRepos(repos)
        runsCache.removeAll() // different repo set, different conditional requests
        Task { await sweep() }
    }

    func setActorFilter(_ filter: ActorFilter) {
        settings.setActorFilter(filter)
    }

    /// Filtering happens when a run is first picked up. A run already on
    /// screen is never yanked away because the filter changed under it.
    private func passesActorFilter(_ run: WorkflowRun) -> Bool {
        let filter = settings.actorFilter

        if filter.mode == .all {
            return true
        }

        guard let actor = run.whoTriggered else {
            return false
        }

        if filter.mode == .me {
            guard let me = myLogin else { return true }
            return actor.caseInsensitiveCompare(me) == .orderedSame
        }

        return filter.logins.contains { $0.caseInsensitiveCompare(actor) == .orderedSame }
    }

    // MARK: - Repositories

    func listRepos(force: Bool = false) async -> [RepoSummary] {
        if let demoRepos {
            return demoRepos
        }

        guard let client else {
            return []
        }

        if !force, let cache = repoCache, Date().timeIntervalSince(cache.fetchedAt) < Self.repoListCache {
            return cache.repos
        }

        do {
            let repos = try await client.listRepositories()
            repoCache = (Date(), repos)
            return repos
        } catch {
            log("error listing repositories: \(error.localizedDescription)")
            return repoCache?.repos ?? []
        }
    }

    /// The repos this poll should look at: whatever is ticked, or the recent ones.
    private func reposToScan() async -> [RepoSummary] {
        let watched = settings.watchedRepos

        if watched.isEmpty {
            return Array(await listRepos().prefix(AppSettings.autoRepoCount))
        }

        let known = Dictionary(uniqueKeysWithValues: await listRepos().map { ($0.fullName, $0) })

        return watched.map { fullName in
            if let repo = known[fullName] {
                return repo
            }
            let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
            return RepoSummary(fullName: fullName, owner: parts.first ?? "", name: parts.last ?? "", isPrivate: true, isFork: false, updatedAt: "")
        }
    }

    private func fetchRepoRuns(_ repo: RepoSummary) async -> [WorkflowRun] {
        guard let client else {
            return []
        }

        let cached = runsCache[repo.fullName]

        do {
            let response = try await client.recentRuns(owner: repo.owner, repo: repo.name, perPage: Self.runsPerRepo, etag: cached?.etag)

            guard let runs = response.value else {
                conditionalHits += 1
                return cached?.runs ?? []
            }

            runsCache[repo.fullName] = (response.etag, runs)
            return runs
        } catch let error as GitHubError where error.status == 404 {
            return [] // repo went away, or the token lost access to it
        } catch {
            log("error fetching workflows for \(repo.fullName): \(error.localizedDescription)")
            return cached?.runs ?? []
        }
    }

    // MARK: - Polling

    private func startMonitoring() {
        stopMonitoring()
        log("monitoring started")

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sweep()
                try? await Task.sleep(for: .seconds(self.nextPollDelay()))
            }
        }
    }

    private func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        lingerTimer?.invalidate()
        lingerTimer = nil
    }

    private func activeRunCount() -> Int {
        running.values.filter { $0.status != .completed }.count
    }

    /// Watching idle repos is free, but every run we are actively following
    /// costs a jobs request per sweep - so speed up when something is
    /// happening and back off again as more runs pile up.
    private func nextPollDelay() -> TimeInterval {
        let active = activeRunCount()

        if active == 0 {
            return Self.pollIdle
        }

        return min(Self.pollIdle, max(Self.pollActive, Double(active) * 4))
    }

    private func trackedRun(key: String, repo: String, run: WorkflowRun) -> TrackedRun {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)

        return TrackedRun(
            key: key,
            repo: repo,
            owner: parts.first ?? "",
            repoName: parts.last ?? "",
            runId: run.id,
            workflowId: run.workflowId,
            name: run.name ?? run.displayTitle ?? "Workflow run",
            branch: run.headBranch,
            event: run.event,
            commitMessage: run.commitSummary,
            status: RunStatus(github: run.status),
            conclusion: run.conclusion,
            actor: run.whoTriggered,
            startedAt: run.startedAt,
            completedAt: nil,
            duration: nil,
            expectedDuration: nil,
            currentJob: nil,
            currentStep: nil,
            jobsTotal: 0,
            jobsCompleted: 0,
            url: run.htmlUrl.flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(repo)/actions/runs/\(run.id)")!
        )
    }

    private func apply(_ run: WorkflowRun, to action: inout TrackedRun) {
        action.name = run.name ?? run.displayTitle ?? action.name
        action.branch = run.headBranch ?? action.branch
        action.commitMessage = run.commitSummary ?? action.commitMessage
        action.actor = run.whoTriggered ?? action.actor
        action.startedAt = run.startedAt

        let status = RunStatus(github: run.status)
        let wasCompleted = action.status == .completed
        action.status = status
        action.conclusion = run.conclusion

        if status == .completed, !wasCompleted {
            let finished = run.updatedAt.timeIntervalSince(action.startedAt)
            action.completedAt = Date()
            action.duration = finished > 0 ? finished : Date().timeIntervalSince(action.startedAt)
            action.currentJob = nil
            action.currentStep = nil

            if action.jobsTotal > 0 {
                action.jobsCompleted = action.jobsTotal
            }

            log("\(action.repo) \(action.name) finished: \(action.conclusion ?? "-")")
        }
    }

    // Typical wall-clock duration of the last few successful runs of the same
    // workflow - the yardstick the progress bar uses. The median rather than
    // the mean, because a single freak run (a cold cache, a stuck runner)
    // would otherwise drag the estimate off for the next half hour.
    private func expectedDuration(for action: TrackedRun) async -> TimeInterval? {
        guard let client, let workflowId = action.workflowId else {
            return action.expectedDuration
        }

        let cacheKey = "\(action.repo)#\(workflowId)"

        if let cached = expectedDurations[cacheKey], Date().timeIntervalSince(cached.fetchedAt) < Self.expectedDurationCache {
            return cached.value
        }

        do {
            let runs = try await client.successfulRuns(owner: action.owner, repo: action.repoName, workflowId: workflowId, count: Self.expectedDurationSamples)
            let durations = runs
                .map { $0.updatedAt.timeIntervalSince($0.startedAt) }
                .filter { $0 > 1 && $0 < 6 * 60 * 60 }

            let value = median(durations)
            expectedDurations[cacheKey] = (value, Date())

            if let value {
                log("expected duration for \(cacheKey): \(Int(value))s (from \(durations.count) run\(durations.count == 1 ? "" : "s"))")
            }

            return value
        } catch {
            log("error fetching previous runs for \(cacheKey): \(error.localizedDescription)")
            expectedDurations[cacheKey] = (nil, Date())
            return nil
        }
    }

    private func refreshJobs(_ action: inout TrackedRun) async {
        guard let client else {
            return
        }

        do {
            let jobs = try await client.jobs(owner: action.owner, repo: action.repoName, runId: action.runId)

            action.jobsTotal = jobs.count
            action.jobsCompleted = jobs.filter { $0.status == "completed" }.count

            guard let runningJob = jobs.first(where: { $0.status == "in_progress" || $0.status == "queued" }) else {
                action.currentJob = nil
                action.currentStep = nil
                return
            }

            action.currentJob = runningJob.name
            action.currentStep = runningJob.steps?.first { $0.status == "in_progress" || $0.status == "queued" }?.name
        } catch {
            log("error fetching jobs for \(action.repo): \(error.localizedDescription)")
        }
    }

    private func sweep() async {
        guard let client, !sweepInFlight else {
            return
        }

        sweepInFlight = true
        defer { sweepInFlight = false }
        conditionalHits = 0

        let repos = await reposToScan()

        // key -> run for every run we can currently see
        var seen: [String: (run: WorkflowRun, repo: String)] = [:]
        for repo in repos {
            for run in await fetchRepoRuns(repo) {
                seen["\(repo.fullName)-\(run.id)"] = (run, repo.fullName)
            }
        }

        // 1. Pick up runs that have just started.
        for (key, entry) in seen {
            if running[key] != nil || dismissed[key] != nil {
                continue
            }

            if RunStatus(github: entry.run.status) == .completed {
                continue // only announce runs we can watch from the start
            }

            if !passesActorFilter(entry.run) {
                continue
            }

            let action = trackedRun(key: key, repo: entry.repo, run: entry.run)
            running[key] = action
            log("\(action.repo) \(action.name) started (by \(action.actor ?? "unknown"))")
        }

        // 2. Refresh everything we are tracking.
        for key in Array(running.keys) {
            guard var action = running[key] else { continue }

            var run = seen[key]?.run

            if run == nil, action.status != .completed {
                // The run dropped off the recent list - ask for it directly so
                // we learn its conclusion instead of just losing the card.
                do {
                    run = try await client.run(owner: action.owner, repo: action.repoName, runId: action.runId)
                } catch {
                    log("error fetching run \(action.runId) for \(action.repo): \(error.localizedDescription)")
                }
            }

            if let run {
                apply(run, to: &action)
            }

            if action.status != .completed {
                action.expectedDuration = await expectedDuration(for: action)
                await refreshJobs(&action)
            }

            // The card may have been dismissed - or a cancel sent - while we
            // were waiting on GitHub.
            if let current = running[key] {
                action.cancelling = current.cancelling
                action.cancelError = current.cancelError
                running[key] = action
            }
        }

        pruneCompleted()
        pruneDismissed()
        publish()

        if verbose {
            log("swept \(repos.count) repo(s) (\(conditionalHits) unchanged), \(seen.count) recent run(s), tracking \(running.count)")
        }
    }

    // MARK: - Demo mode
    //
    // KINGPROGRESS_DEMO=1 fakes a couple of runs so the cards can be checked
    // without waiting for real CI.

    func startDemo(account: Account? = nil) {
        isDemo = true
        isSignedIn = true
        demoAccount = account
        demoRepos = [
            ("octocat/website", false, false), ("octocat/api", false, true), ("octocat/mobile-app", false, true),
            ("octocat/design-system", true, false), ("octocat/infra", false, true), ("octocat/docs", false, true),
            ("acme/checkout", true, false), ("acme/billing", false, true), ("acme/notifier", false, true),
        ].map { name, isPrivate, isFork in
            let parts = name.split(separator: "/").map(String.init)
            return RepoSummary(fullName: name, owner: parts[0], name: parts[1], isPrivate: isPrivate, isFork: isFork, updatedAt: "")
        }
        let now = Date()
        let me = myLogin ?? "octocat"

        func demoRun(key: String, repo: String, name: String, branch: String, actor: String = me, status: RunStatus = .inProgress, job: String? = "test-and-deploy", step: String? = "Run actions/checkout@v4", expected: TimeInterval? = 90, jobsTotal: Int = 3, jobsCompleted: Int = 1, startedAgo: TimeInterval = 0, commit: String? = nil) -> TrackedRun {
            TrackedRun(
                key: key, repo: repo, owner: String(repo.split(separator: "/")[0]), repoName: String(repo.split(separator: "/")[1]),
                runId: 1, workflowId: 1, name: name, branch: branch, event: "push", commitMessage: commit, status: status, conclusion: nil,
                actor: actor, startedAt: now.addingTimeInterval(-startedAgo), completedAt: nil, duration: nil,
                expectedDuration: expected, currentJob: job, currentStep: step, jobsTotal: jobsTotal, jobsCompleted: jobsCompleted,
                url: URL(string: "https://github.com/\(repo)/actions/runs/32376222808")!
            )
        }

        func finish(_ key: String, _ conclusion: String) {
            complete(key, conclusion: conclusion)
        }

        func at(_ seconds: Double, _ block: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { block() }
        }

        at(1) { [self] in
            running["demo-a"] = demoRun(key: "demo-a", repo: "sietzekeuning/vvw-site", name: "CI/CD", branch: "main", status: .queued, job: nil, step: nil, commit: "Fix the newsletter form on Safari")
            publish()
        }
        at(3) { [self] in
            running["demo-a"]?.status = .inProgress
            publish()
        }
        at(6) { [self] in
            running["demo-b"] = demoRun(key: "demo-b", repo: "sietzekeuning/marmaya", name: "Deploy to production", branch: "release/2026-08", actor: "octocat", job: "build-and-push-image", step: "Build and push Docker image to the registry", expected: nil, jobsTotal: 5, jobsCompleted: 2, startedAgo: 45, commit: "Bump image to PHP 8.4 and rotate the registry token")
            publish()
        }
        at(12) { finish("demo-a", "success") }
        at(16) { [self] in
            running["demo-c"] = demoRun(key: "demo-c", repo: "sietzekeuning/pos", name: "production", branch: "master", job: "deploy", step: "Run php artisan migrate --force", expected: 352, jobsTotal: 4, jobsCompleted: 3, startedAgo: 210, commit: "Add refunds to the daily sales export")
            publish()
        }
        at(18) { finish("demo-b", "failure") }
    }

    // MARK: - Helpers

    private func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[kingprogress] \(message)\n".utf8))
    }
}
