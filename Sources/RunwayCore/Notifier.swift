import Foundation

public struct RunwayNotification: Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var playsSound: Bool

    public init(id: String, title: String, body: String, playsSound: Bool) {
        self.id = id
        self.title = title
        self.body = body
        self.playsSound = playsSound
    }
}

/// Delivery side (UNUserNotificationCenter in the app, a recorder in tests).
@MainActor
public protocol NotificationSink: AnyObject {
    func deliver(_ notification: RunwayNotification)
}

/// Remembers what was already notified, across launches.
@MainActor
public protocol NotificationLedger: AnyObject {
    func contains(_ key: String) -> Bool
    /// `relevantUntil`: after this date the key can be pruned.
    func insert(_ key: String, relevantUntil: Date)
    func prune(now: Date)
    var lastSessionResetsAt: Date? { get set }
    var expiredNotified: Bool { get set }
}

public struct NotifierSettings: Equatable, Sendable {
    public var sessionThresholds: [Int]
    public var weeklyThresholds: [Int]
    public var notifySessionReset: Bool

    public static let defaultThresholds = [50, 80, 95]

    public init(sessionThresholds: [Int] = defaultThresholds,
                weeklyThresholds: [Int] = defaultThresholds,
                notifySessionReset: Bool = true) {
        self.sessionThresholds = sessionThresholds
        self.weeklyThresholds = weeklyThresholds
        self.notifySessionReset = notifySessionReset
    }

    /// "50,80,95" ↔ [50, 80, 95]
    public static func parseThresholds(_ csv: String) -> [Int] {
        csv.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (1...100).contains($0) }.sorted()
    }

    public static func encodeThresholds(_ values: [Int]) -> String {
        Set(values).sorted().map(String.init).joined(separator: ",")
    }
}

/// Threshold logic, isolated from UNUserNotificationCenter.
/// One notification per threshold and per window (key = kind + resets_at + threshold).
@MainActor
public final class ThresholdNotifier {
    public static let soundThreshold = 95

    private let ledger: NotificationLedger
    private let sink: NotificationSink
    private let format: RunwayFormat

    public init(ledger: NotificationLedger, sink: NotificationSink, format: RunwayFormat = RunwayFormat()) {
        self.ledger = ledger
        self.sink = sink
        self.format = format
    }

    /// - Parameter isFirstPoll: true for the first snapshot after launch. Thresholds already
    ///   crossed are then recorded silently, so a relaunch never produces a burst.
    @discardableResult
    public func process(_ snapshot: UsageSnapshot, settings: NotifierSettings,
                        isFirstPoll: Bool, now: Date) -> [RunwayNotification] {
        ledger.prune(now: now)
        var out: [RunwayNotification] = []

        if let reset = sessionResetNotification(snapshot, settings: settings, isFirstPoll: isFirstPoll, now: now) {
            out.append(reset)
        }
        if let session = snapshot.session,
           let n = thresholdNotification(session, thresholds: settings.sessionThresholds,
                                         silent: isFirstPoll, now: now) {
            out.append(n)
        }
        if let weekly = snapshot.weekly,
           let n = thresholdNotification(weekly, thresholds: settings.weeklyThresholds,
                                         silent: isFirstPoll, now: now) {
            out.append(n)
        }

        // Back online with a valid token: the next expiry notifies again.
        ledger.expiredNotified = false
        out.forEach(sink.deliver)
        return out
    }

    /// "Claude Code connection expired", once per expiry.
    @discardableResult
    public func connectionExpired() -> RunwayNotification? {
        guard !ledger.expiredNotified else { return nil }
        ledger.expiredNotified = true
        let n = RunwayNotification(id: "expired",
                                     title: tr("Claude Code connection expired"),
                                     body: tr("Open Claude Code to renew it."),
                                     playsSound: false)
        sink.deliver(n)
        return n
    }

    // MARK: - Private

