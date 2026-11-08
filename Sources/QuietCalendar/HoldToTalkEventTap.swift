import AppKit
import QuietCalendarCore

/// Listen-only CGEventTap for `flagsChanged` — the path that actually
/// captures the Fn/Globe key globally (2026-11-07 fix).
///
/// Why this exists (root cause of "holding Fn does nothing even with
/// Accessibility on"): QuikCal is a menu-bar accessory app and is almost
/// never frontmost, so the LOCAL NSEvent monitor never fires in normal
/// use. NSEvent GLOBAL monitors receive standard modifier flagsChanged,
/// but the Fn/Globe key is a system-consumed modifier whose flagsChanged
/// is not reliably delivered to global NSEvent monitors — the proven
/// mechanism used by Fn-remap utilities is a listen-only CGEventTap at
/// the HID level, which sees keycode-63 flagsChanged system-wide.
///
/// Permissions honesty (2026-11-07 privacy repair): a listen-only HID
/// key-event tap's event DELIVERY is gated by Input Monitoring
/// (listen-event access — `CGPreflightListenEventAccess` /
/// `CGRequestListenEventAccess`). Tap CREATION can succeed even in an
/// untrusted process (proven by the 2026-11-07 launch-context
/// experiment B), so `install()` returning true is NEVER proof of
/// delivery — the live QA probe (`logs/fn-tap-probe.txt`) ran in a
/// copy that already held BOTH grants, and actual Fn delivery is
/// always confirmed by the user's first real hold. The monitor gates
/// Fn monitoring on the Input Monitoring probe, never on AX alone.
/// Nothing here auto-requests any grant; Input Monitoring stays a
/// user action (Settings button / system prompt on request). If tap
/// creation returns NULL the failure is reported honestly
/// (`isInstalled == false`); nothing is faked.
///
/// Safety: `.listenOnly` can never modify, suppress or inject events —
/// the user's Fn key keeps its normal system behavior. No event content is
/// recorded; only the abstract keycode + modifier-flag booleans the
/// monitor path already uses (Sendable primitives, no key text).
@MainActor
final class HoldToTalkEventTap {
    /// One delivered flagsChanged event, reduced to Sendable primitives
    /// (keycode + modifier-flag booleans) in the C callback — the same
    /// shape the NSEvent path extracts, so both listener paths feed ONE
    /// interpretation entry point.
    struct FlagsChangedEvent: Sendable, Equatable {
        var keyCode: UInt16
        var functionDown: Bool
        var optionDown: Bool
        var commandDown: Bool
        var controlDown: Bool
    }

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isInstalled = false
    private var disableReenableCount = 0
    private var handler: ((FlagsChangedEvent) -> Void)?
    /// Fired when the tap becomes EFFECTIVELY DEAD — the system disabled
    /// it and the bounded re-enable recovery is exhausted. The owner
    /// (monitor) uses this to update honest install state and to CANCEL
    /// any in-flight hold: for the Fn shortcut this is primary-listener
    /// loss, so a mid-hold release can never be trusted again. Main
    /// thread only (called from `handleTapDisabled`).
    var onEffectivelyDead: (() -> Void)?

    /// Installs (replacing any previous tap — no duplicate taps possible)
    /// a listen-only flagsChanged tap on the main runloop. Returns the
    /// REAL install outcome.
    @discardableResult
    func install(handler: @escaping (FlagsChangedEvent) -> Void) -> Bool {
        uninstall()
        self.handler = handler
        // refcon carries an UNRETAINED reference — the tap never keeps the
        // owner alive; uninstall() must run before the monitor deallocates
        // (the monitor owns this tap and removes it in stopMonitoring).
        let refcon = Unmanaged<HoldToTalkEventTap>.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: holdToTalkTapCallback,
            userInfo: refcon
        ) else {
            // Not authorized (this process copy is not trusted) or tap
            // point unavailable — honest failure, never a fake "on".
            isInstalled = false
            return false
        }
        machPort = port
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            machPort = nil
            isInstalled = false
            return false
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        disableReenableCount = 0
        isInstalled = true
        return true
    }

    /// Removes the tap and its runloop source. Idempotent.
    func uninstall() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let machPort {
            CFMachPortInvalidate(machPort)
        }
        runLoopSource = nil
        machPort = nil
        handler = nil
        isInstalled = false
    }

    /// Called from the C callback on the main thread (tap runs on the main
    /// runloop). Bounded auto re-enable after a system disable; beyond the
    /// bound the tap stays down, `isInstalled` reports the honest
    /// down-state (review fix 2026-11-07: previously it kept claiming
    /// `true` while the tap was disabled and delivering nothing), and the
    /// owner is notified via `onEffectivelyDead` so any in-flight hold is
    /// CANCELLED (fail-safe 2026-11-07) instead of waiting for a release
    /// event that can no longer arrive.
    func handleTapDisabled() {
        if EventTapRecoveryPolicy.shouldReenable(disableCount: disableReenableCount) {
            disableReenableCount += 1
            if let machPort {
                CGEvent.tapEnable(tap: machPort, enable: true)
            }
        } else {
            isInstalled = false
            onEffectivelyDead?()
        }
    }

    /// Delivers one reduced flagsChanged event to the handler (main thread).
    func deliver(_ event: FlagsChangedEvent) {
        handler?(event)
    }
}

/// C trampoline. Runs on the main thread (the tap's runloop source lives on
/// the main runloop) — `MainActor.assumeIsolated` bridges into the actor.
/// The CGEvent is reduced to Sendable primitives HERE, in the nonisolated
/// callback — no non-Sendable object crosses the isolation boundary.
private func holdToTalkTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HoldToTalkEventTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            tap.handleTapDisabled()
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
    let flags = event.flags
    let reduced = HoldToTalkEventTap.FlagsChangedEvent(
        keyCode: UInt16(max(0, event.getIntegerValueField(.keyboardEventKeycode))),
        functionDown: flags.contains(.maskSecondaryFn),
        optionDown: flags.contains(.maskAlternate),
        commandDown: flags.contains(.maskCommand),
        controlDown: flags.contains(.maskControl)
    )
    MainActor.assumeIsolated {
        tap.deliver(reduced)
    }
    // Listen-only: the event always continues to the system unchanged.
    return Unmanaged.passUnretained(event)
}
