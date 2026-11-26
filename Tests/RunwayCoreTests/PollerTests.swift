import Foundation
import Testing
@testable import RunwayCore

/// Returns scripted results in order, then repeats the last one.
actor ScriptedClient: UsageFetching {
    private var results: [Result<UsageResponse, UsageFetchError>]
    private(set) var calls = 0

    init(_ results: [Result<UsageResponse, UsageFetchError>]) { self.results = results }

    func fetchUsage(accessToken: String) async throws -> UsageResponse {
        calls += 1
        let r = results.count > 1 ? results.removeFirst() : results[0]
        return try r.get()
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ d: Date) { value = d }
    var now: Date { lock.withLock { value } }
    func advance(_ s: TimeInterval) { lock.withLock { value = value.addingTimeInterval(s) } }
}

func response(session: Double, weekly: Double = 10) -> UsageResponse {
    UsageResponse(limits: [
        RawLimit(kind: "session", percent: session, resetsAt: "2026-11-26T16:10:00Z"),
        RawLimit(kind: "weekly_all", percent: weekly, resetsAt: "2026-11-30T15:00:00Z"),
    ])
}

let validCreds = ClaudeCredentials(accessToken: "tok", expiresAt: iso("2026-11-27T00:00:00Z"),
                                   subscriptionType: "team", rateLimitTier: "default_claude_max_5x")

@Suite struct PollScheduleTests {
    let t0 = iso("2026-11-26T12:00:00Z")

    @Test func adaptiveInterval() {
        var s = PollSchedule()
        #expect(s.nextInterval(now: t0) == 300)
        s.recordSuccess(changed: true, now: t0)
        #expect(s.nextInterval(now: t0.addingTimeInterval(60)) == 180)
        #expect(s.nextInterval(now: t0.addingTimeInterval(599)) == 180)
        #expect(s.nextInterval(now: t0.addingTimeInterval(601)) == 300)
        s.recordSuccess(changed: false, now: t0.addingTimeInterval(700))
        #expect(s.nextInterval(now: t0.addingTimeInterval(700)) == 300)
    }

    @Test func exponentialBackoffCappedAt15Min() {
        var s = PollSchedule()
        var intervals: [TimeInterval] = []
        for _ in 0..<6 {
            s.recordThrottle()
            intervals.append(s.nextInterval(now: t0))
        }
        #expect(intervals == [180, 360, 720, 900, 900, 900])
        s.recordSuccess(changed: false, now: t0)
        #expect(s.nextInterval(now: t0) == 300)
    }
}

@MainActor
@Suite struct UsageStoreTests {
    func makeStore(_ results: [Result<UsageResponse, UsageFetchError>],
                   creds: Result<ClaudeCredentials, CredentialsError> = .success(validCreds),
                   clock: Clock = Clock(iso("2026-11-26T12:00:00Z")),
                   sink: RecordingSink? = nil,
                   persistence: MemoryStore = MemoryStore(),
                   accounts: any AccountProvider = StaticAccountProvider(nil)) -> (UsageStore, ScriptedClient) {
        let client = ScriptedClient(results)
        let notifier = sink.map { ThresholdNotifier(ledger: InMemoryLedger(), sink: $0) }
        let store = UsageStore(credentials: StaticCredentialsProvider(creds), client: client, accounts: accounts,
                               persistence: persistence, notifier: notifier, now: { clock.now })
        return (store, client)
    }

    func account(_ id: String, _ kind: AccountKind = .team) -> ClaudeAccount {
        ClaudeAccount(email: "\(id)@x.com", kind: kind, id: id)
    }

    @Test func successThenAdaptiveInterval() async {
        let clock = Clock(iso("2026-11-26T12:00:00Z"))
        let (store, _) = makeStore([.success(response(session: 10)), .success(response(session: 12)),
                                    .success(response(session: 12))], clock: clock)
        #expect(await store.pollOnce() == 300) // first snapshot is not a "change"
        #expect(store.state == .ok)
        #expect(store.plan == "Max 5x")
        #expect(store.snapshot?.session?.percent == 10)
        clock.advance(300)
        #expect(await store.pollOnce() == 180) // moved
        clock.advance(180)
        #expect(await store.pollOnce() == 180) // still within 10 min of the last change
        clock.advance(600)
        #expect(await store.pollOnce() == 300)
    }

