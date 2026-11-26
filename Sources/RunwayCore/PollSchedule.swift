import Foundation

/// Adaptive interval: 3 min while usage moved in the last 10 min, 5 min otherwise; exponential
/// backoff on 429 / 5xx, capped at 15 min. The server's Retry-After and the call budget are the
/// `CallGate`'s job: the loop never sleeps less than the gate asks.
public struct PollSchedule: Sendable, Equatable {
    /// 3 min: a 5 h session moves about 1 % a minute at most, and 20 calls an hour is all the
    /// `CallGate` allows; popover opens and clicks need some of it.
    public static let fastInterval: TimeInterval = 180
    public static let slowInterval: TimeInterval = 300
    public static let activityWindow: TimeInterval = 600
    public static let maxBackoff: TimeInterval = 900
    /// Expired token / Claude Code missing: nothing to fetch, just watch the keychain.
    public static let idleInterval: TimeInterval = 120

    public private(set) var lastChangeAt: Date?
    public private(set) var consecutiveThrottles = 0

    public init() {}

    public mutating func recordSuccess(changed: Bool, now: Date) {
        consecutiveThrottles = 0
        if changed { lastChangeAt = now }
    }

    public mutating func recordThrottle() {
        consecutiveThrottles += 1
    }

    public func nextInterval(now: Date) -> TimeInterval {
        if consecutiveThrottles > 0 {
            let exponent = Double(min(consecutiveThrottles - 1, 10))
            return min(Self.maxBackoff, Self.fastInterval * pow(2, exponent))
        }
        if let lastChangeAt, now.timeIntervalSince(lastChangeAt) < Self.activityWindow {
            return Self.fastInterval
        }
        return Self.slowInterval
    }
}
