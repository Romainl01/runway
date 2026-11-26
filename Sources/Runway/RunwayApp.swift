import AppKit
import RunwayCore
import SwiftUI

@main
struct RunwayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: appDelegate.store, ram: appDelegate.ram)
        } label: {
            MenuBarLabel(store: appDelegate.store, ram: appDelegate.ram)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: UsageStore
    let ram: RAMStore
    private let sink = UserNotificationSink()
    private let isPreview = CommandLine.arguments.contains("--preview-window")
    private let isFixture: Bool
    private var previewWindow: NSWindow?

    override init() {
        Preferences.registerDefaults()
        let env = ProcessInfo.processInfo.environment

        // QA: RUNWAY_FIXTURE=<json> replaces the network call (and the keychain read);
        // RUNWAY_NOW=<ISO 8601> shifts the clock so the fixture's resets_at stay in the future.
        let fixturePath = env["RUNWAY_FIXTURE"].flatMap { $0.isEmpty ? nil : $0 }
        isFixture = fixturePath != nil
        let offset = ISODate.parse(env["RUNWAY_NOW"]).map { $0.timeIntervalSinceNow } ?? 0
        let now: @Sendable () -> Date = { Date().addingTimeInterval(offset) }

        let credentials: any CredentialsProvider
        let accounts: any AccountProvider
        let client: any UsageFetching
        let ledger: NotificationLedger
        let persistence: any KeyValueStore
        if let fixturePath {
            credentials = StaticCredentialsProvider(.success(ClaudeCredentials(
                accessToken: "fixture", expiresAt: nil, subscriptionType: "team",
                rateLimitTier: "default_claude_max_5x")))
            accounts = StaticAccountProvider(ClaudeAccount(email: "you@example.com", kind: .team,
                                                           organizationName: "Acme"))
            client = FixtureUsageClient(url: URL(fileURLWithPath: fixturePath))
            ledger = InMemoryLedger()
            persistence = MemoryStore()
            debugLog("fixture mode: \(fixturePath)")
        } else {
            credentials = KeychainCredentialsProvider()
            accounts = ClaudeConfigAccountProvider()
            client = HTTPUsageClient()
            ledger = UserDefaultsLedger()
            persistence = UserDefaults.standard
            // v0.1 kept these under separate keys; the gate and the snapshot cache replace them.
            for key in ["runway.cache.snapshot", "runway.cache.retryAt", "runway.cache.accountID", "runway.cache.apiCalls"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        store = UsageStore(credentials: credentials,
                           client: client,
                           accounts: accounts,
                           persistence: persistence,
                           notifier: ThresholdNotifier(ledger: ledger, sink: sink),
                           settings: { Preferences.notifierSettings() },
                           now: now)

        let scanner: any MemoryScanning
        let stopper: any MemoryStopping
        if isFixture && env["RUNWAY_LIVE_MEMORY"] != nil {
            // QA: this Mac's real processes, with a stopper that never signals anything.
            scanner = SystemMemoryScanner()
            stopper = NoopMemoryStopper()
        } else if isFixture {
            scanner = FixtureMemoryScanner()
            stopper = NoopMemoryStopper()
        } else {
            scanner = SystemMemoryScanner()
            stopper = ProcessStopper()
        }
        ram = RAMStore(scanner: scanner, stopper: stopper, now: now)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Runway per Mac: a second one would show the same thing (the CallGate already keeps
        // them from calling twice). QA runs are exempt.
        if !isFixture && !isPreview, let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            debugLog("another Runway is running: quitting")
            NSApp.terminate(nil)
            return
        }
        // QA: RUNWAY_THEME=system|light|dark|glass sets the starting theme.
        Cheatcodes.shared.applyAppearance()
        if !isFixture && !isPreview { sink.requestAuthorization() }
        store.start()
        ram.start()
        // QA: RUNWAY_SCENARIO=<id> (calm, warning, critical, creditsCap, overflow, personal, loading,
        // offline, expired, claudeCodeMissing) shows a cheatcode scenario at launch; mem-<id> (mem-calm,
        // mem-medium, mem-critical, mem-hover, mem-confirm, mem-stopping, mem-stopped, mem-busy,
        // mem-loading, mem-overflow) does the same for the Memory tab.
        if let id = ProcessInfo.processInfo.environment["RUNWAY_SCENARIO"] {
            if let scenario = Scenario(rawValue: id) {
                scenario.apply(to: store)
            } else if let scenario = MemoryScenario(launchID: id) {
                scenario.apply(to: ram)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh(.wake) }
        }

        if isPreview { openPreviewWindow() }

        // QA: RUNWAY_DUMP_MENUBAR=<dir> writes sample menu bar labels as PNG (status items can hide behind the notch).
        if let dir = ProcessInfo.processInfo.environment["RUNWAY_DUMP_MENUBAR"] {
            MenuBarImage.dumpSamples(to: URL(fileURLWithPath: dir))
        }

        // QA: RUNWAY_OPEN_MENU=1 opens the real MenuBarExtra panel after launch.
        if ProcessInfo.processInfo.environment["RUNWAY_OPEN_MENU"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let button = NSApp.windows
                    .filter { String(describing: type(of: $0)).contains("StatusBar") }
                    .compactMap { $0.contentView?.allSubviews.compactMap { $0 as? NSStatusBarButton }.first
                        ?? ($0.contentView as? NSStatusBarButton) }
                    .first
                debugLog("open menu: status button \(button.map { "\($0.window?.frame ?? .zero)" } ?? "not found")")
                button?.performClick(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        isPreview
    }

    /// `--preview-window`: the popover content in a regular window, for screenshot QA.
    private func openPreviewWindow() {
        // Same system glass panel as the MenuBarExtra window, so the preview shows the real shape and border.
        let hosting = NSHostingView(rootView: PopoverView(store: store, ram: ram))
        let glass = NSGlassEffectView()
        glass.cornerRadius = Theme.popoverRadius
        glass.contentView = hosting
        let size = hosting.fittingSize
        let window = PreviewWindow(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = glass
        window.title = "Runway"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // On the menu bar's screen (Retina on a laptop), so captures are 2x whatever screen has focus.
        if let screen = NSScreen.screens.first {
            let f = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2))
        } else {
            window.center()
        }
        previewWindow = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private extension NSView {
    var allSubviews: [NSView] { subviews + subviews.flatMap(\.allSubviews) }
}

/// Borderless window that can still become key (the popover draws its own border).
final class PreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
