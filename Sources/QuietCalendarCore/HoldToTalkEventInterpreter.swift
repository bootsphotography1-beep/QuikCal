import Foundation

// MARK: - Fn/Globe event interpretation (pure, unit-testable)
//
// Extracted from the AppKit monitor's `handle(event:)` (2026-11-07) so the
// REAL callback pipeline — flagsChanged → interpretation → state machine →
// begin/end callbacks — is testable with synthetic events in the pure test
// target (the app target is an executable and cannot be imported by tests).
//
// Fn/Globe (hardware keycode 63) must be matched by KEYCODE, not by the
// `.function` flag alone: arrow keys and F-key events also carry the
// `.function` flag (NX_SECONDARYFNMASK, 0x800000 — the same bit NSEvent
// exposes as `.function`), which previously made any F-key press look like
// an Fn hold. For the Fn shortcut, ONLY keycode-63 events drive the state
// machine; other shortcuts keep flag-based matching.

/// Hardware keycode of the Fn / Globe key (kVK_Function).
public let HoldToTalkFnKeyCode: UInt16 = 63

/// Pure interpretation of ONE flagsChanged event against the configured
/// shortcut. Stateless: the state machine (not this type) provides the
/// idempotency that makes double delivery — e.g. the same physical press
/// arriving from BOTH the CGEventTap and an NSEvent monitor — count as a
/// single hold.
public enum HoldToTalkEventInterpreter: Sendable {

    /// What one delivered flagsChanged event means for the shortcut.
    public enum Decision: String, Sendable, Equatable {
        /// Not our key, or not a shortcut transition (e.g. autorepeat
        /// while already holding — the machine ignores it).
        case ignore
        /// The shortcut modifier went DOWN (press).
        case press
        /// The shortcut modifier cleared (release).
        case release
    }

    /// Interpret one flagsChanged event.
    ///
    /// - Parameters:
    ///   - shortcut: the configured shortcut kind.
    ///   - keyCode: the event's hardware keycode (63 = Fn/Globe).
    ///   - functionDown: the `.function` / NX_SECONDARYFNMASK flag state.
    ///   - optionDown / commandDown / controlDown: the other modifier flags.
    public static func decision(
        shortcut: HoldToTalkShortcutKind,
        keyCode: UInt16,
        functionDown: Bool,
        optionDown: Bool,
        commandDown: Bool,
        controlDown: Bool
    ) -> Decision {
        let matches: Bool
        switch shortcut {
        case .fn:
            // KEYCODE-gated: F1…F12 and arrows carry the same flag — only
            // keycode 63 is the physical Fn/Globe key.
            guard keyCode == HoldToTalkFnKeyCode else { return .ignore }
            matches = functionDown
        case .option:
            matches = optionDown
        case .command:
            matches = commandDown
        case .control:
            matches = controlDown
        }
        return matches ? .press : .release
    }
}

// MARK: - Hold-to-talk event pipeline (the REAL production path)
//
// One delivered flagsChanged event → pure interpretation → state machine
// → counters/timestamps → begin/end (or practice) callbacks. The AppKit
// monitor delegates here, and the tests drive the SAME pipeline with
// synthetic events — the tested path IS the production path, not a
// reimplementation. The state machine's phase guards make double delivery
// (e.g. the same physical press arriving from BOTH the CGEventTap and an
// NSEvent monitor) count as ONE hold — no duplicate callbacks.

public final class HoldToTalkEventPipeline {
    public private(set) var machine: HoldToTalkStateMachine
    public private(set) var holdCycleCount = 0
    public private(set) var releaseCycleCount = 0
    /// Detected releases in onboarding practice preview — drives the
    /// honest "Released — nothing saved." status.
    public private(set) var practiceReleaseCount = 0
    /// Timestamp of the last detected hold begin (diagnostics only —
    /// numbers/timestamps, never key content).
    public private(set) var lastHoldAt: Date?
    /// Timestamp of the last detected hold end (diagnostics only).
    public private(set) var lastReleaseAt: Date?
    /// Last practice transition for the onboarding preview (no mic / no
    /// writes).
    public private(set) var practicePhase: HoldToTalkPhase = .idle
    /// When true, hold/release only updates practicePhase — no capture
    /// callbacks.
    public var practicePreviewOnly = false
    public var onBeginHold: (() -> Void)?
    public var onEndHold: (() -> Void)?
    /// FAIL-SAFE cancel callback (2026-11-07): fired EXACTLY ONCE per
    /// cancelled hold, and ONLY from `cancelHold(reason:)` — never from a
    /// release. The host must terminate the recording with NO
    /// transcription, NO parse and NO submit.
    public var onCancelHold: ((HoldToTalkCancelReason) -> Void)?
    /// How many holds were cancelled (never submitted) — diagnostics
    /// counter only, asserted by the fail-safe tests.
    public private(set) var holdCancelCount = 0
    /// Invoked ONLY on a monitor-detected practice release (never a
    /// button press). Onboarding marks its persisted "seen" here.
    public var onPracticeRelease: (() -> Void)?

