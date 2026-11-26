import Foundation

/// Copy helpers (localized through the app bundle). Time zone and locale are injectable for tests.
public struct RunwayFormat: Sendable {
    public var timeZone: TimeZone
    public var locale: Locale

    public init(timeZone: TimeZone = .current, locale: Locale = .runway) {
        self.timeZone = timeZone
        self.locale = locale
    }

    /// "18%" in English, "18 %" (non-breaking space) in French.
    public func percent(_ value: Double) -> String {
        let n = Int(value.rounded())
        return tr("\(n)%")
    }

    /// "18%" (mono values in the popover and the menu bar)
    public func compactPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "17:10"
    public func clock(_ date: Date) -> String {
        Formatters.shared.date("jmm", timeZone: timeZone, locale: locale).string(from: date)
    }

    /// "Mon, Nov 30, 4:00 PM" / "lun. 30 nov. 16:00"
    public func dayAndClock(_ date: Date) -> String {
        // Built from two parts: a single template would add "at" / "à" between day and time.
        let day = Formatters.shared.date("EEEdMMM", timeZone: timeZone, locale: locale).string(from: date)
        let time = clock(date)
        return tr("\(day), \(time)")
    }

    /// "4h 23m", "32 min", "less than 1 min" / "4 h 23", "32 min", "moins d’1 min"
    public func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        if minutes < 1 { return tr("less than 1 min") }
        if minutes < 60 { return tr("\(minutes) min") }
        let days = minutes / 1440
        if days >= 1 {
            let hours = (minutes % 1440) / 60
            return hours == 0 ? tr("\(days)d") : tr("\(days)d \(hours)h")
        }
        let (h, m) = (minutes / 60, minutes % 60)
        return m == 0 ? tr("\(h)h") : tr("\(h)h \(m)m")
    }

    /// "in 4h 23m"
    public func countdown(to date: Date, now: Date) -> String {
        date <= now ? tr("now") : tr("in \(duration(date.timeIntervalSince(now)))")
    }

    /// "8 s ago", "3 min ago", "2 h ago"
    public func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 5 { return tr("just now") }
        if s < 60 { return tr("\(s) s ago") }
        if s < 3600 { return tr("\(s / 60) min ago") }
        if s < 86400 { return tr("\(s / 3600) h ago") }
        return tr("\(s / 86400) d ago")
    }

    /// "€30.80" / "30,80 €"
    public func money(_ amount: Double, currency: String) -> String {
        Formatters.shared.money(currency, locale: locale).string(from: NSNumber(value: amount))
            ?? String(format: "%.2f %@", amount, currency)
    }

    /// "At this pace: ~41% at reset" / "At this pace: 100% at 16:08, 32 min before reset"
    public func paceLine(_ projection: PaceProjection) -> String {
        switch projection {
        case .reachesAtReset(let p):
            let pct = percent(p)
            return tr("At this pace: ~\(pct) at reset")
        case .hitsLimit(let at, let before):
            let time = clock(at), left = duration(before)
            return tr("At this pace: 100% at \(time), \(left) before reset")
        }
    }
}

/// Formatters are costly to build and the popover redraws every second: one per configuration.
/// Formatting with a shared formatter is thread-safe on macOS.
final class Formatters: @unchecked Sendable {
    static let shared = Formatters()
    private let lock = NSLock()
    private var cache: [String: Formatter] = [:]

    func date(_ template: String, timeZone: TimeZone, locale: Locale) -> DateFormatter {
        cached("d|\(template)|\(timeZone.identifier)|\(locale.identifier)") {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f
        }
    }

    func money(_ currency: String, locale: Locale) -> NumberFormatter {
        cached("m|\(currency)|\(locale.identifier)") {
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.locale = locale
            f.currencyCode = currency
            return f
        }
    }

    private func cached<F: Formatter>(_ key: String, make: () -> F) -> F {
        lock.withLock {
            if let f = cache[key] as? F { return f }
            let f = make()
            cache[key] = f
            return f
        }
    }
}
