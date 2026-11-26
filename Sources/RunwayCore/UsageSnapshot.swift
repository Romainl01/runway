import Foundation

public enum LimitKind: String, Sendable, Equatable, Codable {
    case session
    case weeklyAll
    case weeklyScoped
}

public struct UsageLimit: Sendable, Equatable, Identifiable, Codable {
    public var kind: LimitKind
    /// Model name for scoped limits (from `scope.model.display_name`).
    public var modelName: String?
    public var percent: Double
    public var severity: String?
    public var resetsAt: Date?

    public var id: String { kind.rawValue + "|" + (modelName ?? "") }

    /// What to show at `now`: once the window has reset, the value is the previous window's, so 0 %.
    public func percent(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return percent
    }

    public init(kind: LimitKind, modelName: String? = nil, percent: Double,
                severity: String? = nil, resetsAt: Date?) {
        self.kind = kind
        self.modelName = modelName
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
    }
}

public struct UsageCredits: Sendable, Equatable, Codable {
    /// Major units (e.g. euros), already divided by 10^decimal_places.
    public var used: Double
    public var limit: Double?
    public var currency: String

    public var isCapReached: Bool {
        guard let limit, limit > 0 else { return false }
        return used >= limit
    }

    public var fraction: Double? {
        guard let limit, limit > 0 else { return nil }
        return used / limit
    }

    public init(used: Double, limit: Double?, currency: String) {
        self.used = used
        self.limit = limit
        self.currency = currency
    }
}

public struct UsageSnapshot: Sendable, Equatable, Codable {
    public var session: UsageLimit?
    public var weekly: UsageLimit?
    public var scoped: [UsageLimit]
    public var credits: UsageCredits?
    public var fetchedAt: Date

    public init(session: UsageLimit?, weekly: UsageLimit?, scoped: [UsageLimit] = [],
                credits: UsageCredits? = nil, fetchedAt: Date) {
        self.session = session
        self.weekly = weekly
        self.scoped = scoped
        self.credits = credits
        self.fetchedAt = fetchedAt
    }

    /// Normalizes the raw payload: `limits` first, `five_hour` / `seven_day` as fallback.
    public init(response: UsageResponse, fetchedAt: Date) {
        var session: UsageLimit?
        var weekly: UsageLimit?
        var scoped: [UsageLimit] = []

        for raw in response.limits ?? [] {
            guard let kind = raw.kind, let percent = raw.percent else { continue }
            let resetsAt = ISODate.parse(raw.resetsAt)
            switch kind {
            case "session":
                session = session ?? UsageLimit(kind: .session, percent: percent,
                                                severity: raw.severity, resetsAt: resetsAt)
            case "weekly_all":
                weekly = weekly ?? UsageLimit(kind: .weeklyAll, percent: percent,
                                              severity: raw.severity, resetsAt: resetsAt)
            case "weekly_scoped":
                let name = raw.scope?.model?.displayName ?? raw.scope?.model?.id ?? tr("Model")
                scoped.append(UsageLimit(kind: .weeklyScoped, modelName: name, percent: percent,
                                         severity: raw.severity, resetsAt: resetsAt))
            default:
                continue
            }
        }

        if session == nil, let w = response.fiveHour, let u = w.utilization {
            session = UsageLimit(kind: .session, percent: u, resetsAt: ISODate.parse(w.resetsAt))
        }
        if weekly == nil, let w = response.sevenDay, let u = w.utilization {
            weekly = UsageLimit(kind: .weeklyAll, percent: u, resetsAt: ISODate.parse(w.resetsAt))
        }

        var credits: UsageCredits?
        if let extra = response.extraUsage, extra.isEnabled == true, let usedMinor = extra.usedCredits {
            let divisor = pow(10, Double(extra.decimalPlaces ?? 2))
            credits = UsageCredits(used: usedMinor / divisor,
                                   limit: extra.monthlyLimit.map { $0 / divisor },
                                   currency: extra.currency ?? "USD")
        }

        self.init(session: session, weekly: weekly, scoped: scoped, credits: credits, fetchedAt: fetchedAt)
    }

    /// No limit and no credits: the payload had nothing Runway recognizes (an API change, not "0 %").
    public var isEmpty: Bool { session == nil && weekly == nil && scoped.isEmpty && credits == nil }

    /// What the UI shows: no session open yet, or a window reset since the fetch, is 0 %.
    public func sessionPercent(at now: Date) -> Double { session?.percent(at: now) ?? 0 }
    public func weeklyPercent(at now: Date) -> Double { weekly?.percent(at: now) ?? 0 }

    /// True when any displayed value differs (used to pick the fast poll interval).
    public func hasDifferentUsage(than other: UsageSnapshot?) -> Bool {
        guard let other else { return false }
        return session?.percent != other.session?.percent
            || weekly?.percent != other.weekly?.percent
            || scoped.map(\.percent) != other.scoped.map(\.percent)
            || credits?.used != other.credits?.used
    }
}
