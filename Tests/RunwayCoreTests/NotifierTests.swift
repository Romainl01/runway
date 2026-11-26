import Foundation
import Testing
@testable import RunwayCore

@MainActor
final class RecordingSink: NotificationSink {
    var delivered: [RunwayNotification] = []
    func deliver(_ notification: RunwayNotification) { delivered.append(notification) }
}

func snapshot(session: Double?, sessionReset: Date? = iso("2026-11-26T16:10:00Z"),
              weekly: Double? = nil, weeklyReset: Date? = iso("2026-11-30T15:00:00Z"),
              at now: Date = iso("2026-11-26T13:00:00Z")) -> UsageSnapshot {
    UsageSnapshot(session: session.map { UsageLimit(kind: .session, percent: $0, resetsAt: sessionReset) },
                  weekly: weekly.map { UsageLimit(kind: .weeklyAll, percent: $0, resetsAt: weeklyReset) },
                  fetchedAt: now)
}

@MainActor
@Suite struct NotifierTests {
    let now = iso("2026-11-26T13:00:00Z")
    let format = RunwayFormat(timeZone: TimeZone(identifier: "Europe/Paris")!, locale: Locale(identifier: "en_GB"))

    func make() -> (ThresholdNotifier, RecordingSink, InMemoryLedger) {
        let sink = RecordingSink(), ledger = InMemoryLedger()
        return (ThresholdNotifier(ledger: ledger, sink: sink, format: format), sink, ledger)
    }

    @Test func notifiesEachThresholdOncePerWindow() {
        let (n, sink, _) = make()
        let s = NotifierSettings()
        n.process(snapshot(session: 10), settings: s, isFirstPoll: true, now: now)
        n.process(snapshot(session: 52), settings: s, isFirstPoll: false, now: now)
        n.process(snapshot(session: 55), settings: s, isFirstPoll: false, now: now)
        n.process(snapshot(session: 81), settings: s, isFirstPoll: false, now: now)
        n.process(snapshot(session: 96), settings: s, isFirstPoll: false, now: now)
        n.process(snapshot(session: 97), settings: s, isFirstPoll: false, now: now)
        #expect(sink.delivered.map(\.title) == ["Session at 50%", "Session at 80%", "Session at 95%"])
        #expect(sink.delivered.map(\.playsSound) == [false, false, true])
        #expect(sink.delivered.first?.body == "Resets at 17:10.")
    }

    @Test func firstPollMarksCrossedThresholdsSilently() {
        let (n, sink, _) = make()
        n.process(snapshot(session: 85, weekly: 73), settings: NotifierSettings(), isFirstPoll: true, now: now)
        #expect(sink.delivered.isEmpty)
        n.process(snapshot(session: 90, weekly: 79), settings: NotifierSettings(), isFirstPoll: false, now: now)
        #expect(sink.delivered.isEmpty)
        n.process(snapshot(session: 95, weekly: 80), settings: NotifierSettings(), isFirstPoll: false, now: now)
        #expect(sink.delivered.map(\.title) == ["Session at 95%", "Weekly at 80%"])
    }

    @Test func reEnablingALowerThresholdLateStaysSilent() {
        let (n, sink, _) = make()
        var s = NotifierSettings()
        s.sessionThresholds = [80, 95]
        n.process(snapshot(session: 10), settings: s, isFirstPoll: true, now: now)
        n.process(snapshot(session: 96), settings: s, isFirstPoll: false, now: now)
        s.sessionThresholds = [50, 80, 95]
        n.process(snapshot(session: 97), settings: s, isFirstPoll: false, now: now)
        #expect(sink.delivered.map(\.title) == ["Session at 95%"])
    }

    @Test func jumpOverSeveralThresholdsShowsOnlyTheHighest() {
        let (n, sink, ledger) = make()
        n.process(snapshot(session: 0), settings: NotifierSettings(), isFirstPoll: true, now: now)
        n.process(snapshot(session: 90), settings: NotifierSettings(), isFirstPoll: false, now: now)
        #expect(sink.delivered.map(\.title) == ["Session at 80%"])
        #expect(ledger.keys.count == 2) // 50 and 80 both recorded
    }

    @Test func newWindowRearmsThresholds() {
        let (n, sink, _) = make()
        let s = NotifierSettings(notifySessionReset: false)
        n.process(snapshot(session: 0), settings: s, isFirstPoll: true, now: now)
        n.process(snapshot(session: 60), settings: s, isFirstPoll: false, now: now)
        let next = iso("2026-11-26T21:10:00Z")
        n.process(snapshot(session: 60, sessionReset: next), settings: s, isFirstPoll: false, now: now)
        #expect(sink.delivered.map(\.title) == ["Session at 50%", "Session at 50%"])
    }