    @Test func unauthorizedMeansExpiredAndNotifiesOnce() async {
        let sink = RecordingSink()
        let clock = Clock(iso("2026-11-26T12:00:00Z"))
        let (store, _) = makeStore([.failure(.unauthorized)], clock: clock, sink: sink)
        #expect(await store.pollOnce() == PollSchedule.idleInterval)
        clock.advance(120)
        await store.pollOnce()
        #expect(store.state == .expired)
        #expect(sink.delivered.map(\.title) == ["Claude Code connection expired"])
    }

    @Test func locallyExpiredTokenSkipsTheNetwork() async {
        let expired = ClaudeCredentials(accessToken: "tok", expiresAt: iso("2026-11-26T11:00:00Z"),
                                        subscriptionType: nil, rateLimitTier: nil)
        let (store, client) = makeStore([.success(response(session: 1))], creds: .success(expired))
        await store.pollOnce()
        #expect(store.state == .expired)
        #expect(await client.calls == 0)
    }

    @Test func missingClaudeCode() async {
        let (store, client) = makeStore([.success(response(session: 1))], creds: .failure(.notFound))
        await store.pollOnce()
        #expect(store.state == .claudeCodeMissing)
        #expect(await client.calls == 0)
    }

    @Test func unreadableKeychainIsNotClaudeCodeMissing() async {
        let persistence = MemoryStore()
        SnapshotCache(store: persistence).save(UsageSnapshot(session: nil, weekly: nil, fetchedAt: iso("2026-11-26T11:00:00Z")),
                                               accountID: nil)
        let (store, _) = makeStore([.success(response(session: 1))], creds: .failure(.unreadable(status: 36)),
                                   persistence: persistence)
        store.start()
        try? await Task.sleep(for: .milliseconds(50))
        store.stop()
        #expect(store.state == .offline(.keychain))
        #expect(store.snapshot != nil) // the last values stay
    }

    @Test func offlineKeepsLastValues() async {
        let clock = Clock(iso("2026-11-26T12:00:00Z"))
        let (store, _) = makeStore([.success(response(session: 33)), .failure(.network("down"))], clock: clock)
        await store.pollOnce()
        clock.advance(300)
        #expect(await store.pollOnce() == PollSchedule.fastInterval)
        #expect(store.state == .offline(.network))
        #expect(store.snapshot?.session?.percent == 33)
    }

    @Test func emptyPayloadIsAnErrorNotZero() async {
        let clock = Clock(iso("2026-11-26T12:00:00Z"))
        let (store, _) = makeStore([.success(response(session: 33)), .success(UsageResponse(limits: []))], clock: clock)
        await store.pollOnce()
        clock.advance(300)
        await store.pollOnce()
        #expect(store.state == .offline(.decoding))
        #expect(store.snapshot?.session?.percent == 33)
    }

    @Test func retryAfterBlocksEvenTheButtonAndSurvivesARelaunch() async {
        let clock = Clock(iso("2026-11-26T12:00:00Z"))
        let persistence = MemoryStore()
        let (store, client) = makeStore([.failure(.rateLimited(retryAfter: 3566)), .success(response(session: 5))],
                                        clock: clock, persistence: persistence)
        #expect(await store.pollOnce() == 3566)
        #expect(store.throttledUntil == iso("2026-11-26T12:00:00Z").addingTimeInterval(3566))
        clock.advance(600)
        store.refresh(.manual)
        try? await Task.sleep(for: .milliseconds(50))
        store.stop()
        #expect(await client.calls == 1)
        #expect(store.isRefreshing == false)

        let (relaunched, client2) = makeStore([.success(response(session: 5))], clock: clock, persistence: persistence)
        relaunched.start()
        try? await Task.sleep(for: .milliseconds(50))
        relaunched.stop()
        #expect(await client2.calls == 0)
        #expect(relaunched.throttledUntil == iso("2026-11-26T12:00:00Z").addingTimeInterval(3566))
    }

    @Test func relaunchShowsTheCacheWithoutCallingRightAway() async {
        let clock = Clock(iso("2026-11-26T12:00:00Z"))
        let persistence = MemoryStore()
        let (first, _) = makeStore([.success(response(session: 42))], clock: clock, persistence: persistence)
        await first.pollOnce()
        clock.advance(20)
        let (store, client) = makeStore([.success(response(session: 5))], clock: clock, persistence: persistence)
        store.start()
        try? await Task.sleep(for: .milliseconds(50))
        store.stop()
        #expect(await client.calls == 0) // inside the 60 s gap
        #expect(store.state == .ok)
        #expect(store.snapshot?.session?.percent == 42)
    }

