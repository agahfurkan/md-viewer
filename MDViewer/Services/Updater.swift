import Foundation
import Observation
import Sparkle

/// Checks for, downloads and installs new versions of the app with Sparkle.
///
/// The update feed (`SUFeedURL`) and the public key updates must be signed with
/// (`SUPublicEDKey`) are in Info.plist. `scripts/release.sh` publishes each version and its feed
/// as a GitHub release.
@MainActor
@Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// False while a check or an update is in progress.
    private(set) var canCheckForUpdates = false

    /// - Parameter startingUpdater: `false` creates an inactive updater (used when hosting tests).
    init(startingUpdater: Bool) {
        controller = SPUStandardUpdaterController(startingUpdater: startingUpdater, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            // Sparkle changes this on the main thread.
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    /// Whether Sparkle checks for updates in the background (daily). Stored by Sparkle.
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// Checks now and shows the result, offering to install a new version if there is one.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
