import Foundation

// MARK: - Floating onboarding/repair window policy (2026-11-07)
//
// Owner request: QuikCal's onboarding window and the targeted repair card
// must present like Spotlight — floating above other apps' normal windows,
// never hidden behind them, and NOT closable by a red standard close
// button (accidental close loses the guide). Genuine escapes stay:
// the card's "Skip for now", the flow's Skip/Back/Continue, and Quit
// (status menu / Cmd-Q path) — the user is never trapped.
//
// Honesty rules pinned here:
// - The floating level is moderate (above normal windows, Spotlight-like).
//   The extreme `.screenSaver` level is FORBIDDEN — a permission guide
//   must never cover security prompts.
// - When the user hands off to an EXTERNAL surface (System Settings pane
//   via Open Settings, the OAuth browser via Sign in), the floating
//   window YIELDS (drops to the normal level) so System Settings, the
//   browser, and any authentication prompt are never covered.
// - The floating level is restored when the user comes back to QuikCal
//   (app activation — which is what clicking the card or its Check again
//   does for an accessory app) or when the surface is presented again.
// - While a permission guide is visible and the process is not yet
//   trusted, a BOUNDED lightweight poll may refresh the live probe so a
//   grant made in System Settings appears without a restart. The poll is
//   lifecycle-aware: it stops when trust is real, when the window closes,
//   or at a hard cap — never an endless background loop, never a focus
//   hijack, never a reentrant monitor install.

/// Pure representation of the window level a floating QuikCal surface
/// uses. The app target maps `.floating` → `NSWindow.Level.floating` and
/// `.normal` → `NSWindow.Level.normal`; the forbidden screen-saver level
/// is not representable here by design.
public enum FloatingSurfaceLevel: Sendable, Equatable, CaseIterable {
    /// Above normal app windows (Spotlight-like), moderate — never
    /// screen-saver level.
    case floating
    /// The yielding level used during an external-surface handoff so
    /// System Settings / the OAuth browser / security prompts stay
    /// visible above us.
    case normal
}

/// Presentation state of a floating surface.
public enum FloatingSurfaceState: Sendable, Equatable {
    /// Normal presentation: floating above other apps' windows.
    case presented
    /// Yielded after handing off to System Settings / the browser.
    case yieldedForExternalSurface
}

/// Pure transition policy for a floating surface's level.
public enum FloatingSurfacePolicy: Sendable {
    /// The level for a state. `.presented` floats; a yielded surface
    /// drops to normal so the external surface is never covered.
    public static func level(for state: FloatingSurfaceState) -> FloatingSurfaceLevel {
        switch state {
        case .presented: return .floating
        case .yieldedForExternalSurface: return .normal
        }
    }

    /// An external handoff (Open Settings deep link actually opened, or
    /// the OAuth browser actually opened) must yield a floating surface.
    public static func shouldYield(onExternalHandoff: Bool, state: FloatingSurfaceState) -> Bool {
        onExternalHandoff && state == .presented
    }

    /// Restores the floating level when the user returns to QuikCal
    /// (app activation — clicking the card or Check again activates the
    /// accessory app) or the surface is presented again. Yielded →
    /// presented on those triggers only; an already-presented surface
    /// is a no-op.
    public static func shouldRestore(
        onAppActivation: Bool,
        onPresentation: Bool,
        state: FloatingSurfaceState
    ) -> Bool {
        guard state == .yieldedForExternalSurface else { return false }
        return onAppActivation || onPresentation
    }

    /// The collection behavior flags a floating QuikCal surface joins:
    /// visible on all Spaces and over full-screen apps (auxiliary), so
    /// the guide cannot get lost behind a Space switch. No
    /// `.ignoresCycle`-style focus tricks are pinned here.
    public static let joinsAllSpaces = true
    public static let fullScreenAuxiliary = true
}

/// Bounded, lifecycle-aware refresh poll for a visible permission guide
/// (repair card) whose process is not yet Accessibility-trusted. The poll
/// only re-reads the live probe (and re-attaches the listener once trust
/// flips true); it never activates the app, never makes the window key,
/// and never installs anything reentrantly.
public enum RepairCardPollPolicy: Sendable {
    /// Poll interval in seconds — lightweight, human-perceptible.
    public static let intervalSeconds: TimeInterval = 1.0
    /// Hard cap in seconds — the poll always ends, even if the user
    /// leaves the card open forever. No endless background polling.
    public static let maximumDurationSeconds: TimeInterval = 600.0

    /// Whether the poll should continue. It stops the moment trust is
    /// real (the goal is reached), the moment the window is no longer
    /// visible (lifecycle), or at the hard cap.
    public static func shouldContinue(
        elapsedSeconds: TimeInterval,
        accessibilityTrusted: Bool,
        windowVisible: Bool
    ) -> Bool {
        guard windowVisible else { return false }
        guard !accessibilityTrusted else { return false }
        return elapsedSeconds < maximumDurationSeconds
    }

    /// The poll refreshes the live probe only — no prompt, no grant, no
    /// TCC touch, no focus change. When the fresh probe says trusted,
    /// the caller may re-attach the listener exactly once (the existing
    /// `startMonitoringIfPermitted` path removes old monitors before
    /// installing, so no duplicate event taps are possible).
    public static func mayReattachListenerOnTrustFlip(accessibilityTrustedNow: Bool) -> Bool {
        accessibilityTrustedNow
    }
}