    @Test func respectsConfiguredThresholds() {
        let (n, sink, _) = make()
        let s = NotifierSettings(sessionThresholds: [80], weeklyThresholds: [])
        n.process(snapshot(session: 0, weekly: 0), settings: s, isFirstPoll: true, now: now)
        n.process(snapshot(session: 60, weekly: 99), settings: s, isFirstPoll: false, now: now)
        #expect(sink.delivered.isEmpty)
        n.process(snapshot(session: 80, weekly: 99), settings: s, isFirstPoll: false, now: now)
        #expect(sink.delivered.map(\.title) == ["Session at 80%"])
    }

    @Test func microsecondJitterIsTheSameWindow() {
        let (n, sink, _) = make()
        n.process(snapshot(session: 0), settings: NotifierSettings(), isFirstPoll: true, now: now)
        n.process(snapshot(session: 51, sessionReset: iso("2026-11-26T16:10:00.252515+00:00")),
                  settings: NotifierSettings(), isFirstPoll: false, now: now)
        n.process(snapshot(session: 52, sessionReset: iso("2026-11-26T16:10:00.871000+00:00")),
                  settings: NotifierSettings(), isFirstPoll: false, now: now)
        #expect(sink.delivered.count == 1)
    }

    @Test func sessionResetNotifiesOnceAndCanBeDisabled() {
        let (n, sink, _) = make()
        n.process(snapshot(session: 40), settings: NotifierSettings(), isFirstPoll: true, now: now)
        // Window passed, API not updated yet.
        let later = iso("2026-11-26T16:11:00Z")
        n.process(snapshot(session: 40), settings: NotifierSettings(), isFirstPoll: false, now: later)
        // New window appears: same old window → no duplicate.
        n.process(snapshot(session: 2, sessionReset: iso("2026-11-26T21:15:00Z")),
                  settings: NotifierSettings(), isFirstPoll: false, now: later)
        #expect(sink.delivered.map(\.title) == ["Session reset"])

        let (n2, sink2, _) = make()
        let off = NotifierSettings(notifySessionReset: false)
        n2.process(snapshot(session: 40), settings: off, isFirstPoll: true, now: now)
        n2.process(snapshot(session: 2, sessionReset: iso("2026-11-26T21:15:00Z")), settings: off, isFirstPoll: false, now: later)
        #expect(sink2.delivered.isEmpty)
    }

    @Test func sessionResetFromPreviousLaunchIsSilent() {
        let (n, sink, ledger) = make()
        ledger.lastSessionResetsAt = iso("2026-11-26T08:00:00Z")
        n.process(snapshot(session: 5), settings: NotifierSettings(), isFirstPoll: true, now: now)
        #expect(sink.delivered.isEmpty)
        #expect(ledger.lastSessionResetsAt == iso("2026-11-26T16:10:00Z"))
    }

    @Test func expiredOnceUntilRecovered() {
        let (n, sink, _) = make()
        n.connectionExpired()
        n.connectionExpired()
        #expect(sink.delivered.map(\.title) == ["Claude Code connection expired"])
        n.process(snapshot(session: 1), settings: NotifierSettings(), isFirstPoll: true, now: now)
        n.connectionExpired()
        #expect(sink.delivered.count == 2)
    }

    @Test func userDefaultsLedgerPersistsAndPrunes() {
        let defaults = UserDefaults(suiteName: "runway.tests.\(UUID().uuidString)")!
        let a = UserDefaultsLedger(defaults: defaults)
        a.insert("k1", relevantUntil: now.addingTimeInterval(10))
        a.insert("k2", relevantUntil: now.addingTimeInterval(-10))
        a.lastSessionResetsAt = now
        a.expiredNotified = true
        let b = UserDefaultsLedger(defaults: defaults)
        #expect(b.contains("k1") && b.contains("k2"))
        #expect(b.lastSessionResetsAt == now && b.expiredNotified)
        b.prune(now: now)
        #expect(b.contains("k1") && !b.contains("k2"))
    }

    @Test func thresholdCSV() {
        #expect(NotifierSettings.parseThresholds("95, 50,80,abc,0,101") == [50, 80, 95])
        #expect(NotifierSettings.encodeThresholds([95, 50, 50]) == "50,95")
        #expect(NotifierSettings.parseThresholds("") == [])
    }
}
