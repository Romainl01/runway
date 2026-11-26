import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
    case loading
    case ok
    /// Token expired or 401. Never refreshed by Runway: the refresh token belongs to Claude Code.
    case expired
    /// Could not refresh: last values are shown with their age.
    case offline(OfflineReason)
    case claudeCodeMissing

    public var isOffline: Bool {
        if case .offline = self { true } else { false }
    }
}

public enum OfflineReason: Equatable, Sendable {
    /// 429. `until` is the end of the server's Retry-After window when it gave one.
    case rateLimited(until: Date?)
    case server(status: Int)
    case http(status: Int)
    case network
    case decoding
    /// The keychain item exists but could not be read (locked keychain, `security` failure…).
    case keychain

    public var message: String {
        switch self {
        case .rateLimited: tr("Call limit reached")
        case .server(let status): tr("Service unavailable (\(status))")
        case .http(let status): tr("Error \(status)")
        case .network: tr("Offline")
        case .decoding: tr("Unreadable response")
        case .keychain: tr("Keychain inaccessible")
        }
    }

    init(_ error: UsageFetchError, retryAt: Date?) {
        self = switch error {
        case .rateLimited: .rateLimited(until: retryAt)
        case .server(let status): .server(status: status)
        case .http(let status): .http(status: status)
        case .decoding: .decoding
        case .network, .unauthorized: .network
        }
    }
}

public enum RefreshReason: Sendable {
    case popoverOpened
    case manual
    case wake
}

/// Everything the UI reads, live or from a cheatcode scenario.
public struct Presentation: Equatable, Sendable {
    public var state: ConnectionState
    public var snapshot: UsageSnapshot?
    public var plan: String?
    public var account: ClaudeAccount?

    public init(state: ConnectionState, snapshot: UsageSnapshot? = nil, plan: String? = nil,
                account: ClaudeAccount? = nil) {
        self.state = state
        self.snapshot = snapshot
        self.plan = plan
        self.account = account
    }
}

/// Poller + observable state for the UI. Every API call goes through the `CallGate`.
@MainActor
@Observable
public final class UsageStore {
    private var live = Presentation(state: .loading)
    /// A cheatcode scenario shown over the live data; polling goes on underneath.
    private var simulated: Presentation?
    public private(set) var isRefreshing = false

    public var state: ConnectionState { (simulated ?? live).state }
    public var snapshot: UsageSnapshot? { (simulated ?? live).snapshot }
    public var plan: String? { (simulated ?? live).plan }
    public var account: ClaudeAccount? { (simulated ?? live).account }
    public var isSimulating: Bool { simulated != nil }

    /// Popover opening does not refetch if the data is younger than this.
    public static let popoverFreshness: TimeInterval = 20

    @ObservationIgnored private let credentials: any CredentialsProvider
    @ObservationIgnored private let client: any UsageFetching
    @ObservationIgnored private let accounts: any AccountProvider
    @ObservationIgnored private let cache: SnapshotCache
    @ObservationIgnored private let gate: CallGate
    @ObservationIgnored private let notifier: ThresholdNotifier?
    @ObservationIgnored private let settings: @MainActor () -> NotifierSettings
    @ObservationIgnored public let now: @Sendable () -> Date
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var schedule = PollSchedule()
    /// The account the snapshot, backoff and gate entry belong to.
    @ObservationIgnored private var accountID: String?
    /// Thresholds already crossed at the first answer (of a launch or an account) stay silent.
    @ObservationIgnored private var hasPolledOnce = false