    private func thresholdNotification(_ limit: UsageLimit, thresholds: [Int],
                                       silent: Bool, now: Date) -> RunwayNotification? {
        let window = Self.windowKey(limit.resetsAt)
        let relevantUntil = (limit.resetsAt ?? now).addingTimeInterval(86400)
        var highestNew: Int?
        var highestCrossed: Int?
        for t in thresholds.sorted() where limit.percent >= Double(t) {
            highestCrossed = t
            let key = "\(limit.kind.rawValue)|\(window)|\(t)"
            guard !ledger.contains(key) else { continue }
            ledger.insert(key, relevantUntil: relevantUntil)
            highestNew = t
        }
        // Several thresholds crossed between two polls → only the highest one is shown. A lower one
        // newly enabled in the settings (50 % switched on at 96 %) is recorded, not announced.
        guard let t = highestNew, t == highestCrossed, !silent else { return nil }
        let body = limit.resetsAt.map {
            let time = limit.kind == .session ? format.clock($0) : format.dayAndClock($0)
            return limit.kind == .session ? tr("Resets at \(time).") : tr("Resets \(time).")
        } ?? ""
        return RunwayNotification(id: "\(limit.kind.rawValue)|\(window)|\(t)",
                                    title: limit.kind == .session ? tr("Session at \(t)%") : tr("Weekly at \(t)%"),
                                    body: body,
                                    playsSound: t >= Self.soundThreshold)
    }

    private func sessionResetNotification(_ snapshot: UsageSnapshot, settings: NotifierSettings,
                                          isFirstPoll: Bool, now: Date) -> RunwayNotification? {
        let current = snapshot.session?.resetsAt
        defer {
            if let current { ledger.lastSessionResetsAt = current }
        }
        guard let previous = ledger.lastSessionResetsAt else { return nil }

        // The previous window is over: either resets_at moved, or its time has passed.
        let moved = current.map { abs($0.timeIntervalSince(previous)) > 120 } ?? false
        guard moved || now >= previous else { return nil }

        let key = "reset|\(Self.windowKey(previous))"
        guard !ledger.contains(key) else { return nil }
        ledger.insert(key, relevantUntil: previous.addingTimeInterval(86400))
        guard !isFirstPoll, settings.notifySessionReset else { return nil }
        return RunwayNotification(id: key,
                                    title: tr("Session reset"),
                                    body: tr("Your \(format.duration(Pace.sessionWindow)) session starts over from zero."),
                                    playsSound: false)
    }

    /// resets_at rounded to the minute: the API adds jittery microseconds.
    static func windowKey(_ date: Date?) -> String {
        guard let date else { return "none" }
        return String(Int((date.timeIntervalSince1970 / 60).rounded()))
    }
}

// MARK: - Ledgers

@MainActor
public final class InMemoryLedger: NotificationLedger {
    public var keys: [String: Date] = [:]
    public var lastSessionResetsAt: Date?
    public var expiredNotified = false

    public init() {}

    public func contains(_ key: String) -> Bool { keys[key] != nil }
    public func insert(_ key: String, relevantUntil: Date) { keys[key] = relevantUntil }
    public func prune(now: Date) { keys = keys.filter { $0.value > now } }
}

@MainActor
public final class UserDefaultsLedger: NotificationLedger {
    private let defaults: UserDefaults
    private let keysKey = "runway.notifier.sent"
    private let resetKey = "runway.notifier.lastSessionResetsAt"
    private let expiredKey = "runway.notifier.expiredNotified"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var keys: [String: Double] {
        get { defaults.dictionary(forKey: keysKey) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: keysKey) }
    }

    public func contains(_ key: String) -> Bool { keys[key] != nil }

    public func insert(_ key: String, relevantUntil: Date) {
        keys[key] = relevantUntil.timeIntervalSince1970
    }

    public func prune(now: Date) {
        let t = now.timeIntervalSince1970
        let current = keys
        let kept = current.filter { $0.value > t }
        if kept.count != current.count { keys = kept }
    }

    public var lastSessionResetsAt: Date? {
        get { (defaults.object(forKey: resetKey) as? Double).map(Date.init(timeIntervalSince1970:)) }
        set { defaults.set(newValue?.timeIntervalSince1970, forKey: resetKey) }
    }

    public var expiredNotified: Bool {
        get { defaults.bool(forKey: expiredKey) }
        set { defaults.set(newValue, forKey: expiredKey) }
    }
}
