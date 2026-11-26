import Foundation

/// The only door to the usage API. Whatever asks for a call (poll loop, popover, wake, button,
/// relaunch, a second instance), the gate says how long to wait, per account (the server limits
/// each account on its own):
/// - after a 429, the server's Retry-After window, in full: an early call earns another ~1 h;
/// - at least `minGap` between two calls and at most `maxPerHour` in any rolling hour.
/// Persisted, so relaunches share it. Times in the future (clock set back) are dropped, so a clock
/// change never blocks the app for the length of the jump.
public struct CallGate: Sendable {
    public static let minGap: TimeInterval = 60
    public static let maxPerHour = 20
    public static let window: TimeInterval = 3600
    /// Longest Retry-After believed: a garbled or huge value must not block the app for good.
    public static let maxRetryAfter: TimeInterval = 6 * 3600
    static let key = "runway.gate"

    struct Record: Codable {
        var calls: [Date] = []
        var retryAt: Date?
    }

    private let store: any KeyValueStore

    public init(store: any KeyValueStore) { self.store = store }

    /// 0 when a call may go now, else how long to wait.
    public func delay(account: String, now: Date) -> TimeInterval {
        let record = record(account, now: now)
        var wait = record.retryAt.map { $0.timeIntervalSince(now) } ?? 0
        if let last = record.calls.last { wait = max(wait, Self.minGap - now.timeIntervalSince(last)) }
        if record.calls.count >= Self.maxPerHour {
            // The oldest call of the window has to leave it before a new one fits.
            let oldest = record.calls[record.calls.count - Self.maxPerHour]
            wait = max(wait, Self.window - now.timeIntervalSince(oldest))
        }
        return max(0, wait)
    }

    /// End of the server's 429 window for this account, while it runs.
    public func retryAt(account: String, now: Date) -> Date? {
        record(account, now: now).retryAt
    }

    public func recordCall(account: String, now: Date) {
        update(account, now: now) { $0.calls.append(now) }
    }

    /// 429 with a Retry-After: nothing for this account before then (capped at `maxRetryAfter`).
    public func recordRetryAfter(_ seconds: TimeInterval, account: String, now: Date) {
        guard seconds.isFinite, seconds > 0 else { return }
        update(account, now: now) { $0.retryAt = now.addingTimeInterval(min(seconds, Self.maxRetryAfter)) }
    }

    public func clearRetry(account: String, now: Date) {
        guard retryAt(account: account, now: now) != nil else { return }
        update(account, now: now) { $0.retryAt = nil }
    }

    // MARK: Storage

    /// The account's record, pruned to what still counts at `now`. Calls are kept sorted.
    private func record(_ account: String, now: Date) -> Record {
        Self.pruned(records()[account] ?? Record(), now: now)
    }

    private static func pruned(_ record: Record, now: Date) -> Record {
        var record = record
        record.calls = record.calls.filter { $0 <= now && now.timeIntervalSince($0) < window }.sorted()
        if let retryAt = record.retryAt, retryAt <= now || retryAt.timeIntervalSince(now) > maxRetryAfter {
            record.retryAt = nil
        }
        return record
    }

    private func records() -> [String: Record] {
        store.decode([String: Record].self, forKey: Self.key) ?? [:]
    }

    private func update(_ account: String, now: Date, _ change: (inout Record) -> Void) {
        var all = records().mapValues { Self.pruned($0, now: now) }
        var record = all[account] ?? Record()
        change(&record)
        all[account] = record
        // Accounts with nothing left to count are forgotten.
        store.encode(all.filter { !$0.value.calls.isEmpty || $0.value.retryAt != nil }, forKey: Self.key)
    }
}
