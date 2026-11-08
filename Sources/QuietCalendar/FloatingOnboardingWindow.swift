import AppKit
import QuietCalendarCore

/// Notification posted when QuikCal hands off to an EXTERNAL surface —
/// the System Settings Accessibility pane (deep link actually opened) or
/// the OAuth browser (sign-in actually started). Floating onboarding /
/// repair surfaces observe this and YIELD (drop to the normal window
/// level) so System Settings, the browser, and any security prompt stay
/// visible above them. Posting is best-effort UI coordination only — it
/// never grants, prompts, or edits anything.
extension Notification.Name {
    static let quikCalExternalSurfaceHandoff =
        Notification.Name("QuikCalExternalSurfaceHandoff")
}

/// Shared configuration for QuikCal's floating guide surfaces
/// (onboarding window + targeted repair card), per
/// `FloatingSurfacePolicy`:
/// - Spotlight-like `.floating` level (never screen-saver level), so the
///   guide is never hidden behind other apps' normal windows.
/// - Joins all Spaces + full-screen auxiliary, so it cannot get lost
///   behind a Space switch.
/// - Borderless: NO standard close (red X) control — accidental close is
///   prevented. Genuine escapes are preserved by the surfaces themselves
///   (Skip / Skip for now / Back / Continue, and Quit via the status
///   menu). The user is never trapped.
/// - Yields to `.normal` on an external-surface handoff; restores
///   `.floating` when the app is activated again (clicking the card or
///   its Check again activates this accessory app) or on presentation.
@MainActor
enum FloatingSurfaceConfig {
    static func applyPresentation(to window: NSWindow) {
        window.level = .floating
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]
        window.isMovableByWindowBackground = true
    }

    static func applyYield(to window: NSWindow) {
        window.level = .normal
    }
}

/// Borderless floating window used by the onboarding window and the
/// targeted repair card. `canBecomeKey` is overridden because borderless
/// AppKit windows refuse key status by default — the surfaces are
/// explicitly presented (user action / launch routing) and must take key
/// focus then. There is no standard close button (borderless) and no
/// Cmd-W path (the accessory app has no main menu); dismissal is only
/// the surface's own explicit actions.
@MainActor
final class FloatingCardWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    private var state: FloatingSurfaceState = .presented
    /// Read only from `deinit` (observer teardown) and MainActor methods;
    /// NSObjectProtocol tokens are not Sendable, hence the unsafe markers
    /// (same pattern as `HoldToTalkMonitor.activationObserver`).
    nonisolated(unsafe) private var handoffObserver: NSObjectProtocol?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    /// Configures the floating presentation AND wires the yield/restore
    /// lifecycle. Call once, after the window is created.
    func installFloatingLifecycle() {
        FloatingSurfaceConfig.applyPresentation(to: self)
        state = .presented
        handoffObserver = NotificationCenter.default.addObserver(
            forName: .quikCalExternalSurfaceHandoff,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard FloatingSurfacePolicy.shouldYield(
                    onExternalHandoff: true,
                    state: self.state
                ) else { return }
                self.state = .yieldedForExternalSurface
                FloatingSurfaceConfig.applyYield(to: self)
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard FloatingSurfacePolicy.shouldRestore(
                    onAppActivation: true,
                    onPresentation: false,
                    state: self.state
                ) else { return }
                self.state = .presented
                FloatingSurfaceConfig.applyPresentation(to: self)
            }
        }
    }

    /// Explicit restore (presentation, or a Check-again-style return
    /// while the window is key). No-op when already floating.
    func restoreFloatingPresentation() {
        if FloatingSurfacePolicy.shouldRestore(
            onAppActivation: false,
            onPresentation: true,
            state: state
        ) {
            state = .presented
        }
        FloatingSurfaceConfig.applyPresentation(to: self)
    }

    deinit {
        if let handoffObserver {
            NotificationCenter.default.removeObserver(handoffObserver)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }
}
