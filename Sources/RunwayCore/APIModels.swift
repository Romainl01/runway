import Foundation

// Raw shapes of `GET /api/oauth/usage`. Every field is optional and decoded leniently:
// a field with an unexpected type becomes nil instead of failing the whole payload,
// and unknown keys are ignored.

public struct UsageResponse: Decodable, Sendable, Equatable {
    public var fiveHour: RawWindow?
    public var sevenDay: RawWindow?
    public var extraUsage: RawExtraUsage?
    public var limits: [RawLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case extraUsage = "extra_usage"
        case limits
    }

    public init(fiveHour: RawWindow? = nil, sevenDay: RawWindow? = nil,
                extraUsage: RawExtraUsage? = nil, limits: [RawLimit]? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.extraUsage = extraUsage
        self.limits = limits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = c.lenient(RawWindow.self, .fiveHour)
        sevenDay = c.lenient(RawWindow.self, .sevenDay)
        extraUsage = c.lenient(RawExtraUsage.self, .extraUsage)
        limits = c.lenientArray(RawLimit.self, .limits)
    }
}

public struct RawWindow: Decodable, Sendable, Equatable {
    public var utilization: Double?
    public var resetsAt: String?

    enum CodingKeys: String, CodingKey { case utilization, resetsAt = "resets_at" }

    public init(utilization: Double?, resetsAt: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = c.lenientDouble(.utilization)
        resetsAt = c.lenient(String.self, .resetsAt)
    }
}

public struct RawLimit: Decodable, Sendable, Equatable {
    public var kind: String?
    public var group: String?
    public var percent: Double?
    public var severity: String?
    public var resetsAt: String?
    public var scope: RawScope?
    public var isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    public init(kind: String?, percent: Double?, resetsAt: String?, severity: String? = nil,
                modelName: String? = nil, isActive: Bool? = nil) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.severity = severity
        self.scope = modelName.map { RawScope(model: RawModel(id: nil, displayName: $0)) }
        self.isActive = isActive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lenient(String.self, .kind)
        group = c.lenient(String.self, .group)
        percent = c.lenientDouble(.percent)
        severity = c.lenient(String.self, .severity)
        resetsAt = c.lenient(String.self, .resetsAt)
        scope = c.lenient(RawScope.self, .scope)
        isActive = c.lenient(Bool.self, .isActive)
    }
}

public struct RawScope: Decodable, Sendable, Equatable {
    public var model: RawModel?

    enum CodingKeys: String, CodingKey { case model }

    public init(model: RawModel?) { self.model = model }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = c.lenient(RawModel.self, .model)
    }
}

public struct RawModel: Decodable, Sendable, Equatable {
    public var id: String?
    public var displayName: String?

    enum CodingKeys: String, CodingKey { case id, displayName = "display_name" }

    public init(id: String?, displayName: String?) {
        self.id = id
        self.displayName = displayName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id)
        displayName = c.lenient(String.self, .displayName)
    }
}

public struct RawExtraUsage: Decodable, Sendable, Equatable {
    public var isEnabled: Bool?
    public var monthlyLimit: Double?
    public var usedCredits: Double?
    public var currency: String?
    public var decimalPlaces: Int?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case currency
        case decimalPlaces = "decimal_places"
    }

    public init(isEnabled: Bool?, monthlyLimit: Double?, usedCredits: Double?,
                currency: String?, decimalPlaces: Int? = nil) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.currency = currency
        self.decimalPlaces = decimalPlaces
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.lenient(Bool.self, .isEnabled)
        monthlyLimit = c.lenientDouble(.monthlyLimit)
        usedCredits = c.lenientDouble(.usedCredits)
        currency = c.lenient(String.self, .currency)
        decimalPlaces = c.lenientDouble(.decimalPlaces).map { Int($0) }
    }
}

// MARK: - Lenient decoding helpers

struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    func lenientArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T]? {
        guard let items = lenient([Lenient<T>].self, key) else { return nil }
        return items.compactMap(\.value)
    }

    /// Accepts numbers or numeric strings.
    func lenientDouble(_ key: Key) -> Double? {
        if let d = lenient(Double.self, key) { return d }
        if let s = lenient(String.self, key) { return Double(s) }
        return nil
    }
}

// MARK: - Dates

public enum ISODate {
    /// Parsing with a shared formatter is thread-safe; building one per timestamp is not free.
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses ISO 8601 timestamps with any number of fractional digits (the API sends 6).
    public static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        // Strip the fractional part, keep it as a Double, then parse the rest.
        if let dot = string.firstIndex(of: "."), string[string.index(after: dot)...].first?.isNumber == true {
            var end = string.index(after: dot)
            while end < string.endIndex, string[end].isNumber { end = string.index(after: end) }
            let fraction = Double("0" + string[dot..<end]) ?? 0
            let base = String(string[..<dot]) + String(string[end...])
            return plain.date(from: base).map { $0.addingTimeInterval(fraction) }
        }
        return plain.date(from: string)
    }
}