    public init(shortcut: HoldToTalkShortcutKind = .fn) {
        machine = HoldToTalkStateMachine(shortcut: shortcut)
    }

    /// Applies one interpreted event. Idempotent per physical press: press
    /// while holding and release while idle are both no-ops.
    public func deliver(_ decision: HoldToTalkEventInterpreter.Decision) {
        switch decision {
        case .ignore:
            return
        case .press:
            guard machine.phase != .holding else { return }
            if machine.handle(modifierMatchesShortcut: true, isKeyDown: true) == .beginHold {
                practicePhase = .holding
                holdCycleCount += 1
                lastHoldAt = Date()
                if !practicePreviewOnly {
                    onBeginHold?()
                }
            }
        case .release:
            guard machine.phase == .holding else { return }
            if machine.handle(modifierMatchesShortcut: false, isKeyDown: false) == .endHold {
                practicePhase = .idle
                releaseCycleCount += 1
                lastReleaseAt = Date()
                if practicePreviewOnly {
                    // A REAL detected release — this (never a Try-it
                    // button) is what marks the practice as performed.
                    practiceReleaseCount += 1
                    onPracticeRelease?()
                } else {
                    onEndHold?()
                }
            }
        }
    }

    // MARK: Intent/state forwarding (called by the AppKit monitor)

    /// CANCELS an active hold — the fail-safe path DISTINCT from release
    /// (2026-11-07). Called when listener paths die mid-hold, permission
    /// is lost, monitoring is stopped, the watchdog confirms a lost
    /// release, the recording cap elapses, or the app quits. Effects:
    /// - the state machine leaves `.holding` (stale async work — delayed
    ///   mic grants, late release events, delayed starts — re-check the
    ///   phase and can never continue into recording or submit);
    /// - `onCancelHold` fires EXACTLY ONCE with the reason.
    /// NO transcribe, NO parse, NO submit, NO calendar write — nothing
    /// from an untrusted termination ever reaches the pipeline.
    /// Idempotent: cancelling while not holding is a no-op, and a second
    /// cancel after the first is a no-op.
    public func cancelHold(reason: HoldToTalkCancelReason) {
        guard machine.phase == .holding else { return }
        machine.forceIdle()
        practicePhase = .idle
        holdCancelCount += 1
        onCancelHold?(reason)
    }

    public func setShortcut(_ kind: HoldToTalkShortcutKind) {
        machine.shortcut = kind
    }

    public func setMonitoringEnabled(_ enabled: Bool) {
        machine.monitoringEnabled = enabled
    }

    public func forceIdle() {
        machine.forceIdle()
        practicePhase = .idle
    }
}

// MARK: - Event-tap recovery policy (pure)
//
// A listen-only CGEventTap can be disabled by the system (timeout while the
// runloop was busy, or secure-input states). Auto re-enable is bounded so a
// pathologically blocked tap can never spin; after the bound the listener
// reports honestly instead of pretending to listen.

public enum EventTapRecoveryPolicy: Sendable {
    /// Maximum automatic re-enable attempts after a system disable.
    public static let maxReenableAttempts = 3

    /// May the tap auto re-enable itself after `disableCount` system
    /// disables? Bounded — never an infinite re-enable loop.
    public static func shouldReenable(disableCount: Int) -> Bool {
        disableCount < maxReenableAttempts
    }
}

// MARK: - Listener install policy (pure)
//
// Honest aggregation of the three real listener paths (local NSEvent
// monitor, global NSEvent monitor, listen-only CGEventTap) plus the
// Fn-specific honesty rule: the tap is the only path that reliably sees the
/// Fn/Globe key globally while the accessory app is not frontmost.

public enum HoldToTalkListenerPolicy: Sendable {
    /// True only if at least one listener path is REALLY installed.
    public static func listenerInstalled(local: Bool, global: Bool, eventTap: Bool) -> Bool {
        local || global || eventTap
    }

    /// Fn/Globe is a system-consumed modifier: NSEvent global monitors do
    /// not reliably deliver its flagsChanged, and the local monitor only
    /// fires while the app is key (a menu-bar accessory app almost never
    /// is). The listen-only CGEventTap is the path that actually captures
    /// Fn globally — so for the Fn shortcut a missing tap deserves its own
    /// honest status line, never a silent "on".

    /// True when the Fn shortcut is active but the event tap did not
    /// install — the "listener on, Fn capture degraded" honesty case.
    public static func fnCaptureDegraded(shortcut: HoldToTalkShortcutKind, eventTapInstalled: Bool) -> Bool {
        shortcut == .fn && !eventTapInstalled
    }
}
