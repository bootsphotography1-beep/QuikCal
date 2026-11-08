import AppKit
import SwiftUI
import QuietCalendarCore

/// Compact FLOATING window for the approved targeted hold-guide repair
/// card (design 7:385). Presented ONLY by the existing
/// `LaunchReadinessRepairPolicy` path (completed profile + explicit
/// hold-to-talk intent + Accessibility not trusted right now, cold start).
///
/// Semantics preserved from the 0.3.13 targeted repair: skippable, NEVER a
/// pref reset, never a forced grant — "Open Settings" opens the
/// Accessibility pane only, and the full hold-to-talk guide remains
/// reachable from Settings.
///
/// 0.3.13 follow-up (2026-11-07 owner evidence — "Accessibility enabled
/// but it doesn't show on app" + card hidden behind other apps):
/// - Spotlight-like presentation: borderless `FloatingCardWindow` at the
///   `.floating` level joining all Spaces — no red X close control, no
///   accidental close; "Skip for now" stays the explicit dismissal and
///   Quit stays in the status menu.
/// - Yields to `.normal` when Open Settings actually opens the System
///   Settings pane (never covers it or any security prompt); restores
///   floating when the user comes back (app activation / Check again).
/// - The status chip + under-line are computed from LIVE state only
///   (real `AXIsProcessTrusted()` probe + OBSERVED listener install +
///   running-bundle location) via `AccessibilityRepairStatusPolicy` —
///   trust and listener readiness are never conflated.
/// - "Check again" re-probes AND re-attaches the listener when trust just
///   became real (no restart needed; no duplicate event taps).
/// - While the card is visible and the process is not yet trusted, a
///   BOUNDED lightweight poll (`RepairCardPollPolicy`: 1 s interval,
///   600 s hard cap) re-reads the live probe so a grant made in System
///   Settings appears on its own. The poll never activates the app,
///   never steals focus, never re-prompts — and stops the moment trust
///   is real, the card closes, or the cap is reached.
@MainActor
final class HoldGuideRepairCardController: NSWindowController {
    private let holdToTalk: HoldToTalkMonitor
    private let prefs: AppPreferencesStore
    /// Bounded trust-refresh poll (nil unless running).
    private var pollTimer: Timer?
    private var pollElapsed: TimeInterval = 0

    /// DEBUG QA fixture only (0.3.13 follow-up): render the card with a
    /// simulated trusted-but-no-listener state for a LABELLED screenshot
    /// ("QA fixture" chip in-frame). Production passes nil and the card
    /// always renders the real live state.
    private let qaRepairState: QARepairCardFixture?

