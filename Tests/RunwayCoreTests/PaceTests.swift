import Foundation
import Testing
@testable import RunwayCore

@Suite struct PaceTests {
    let reset = iso("2026-11-26T16:10:00Z")
    let format = RunwayFormat(timeZone: TimeZone(identifier: "Europe/Paris")!, locale: Locale(identifier: "en_GB"))

    func at(minutesElapsed m: Double) -> Date {
        reset.addingTimeInterval(-Pace.sessionWindow + m * 60)
    }

    @Test func hitsTheWallBeforeReset() {
        // 60 % after 120 min → 0.5 %/min → 100 % 80 min later, 100 min before reset.
        let now = at(minutesElapsed: 120)
        let p = Pace.project(percent: 60, resetsAt: reset, now: now)
        guard case .hitsLimit(let hitAt, let before)? = p else {
            Issue.record("expected hitsLimit, got \(String(describing: p))"); return
        }
        #expect(abs(hitAt.timeIntervalSince(now) - 80 * 60) < 1)
        #expect(abs(before - 100 * 60) < 1)
        // 16:10 UTC reset = 17:10 Paris; hit at 15:30 Paris.
        #expect(format.paceLine(p!) == "At this pace: 100% at 15:30, 1h 40m before reset")
    }

    @Test func staysUnderTheLimit() {
        // 20 % after 150 min, 150 min left → ~40 % at reset.
        let p = Pace.project(percent: 20, resetsAt: reset, now: at(minutesElapsed: 150))
        #expect(p == .reachesAtReset(percent: 40))
        #expect(format.paceLine(p!) == "At this pace: ~40% at reset")
    }

    @Test func tooEarlyOrTooLittle() {
        #expect(Pace.project(percent: 30, resetsAt: reset, now: at(minutesElapsed: 10)) == nil)
        #expect(Pace.project(percent: 4, resetsAt: reset, now: at(minutesElapsed: 200)) == nil)
        #expect(Pace.project(percent: 100, resetsAt: reset, now: at(minutesElapsed: 200)) == nil)
        #expect(Pace.project(percent: 50, resetsAt: reset, now: reset.addingTimeInterval(60)) == nil)
        // Boundary: exactly 15 min and 5 % is allowed.
        #expect(Pace.project(percent: 5, resetsAt: reset, now: at(minutesElapsed: 15)) != nil)
    }
}

@Suite struct FormatTests {
    let format = RunwayFormat(timeZone: TimeZone(identifier: "Europe/Paris")!, locale: Locale(identifier: "en_GB"))

    @Test func copy() {
        #expect(format.clock(iso("2026-11-26T16:10:00Z")) == "17:10")
        #expect(format.dayAndClock(iso("2026-11-30T15:00:00Z")) == "Mon 30 Nov, 16:00") // 30 Nov 2026 is a Monday
        #expect(format.duration(263 * 60) == "4h 23m")
        #expect(format.duration(32 * 60) == "32 min")
        #expect(format.percent(18.4) == "18%")
        let money = format.money(30.8, currency: "EUR")
        #expect(money == "€30.80")
        // Dates and money follow the locale, whatever the copy language.
        let fr = RunwayFormat(timeZone: TimeZone(identifier: "Europe/Paris")!, locale: Locale(identifier: "fr_FR"))
        #expect(fr.clock(iso("2026-11-26T16:10:00Z")) == "17:10")
        #expect(fr.dayAndClock(iso("2026-11-30T15:00:00Z")).hasPrefix("lun. 30 nov."))
        #expect(fr.money(30.8, currency: "EUR").hasPrefix("30,80"))
        let now = Date()
        #expect(format.ago(now.addingTimeInterval(-8), now: now) == "8 s ago")
    }
}
