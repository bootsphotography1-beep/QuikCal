
import Foundation
import Sparkle

/// QuikCal update policy (owner-approved 2026-11-08, revised 0.3.19):
/// Sparkle automatically CHECKS the public GitHub Releases appcast on a
/// sensible cadence (official default: once per 24 h, plus a check shortly
/// after launch when due) and NOTIFIES the user through Sparkle's native
/// update alert (release notes + Skip This Version / Remind Me Later /
/// Install Update). Downloads, installs, and relaunches happen ONLY on that
/// explicit user action — `SUAutomaticallyUpdate` is never set and
/// `SUAllowsAutomaticUpdates` is false in Info.plist, so silent downloads
/// and silent installs are structurally disallowed (Sparkle's
/// "automatically download and install" opt-in checkbox is hidden). No
/// force-update, no telemetry (`SUEnableSystemProfiling` stays unset).
///
/// Automatic checks are enabled by DEFAULT via `SUEnableAutomaticChecks` in
/// Info.plist, which per official Sparkle docs also suppresses Sparkle's
/// second-launch consent prompt (no duplicate startup consent — onboarding
/// is never blocked by an updater dialog). The default is a persistent,
/// user-controllable preference: `SPUUpdater.automaticallyChecksForUpdates`
/// is KVO compliant and persists itself in the host bundle's user defaults
/// (key `SUEnableAutomaticChecks`), so this controller binds a Settings
/// toggle straight to it and keeps NO separate preference of its own.
/// Manual "Check for Updates…" works regardless of the toggle's state.
///
/// The Sparkle service is created unstarted and is started on the main
/// actor only after the app has finished launching (`startUpdater()`),
/// per Sparkle's programmatic-setup expectations. This controller is
/// retained by AppDelegate for the process lifetime.
@MainActor
final class AppUpdaterController: ObservableObject {
    /// KVO-driven enable state for the menu item + Settings row
    /// (`SPUUpdater.canCheckForUpdates` is KVO compliant).
    @Published private(set) var canCheckForUpdates = false

    /// User-facing "Automatically check for updates" setting. Two-way bound
    /// to `SPUUpdater.automaticallyChecksForUpdates` (Sparkle's own
    /// persistence — no separate user default). The didSets guard against
    /// feedback loops: each side only writes when it actually differs from
    /// the updater's current value, so KVO echoes terminate immediately.
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            guard automaticallyChecksForUpdates != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private let controller: SPUStandardUpdaterController

    init() {
        // Deferred start: no updater work happens before app readiness.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Seed from Sparkle's persisted/defaulted value (user default
        // `SUEnableAutomaticChecks`, falling back to the Info.plist
        // default true). Equal-value seed → no write-back, no loop.
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        // `assign(to: &$…)` keeps its subscription alive for the
        // publisher's lifetime — no cancellable to retain.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    /// Starts the Sparkle updater service — main actor, after
    /// `applicationDidFinishLaunching` (app readiness). Sparkle then schedules
    /// the automatic check cycle itself (after-launch check when due, then the
    /// default 24 h interval while running); no custom polling anywhere.
    func startUpdater() {
        controller.startUpdater()
    }

    /// Manual, user-initiated check only (status menu + Settings). Works
    /// whether or not automatic checks are enabled. The standard Sparkle UI
    /// handles download/install/relaunch with explicit user actions; nothing
    /// is installed silently.
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