    @Test func manualRefreshInsideTheGapIsQueuedNotDropped() async {
        let clock = Clock(iso("2026-11-26T12:00:00Z"))
        let (store, client) = makeStore([.success(response(session: 1))], clock: clock)
        await store.pollOnce()
        clock.advance(59.9)
        store.refresh(.manual) // queued for 0.1 s from now
        try? await Task.sleep(for: .milliseconds(50))
        clock.advance(1)
        try? await Task.sleep(for: .milliseconds(300))
        store.stop()
        #expect(await client.calls == 2)
    }

    @Test func accountSwitchDropsTheOldValuesAndReadsTheNewAccountAtOnce() async {
        let clock = Clock(iso("2026-11-26T12:00:00Z"))
        let accounts = SwitchableAccounts(account("team"))
        let persistence = MemoryStore()
        let (store, client) = makeStore([.success(response(session: 100)), .success(response(session: 3))],
                                        clock: clock, persistence: persistence, accounts: accounts)
        await store.pollOnce()
        clock.advance(10) // well inside the 60 s gap of the team account
        accounts.current = account("perso", .personal)
        store.refresh(.manual)
        try? await Task.sleep(for: .milliseconds(100))
        store.stop()
        #expect(await client.calls == 2)
        #expect(store.snapshot?.session?.percent == 3)
        #expect(store.account?.kind == .personal)
        #expect(SnapshotCache(store: persistence).load()?.accountID == "perso")
    }

    @Test func eachAccountKeepsItsOwnRetryWindow() async {
        let clock = Clock(iso("2026-11-26T12:00:00Z"))
        let accounts = SwitchableAccounts(account("team"))
        let (store, client) = makeStore([.failure(.rateLimited(retryAfter: 3600)), .success(response(session: 3))],
                                        clock: clock, accounts: accounts)
        await store.pollOnce()
        accounts.current = account("perso", .personal)
        clock.advance(120)
        await store.pollOnce()
        #expect(store.state == .ok) // the new account is not under the team's 429
        accounts.current = account("team")
        clock.advance(600)
        await store.pollOnce()
        #expect(await client.calls == 2) // back on team: its window still runs
        #expect(store.throttledUntil == iso("2026-11-26T13:00:00Z"))
    }

    @Test func relaunchOnAnotherAccountDropsTheCache() async {
        let clock = Clock(iso("2026-11-26T12:00:00Z"))
        let persistence = MemoryStore()
        SnapshotCache(store: persistence).save(UsageSnapshot(session: UsageLimit(kind: .session, percent: 42, resetsAt: nil),
                                                             weekly: nil, fetchedAt: iso("2026-11-26T11:00:00Z")),
                                               accountID: "team")
        CallGate(store: persistence).recordRetryAfter(1800, account: "team", now: clock.now)
        let (store, client) = makeStore([.success(response(session: 5))], clock: clock, persistence: persistence,
                                        accounts: StaticAccountProvider(account("perso", .personal)))
        store.start()
        try? await Task.sleep(for: .milliseconds(100))
        store.stop()
        #expect(await client.calls == 1)
        #expect(store.snapshot?.session?.percent == 5)
        #expect(store.throttledUntil == nil)
    }

    @Test func scenariosSitOverLiveDataAndLeaveWithoutACall() async {
        let clock = Clock(iso("2026-11-26T12:00:00Z"))
        let (store, client) = makeStore([.success(response(session: 21))], clock: clock)
        await store.pollOnce()
        store.simulate(Presentation(state: .offline(.network), snapshot: nil, plan: "Pro"))
        #expect(store.state == .offline(.network))
        #expect(store.plan == "Pro")
        store.resumeLive()
        #expect(store.state == .ok)
        #expect(store.snapshot?.session?.percent == 21)
        #expect(await client.calls == 1)
    }