    /// DEBUG QA fixture only: force the window's AppKit appearance
    /// (light|dark) for labelled screenshots. Production passes nil and
    /// the window follows the Mac's appearance.
    init(
        holdToTalk: HoldToTalkMonitor,
        prefs: AppPreferencesStore,
        qaAppearance: String? = nil,
        qaRepairState: QARepairCardFixture? = nil
    ) {
        self.holdToTalk = holdToTalk
        self.prefs = prefs
        self.qaRepairState = qaRepairState
        let window = FloatingCardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 528, height: 340),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "QuikCal"
        window.backgroundColor = .clear
        window.isOpaque = false
        if qaAppearance == "dark" {
            window.appearance = NSAppearance(named: .darkAqua)
        } else if qaAppearance == "light" {
            window.appearance = NSAppearance(named: .aqua)
        }
        super.init(window: window)
        // Wired after super.init so the skip action can close THIS window
        // (never whichever window happens to be key). The card floats
        // centered with breathing room — not edge-to-edge in the window.
        let host = NSHostingController(
            rootView: HoldGuideRepairCardView(
                holdToTalk: holdToTalk,
                qaRepairState: qaRepairState,
                onOpenSettings: { [weak holdToTalk] in
                    // Opens the pane only — no prompt, no grant, no TCC
                    // edit. The window yields its floating level by
                    // observing the handoff notification this posts.
                    _ = holdToTalk?.openAccessibilitySettings()
                },
                onCheckAgain: { [weak self, weak holdToTalk] in
                    // Fresh probe + listener re-attach when trust is real
                    // (no restart). Restores floating presentation for the
                    // return-from-Settings case.
                    holdToTalk?.checkAgainAndReattach()
                    (self?.window as? FloatingCardWindow)?.restoreFloatingPresentation()
                },
                onCopyDiagnostics: { [weak self, weak holdToTalk] in
                    guard let self, let holdToTalk else { return }
                    let facts = ShortcutDiagnosticCollector.facts(
                        monitor: holdToTalk,
                        prefs: self.prefs
                    )
                    let text = ShortcutDiagnosticsFormatter.render(facts)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                },
                onSkip: { [weak self] in
                    // Dismiss only — no pref is read or written here.
                    self?.window?.close()
                }
            )
            .padding(24)
        )
        window.contentViewController = host
        window.center()
        window.isReleasedWhenClosed = false
        window.installFloatingLifecycle()
        // Stop the bounded poll when the card closes (lifecycle-aware).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cardWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func cardWindowWillClose(_ note: Notification) {
        stopPoll()
    }

    func showAndFront() {
        // Fresh probe at presentation — an old saved untrusted state can
        // never stick as the card's first paint.
        holdToTalk.refreshPermissionFlags()
        (window as? FloatingCardWindow)?.restoreFloatingPresentation()
        showWindow(nil)
        if let window {
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        startPollIfNeeded()
    }

    // MARK: - Bounded trust-refresh poll (RepairCardPollPolicy)

    /// Starts the lightweight poll only when the card is actually shown
    /// and the process is not yet trusted. The poll re-reads the live
    /// probe; when trust flips true it re-attaches the listener once
    /// (guarded, no duplicate taps) and stops itself.
    private func startPollIfNeeded() {
        stopPoll()
        guard window?.isVisible == true else { return }
        guard !effectiveTrusted else { return }
        pollElapsed = 0
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: RepairCardPollPolicy.intervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollTick()
            }
        }
    }

    private func pollTick() {
        guard let window, window.isVisible else {
            stopPoll()
            return
        }
        pollElapsed += RepairCardPollPolicy.intervalSeconds
        // Live probe only — no prompt, no focus, no activation.
        holdToTalk.refreshPermissionFlags()
        if RepairCardPollPolicy.mayReattachListenerOnTrustFlip(
            accessibilityTrustedNow: effectiveTrusted
        ) {
            holdToTalk.reattachIfEnabledIntent()
            stopPoll()
            return
        }
        guard RepairCardPollPolicy.shouldContinue(
            elapsedSeconds: pollElapsed,
            accessibilityTrusted: effectiveTrusted,
            windowVisible: window.isVisible
        ) else {
            stopPoll()
            return
        }
    }

    private func stopPoll() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// The REAL live probe — the QA fixture (DEBUG only) may simulate the
    /// trusted-no-listener state for a labelled screenshot; production
    /// always reads `accessibilityTrusted`.
    private var effectiveTrusted: Bool {
#if DEBUG
        if qaRepairState == .trustedNoListener { return true }
#endif
        return holdToTalk.accessibilityTrusted
    }
}

/// QA fixture selector for the repair card (labelled in-frame):
/// `trustedNoListener` renders the honest "Accessibility is on, but the
/// shortcut listener isn't running yet" state for a screenshot — a state
/// the QA process's real untrusted probe cannot produce without touching
/// TCC (which the QA host never does). The type exists in Release (the
/// view/controller signatures are unconditional) but the QA argument
/// parsing that sets it is compiled out of Release, so no production path
/// can ever set it.
public enum QARepairCardFixture: String, Sendable, Equatable {
    case trustedNoListener
}
