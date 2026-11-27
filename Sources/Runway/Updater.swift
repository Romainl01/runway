import Foundation
import Observation
import Sparkle

/// Sparkle 2, fed by the `appcast.xml` attached to the latest GitHub release (written by scripts/release.sh).
/// Checks on its own once a day; "Check for Updates" in Settings asks now.
@MainActor
@Observable
final class Updater {
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// "0.1.0", or nil outside an app bundle (`swift run`).
    static var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// `enabled` is false in QA runs (fixture, preview window) and outside a bundle with a feed.
    /// QA runs still draw the button as enabled, like the shipped app, and clicking it does nothing.
    init(enabled: Bool) {
        guard enabled, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            canCheckForUpdates = !enabled
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = can }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