    @Test func backoffOn429And5xxThenRecovery() async {
        let clock = Clock(iso("2026-11-26T12:00:00Z"))
        let (store, _) = makeStore([.failure(.rateLimited(retryAfter: nil)), .failure(.server(status: 503)),
                                    .failure(.server(status: 502)), .success(response(session: 5))], clock: clock)
        #expect(await store.pollOnce() == 180)
        #expect(store.state == .offline(.rateLimited(until: nil)))
        clock.advance(180)
        #expect(await store.pollOnce() == 360)
        clock.advance(360)
        #expect(await store.pollOnce() == 720)
        clock.advance(720)
        #expect(await store.pollOnce() == 300)
        #expect(store.state == .ok)
    }

    @Test func firstPollDoesNotBurstNotifications() async {
        let sink = RecordingSink()
        let clock = Clock(iso("2026-11-26T12:00:00Z"))
        let (store, _) = makeStore([.success(response(session: 90, weekly: 85)), .success(response(session: 96, weekly: 85))],
                                   clock: clock, sink: sink)
        await store.pollOnce()
        #expect(sink.delivered.isEmpty)
        clock.advance(300)
        await store.pollOnce()
        #expect(sink.delivered.map(\.title) == ["Session at 95%"])
    }
}

final class SwitchableAccounts: AccountProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ClaudeAccount?
    init(_ account: ClaudeAccount?) { value = account }
    var current: ClaudeAccount? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func loadAccount(subscriptionType: String?) async -> ClaudeAccount? { current }
}

@Suite struct CallGateTests {
    let t0 = iso("2026-11-26T12:00:00Z")

    @Test func minGapBetweenCalls() {
        let gate = CallGate(store: MemoryStore())
        #expect(gate.delay(account: "a", now: t0) == 0)
        gate.recordCall(account: "a", now: t0)
        #expect(gate.delay(account: "a", now: t0.addingTimeInterval(20)) == 40)
        #expect(gate.delay(account: "a", now: t0.addingTimeInterval(60)) == 0)
    }

    @Test func atMostTwentyAnHourPerAccountSharedThroughTheStore() {
        let store = MemoryStore()
        let gate = CallGate(store: store)
        for i in 0..<20 { gate.recordCall(account: "a", now: t0.addingTimeInterval(Double(i) * 120)) } // last at +38 min
        // Full: wait until the first call (t0) leaves the rolling hour.
        #expect(gate.delay(account: "a", now: t0.addingTimeInterval(45 * 60)) == 15 * 60)
        #expect(gate.delay(account: "a", now: t0.addingTimeInterval(3600)) == 0)
        // A relaunch or a second instance on the same store sees the same calls; another account does not.
        #expect(CallGate(store: store).delay(account: "a", now: t0.addingTimeInterval(45 * 60)) == 15 * 60)
        #expect(gate.delay(account: "b", now: t0.addingTimeInterval(45 * 60)) == 0)
    }

    @Test func retryAfterIsHonoredInFullButCapped() {
        let gate = CallGate(store: MemoryStore())
        gate.recordRetryAfter(3566, account: "a", now: t0)
        #expect(gate.delay(account: "a", now: t0) == 3566)
        gate.recordRetryAfter(.infinity, account: "a", now: t0) // ignored
        #expect(gate.delay(account: "a", now: t0) == 3566)
        gate.recordRetryAfter(30 * 86400, account: "a", now: t0)
        #expect(gate.delay(account: "a", now: t0) == CallGate.maxRetryAfter)
        gate.clearRetry(account: "a", now: t0)
        #expect(gate.retryAt(account: "a", now: t0) == nil)
    }

    @Test func clockSetBackDoesNotBlock() {
        let gate = CallGate(store: MemoryStore())
        gate.recordCall(account: "a", now: t0)
        gate.recordRetryAfter(3600, account: "a", now: t0)
        // The clock jumps back a day: the "future" call and a window ending 25 h from now are dropped.
        #expect(gate.delay(account: "a", now: t0.addingTimeInterval(-86400)) == 0)
    }

    @Test func retryAfterAcceptsSecondsOrAnHTTPDate() {
        #expect(HTTPUsageClient.retryAfter("3566") == 3566)
        #expect(HTTPUsageClient.retryAfter("Wed, 26 Nov 2026 13:00:00 GMT", now: t0) == 3600)
        #expect(HTTPUsageClient.retryAfter("inf") == nil)
        #expect(HTTPUsageClient.retryAfter("soon") == nil)
    }
}
