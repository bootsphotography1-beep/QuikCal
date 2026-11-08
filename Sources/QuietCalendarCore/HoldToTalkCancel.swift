import Foundation

// MARK: - Hold cancellation (privacy/correctness fail-safe, 2026-11-07)
//
// The residual defect this closes: if EVERY listener path died mid-hold
// (Fn event tap disabled by the system with bounded recovery exhausted,
// monitoring stopped, Accessibility trust revoked, app quitting), the
// release event could never arrive — the state machine stayed `.holding`
// and the microphone kept recording until the next press or quit, with a
// click-through pill the user could not even dismiss.
//
// The fix introduces an explicit CANCEL transition, distinct from the
// release transition. A release is TRUSTED (a real flagsChanged from a
// live listener) and continues into stop → transcribe → parse → confirm.
// A cancel is UNTRUSTED by definition: it terminates the recording and
// clears the held state with NO transcription, NO parse, NO submit and
// NO calendar write — nothing recorded from an untrusted path can ever
// reach the calendar.

/// Why an active hold was cancelled (never submitted). The raw value is
/// stable, diagnostic-friendly text.
public enum HoldToTalkCancelReason: String, Sendable, Equatable {
    /// The Fn event tap died (system disable, bounded recovery exhausted)
    /// or the listener set was replaced/stopped — for the Fn shortcut this
    /// is effective PRIMARY listener loss even if NSEvent monitors remain
    /// registered (global Fn delivery over NSEvent is unreliable).
    case listenerLost
    /// `AXIsProcessTrusted()` turned false mid-session (Accessibility was
    /// revoked) — the listener can no longer be trusted to deliver the
    /// release.
    case permissionLost
    /// The user turned hold-to-talk off while holding.
    case monitoringStopped
    /// Watchdog: the physical key reads UP (debounced over several
    /// probes) while the state machine still holds — the release event was
    /// lost. Cancelled, never submitted.
    case lostRelease
    /// Watchdog: the recording reached the conservative safety cap while
    /// still held. No auto-submit — the user holds again to continue.
    case maxDuration
    /// The app is quitting with a hold active — terminate the recording,
    /// show nothing.
    case appTerminating
}

// MARK: - Watchdog policy (pure)

/// Pure decision table for the active-hold watchdog. The watchdog is a
/// bounded BACKSTOP only — the real Fn/shortcut release handlers remain
/// the ONLY path that ends a hold with transcribe → parse → confirm. The
/// watchdog's only power is cancellation.
///
/// The physical probe is a read-only `CGEventSource.flagsState` snapshot
/// owned by the host (the same helper the 0.3.11 mic-grant fail-safe
/// uses) — no event injection, no key logging, no new permission. It runs
/// ONLY while a hold is actually active (capturing or practicing) and
/// its timer is closed on release, cancel or stop.
public enum HoldToTalkWatchdogPolicy: Sendable {
    /// Interval between physical-key probes while a hold is active.
    public static let tickInterval: TimeInterval = 0.2
    /// Consecutive UP probes required before a lost release is confirmed
    /// (debounce against a single misread ≈ 0.6 s at the default interval).
    public static let releasedConfirmTicks = 3
    /// Conservative recording cap (fix brief: ~60–120 s band, not tiny).
    /// A cap NEVER auto-submits — it cancels with a clear reason.
    public static let maxHoldSeconds: TimeInterval = 90

    /// One watchdog tick's decision.
    public enum Action: Equatable, Sendable {
        case keepWatching
        case cancel(HoldToTalkCancelReason)
    }

    /// - Parameters:
    ///   - elapsedSeconds: time since the hold began.
    ///   - keyPhysicallyDown: the live read-only HID modifier state of the
    ///     configured shortcut (false when the read cannot confirm — the
    ///     safe direction for a *stop*, never for a start).
    ///   - consecutiveUpTicks: how many consecutive ticks read UP so far.
    public static func action(
        elapsedSeconds: TimeInterval,
        keyPhysicallyDown: Bool,
        consecutiveUpTicks: Int
    ) -> Action {
        // The cap applies even while the key is genuinely held — a
        // recording must never outlive the bound. No auto-submit.
        if elapsedSeconds >= maxHoldSeconds {
            return .cancel(.maxDuration)
        }
        if keyPhysicallyDown {
            return .keepWatching
        }
        // Key reads UP while the state machine still holds: debounce,
        // then treat as a CONFIRMED lost release — cancel, never submit.
        if consecutiveUpTicks >= releasedConfirmTicks {
            return .cancel(.lostRelease)
        }
        return .keepWatching
    }
}

// MARK: - Watchdog (stateful, injectable)

/// Stateful active-hold watchdog. The host (the AppKit monitor) opens
/// the window on a real hold-begin, closes it on release/cancel/stop, and
/// schedules ticks on the main thread while active. Tests inject the
/// clock and the physical-key probe and drive `tick()` directly — no real
/// timer, no HID reads, no event taps in tests.
///
/// Idempotency: `holdBegan()` on an active watch is a no-op (double
/// delivery from tap + NSEvent counts as ONE hold); `holdEnded()` when
/// inactive is a no-op. A cancel decision closes the watch BEFORE the
/// cancel callback fires, so the callback can never race a second tick.
public final class HoldToTalkHoldWatchdog {
    private let now: () -> Date
    private let keyPhysicallyDown: () -> Bool
    private let onCancel: (HoldToTalkCancelReason) -> Void
    private(set) public var isActive = false
    private var holdBeganAt: Date?
    private var consecutiveUpTicks = 0

    public init(
        now: @escaping () -> Date = { Date() },
        keyPhysicallyDown: @escaping () -> Bool,
        onCancel: @escaping (HoldToTalkCancelReason) -> Void
    ) {
        self.now = now
        self.keyPhysicallyDown = keyPhysicallyDown
        self.onCancel = onCancel
    }

    /// Opens the watch window for a hold (no-op if already active — the
    /// phase guards upstream make double delivery one hold).
    public func holdBegan() {
        guard !isActive else { return }
        isActive = true
        holdBeganAt = now()
        consecutiveUpTicks = 0
    }

    /// Closes the watch window (release, cancel, stop). Idempotent.
    public func holdEnded() {
        guard isActive else { return }
        isActive = false
        holdBeganAt = nil
        consecutiveUpTicks = 0
    }

    /// One probe tick. The host schedules this only while `isActive`;
    /// calling it while inactive is a safe no-op (phantom ticks from a
    /// stale timer can never cancel anything).
    public func tick() {
        guard isActive, let began = holdBeganAt else { return }
        let elapsed = now().timeIntervalSince(began)
        let down = keyPhysicallyDown()
        consecutiveUpTicks = down ? 0 : consecutiveUpTicks + 1
        switch HoldToTalkWatchdogPolicy.action(
            elapsedSeconds: elapsed,
            keyPhysicallyDown: down,
            consecutiveUpTicks: consecutiveUpTicks
        ) {
        case .keepWatching:
            break
        case .cancel(let reason):
            holdEnded()
            onCancel(reason)
        }
    }
}
