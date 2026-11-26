import Foundation
import RunwayCore
import ServiceManagement
import UserNotifications

enum PrefKey {
    static let sessionThresholds = "runway.sessionThresholds"
    static let weeklyThresholds = "runway.weeklyThresholds"
    static let menuBarMode = "runway.menuBarMode"
    static let notifySessionReset = "runway.notifySessionReset"
    static let tab = "runway.tab"
}

enum MenuBarMode: String, CaseIterable, Identifiable {
    case session, weekly, both, icon
    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: tr("Session")
        case .weekly: tr("Weekly")
        case .both: tr("Both")
        case .icon: tr("Icon")
        }
    }
}

enum Preferences {
    static let defaultThresholds = NotifierSettings.encodeThresholds(NotifierSettings.defaultThresholds)

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            PrefKey.sessionThresholds: defaultThresholds,
            PrefKey.weeklyThresholds: defaultThresholds,
            PrefKey.menuBarMode: MenuBarMode.session.rawValue,
            PrefKey.notifySessionReset: true,
        ])
    }

    static func notifierSettings(_ d: UserDefaults = .standard) -> NotifierSettings {
        NotifierSettings(
            sessionThresholds: NotifierSettings.parseThresholds(d.string(forKey: PrefKey.sessionThresholds) ?? defaultThresholds),
            weeklyThresholds: NotifierSettings.parseThresholds(d.string(forKey: PrefKey.weeklyThresholds) ?? defaultThresholds),
            notifySessionReset: d.bool(forKey: PrefKey.notifySessionReset))
    }
}

/// "Open at Mac startup" — only meaningful from the signed .app bundle.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            runwayLog.error("launch at login: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// Delivers through UNUserNotificationCenter. Requires a bundle: no-op when run as a bare binary.
@MainActor
final class UserNotificationSink: NotificationSink {
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliver(_ notification: RunwayNotification) {
        guard let center else {
            debugLog("notification (no bundle): \(notification.title)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        if notification.playsSound { content.sound = .default }
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
        center.add(request) { error in
            if let error { runwayLog.error("notification: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