    public init(credentials: any CredentialsProvider,
                client: any UsageFetching,
                accounts: any AccountProvider = StaticAccountProvider(nil),
                persistence: any KeyValueStore = MemoryStore(),
                notifier: ThresholdNotifier? = nil,
                settings: @escaping @MainActor () -> NotifierSettings = { NotifierSettings() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.client = client
        self.accounts = accounts
        self.cache = SnapshotCache(store: persistence)
        self.gate = CallGate(store: persistence)
        self.notifier = notifier
        self.settings = settings
        self.now = now
    }

    /// The account key in the gate. "" while the account is unknown (no `~/.claude.json`).
    private var gateAccount: String { accountID ?? "" }

    /// End of the 429 window, while it runs.
    public var throttledUntil: Date? {
        if case .offline(.rateLimited(let until?)) = state, until > now() { until } else { nil }
    }

    // MARK: Loop

    /// Shows the cached snapshot at once, then polls. The first poll reads the account and asks the
    /// gate, so a relaunch never calls inside a 429 window or right after the previous call.
    public func start() {
        guard loopTask == nil else { return }
        if let cached = cache.load() {
            accountID = cached.accountID
            live.snapshot = cached.snapshot
        }
        restartLoop()
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Popover and wake skip the call when the data is fresh or a 429 / 5xx backoff runs; the button
    /// does not. Either way the poll re-reads the account (a switch is seen at once) and waits for
    /// the gate: a click inside the gap is queued, never dropped.
    public func refresh(_ reason: RefreshReason) {
        if simulated != nil {
            guard reason == .manual else { return }
            simulated = nil
        }
        guard !isRefreshing else { return }
        if reason != .manual {
            if gate.retryAt(account: gateAccount, now: now()) != nil || schedule.consecutiveThrottles > 0 { return }
            if reason == .popoverOpened, live.state == .ok, let last = live.snapshot?.fetchedAt,
               now().timeIntervalSince(last) < Self.popoverFreshness { return }
        }
        restartLoop()
    }

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            var delay: TimeInterval = 0
            while !Task.isCancelled {
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                    if Task.isCancelled { return }
                }
                guard let self else { return }
                delay = await self.pollOnce()
            }
        }
    }

    // MARK: Cheatcodes

    /// Shows a scenario over the live data (no notification fires for it).
    public func simulate(_ presentation: Presentation) {
        simulated = presentation
    }

    public func resumeLive() {
        simulated = nil
    }

    // MARK: One poll

    /// Runs one poll and returns the delay before the next one.
    @discardableResult
    public func pollOnce() async -> TimeInterval {
        isRefreshing = true
        defer { isRefreshing = false }

        let creds: ClaudeCredentials
        do {
            creds = try await credentials.loadCredentials()
        } catch CredentialsError.notFound {
            live.state = .claudeCodeMissing
            return PollSchedule.idleInterval
        } catch {
            live.state = .offline(.keychain)
            return PollSchedule.idleInterval
        }
        let loadedAccount = await accounts.loadAccount(subscriptionType: creds.subscriptionType)
        if Task.isCancelled { return 0 }
        adopt(accountID: loadedAccount?.id)
        live.plan = creds.planName
        live.account = loadedAccount ?? live.account

        if creds.isExpired(now: now()) {
            markExpired()
            return PollSchedule.idleInterval
        }

        let account = gateAccount
        let wait = gate.delay(account: account, now: now())
        if wait > 0 {
            if let until = gate.retryAt(account: account, now: now()) {
                live.state = .offline(.rateLimited(until: until))
            } else if !live.state.isOffline {
                live.state = live.snapshot == nil ? .loading : .ok
            }
            debugLog("call gate: next call in \(Int(wait)) s")
            return wait
        }

        gate.recordCall(account: account, now: now())
        let result: Result<UsageSnapshot, UsageFetchError>
        do {
            let snap = UsageSnapshot(response: try await client.fetchUsage(accessToken: creds.accessToken), fetchedAt: now())
            result = snap.isEmpty ? .failure(.decoding) : .success(snap)
        } catch let error as UsageFetchError {
            result = .failure(error)
        } catch {
            result = .failure(.network("\(error)"))
        }
        if Task.isCancelled { return 0 }

        switch result {
        case .success(let snap):
            schedule.recordSuccess(changed: snap.hasDifferentUsage(than: live.snapshot), now: snap.fetchedAt)
            live.snapshot = snap
            live.state = .ok
            cache.save(snap, accountID: accountID)
            gate.clearRetry(account: account, now: now())
            notifier?.process(snap, settings: settings(), isFirstPoll: !hasPolledOnce, now: snap.fetchedAt)
            hasPolledOnce = true
            return schedule.nextInterval(now: now())
        case .failure(.unauthorized):
            markExpired()
            return PollSchedule.idleInterval
        case .failure(let error):
            if case .rateLimited(let retryAfter?) = error {
                gate.recordRetryAfter(retryAfter, account: account, now: now())
            }
            if error.isThrottling { schedule.recordThrottle() }
            live.state = .offline(OfflineReason(error, retryAt: gate.retryAt(account: account, now: now())))
            let next = schedule.consecutiveThrottles > 0 ? schedule.nextInterval(now: now()) : PollSchedule.fastInterval
            return max(next, gate.delay(account: account, now: now()))
        }
    }

    /// Claude Code switched accounts (`/login`): what belonged to the previous one goes (values,
    /// backoff). Its gate entry stays under its own id, so switching back keeps its 429 window.
    private func adopt(accountID id: String?) {
        guard let id, id != accountID else { return }
        let switched = accountID != nil
        accountID = id
        guard switched else { return }
        debugLog("account switched: previous values dropped")
        live.snapshot = nil
        live.state = .loading
        schedule = PollSchedule()
        hasPolledOnce = false
    }

    private func markExpired() {
        live.state = .expired
        notifier?.connectionExpired()
    }
}
