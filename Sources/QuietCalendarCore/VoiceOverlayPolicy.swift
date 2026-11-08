import Foundation

/// Pure policy + copy for the hold-to-talk voice overlay and model-download
/// progress (onboarding voice/UX repair). No AppKit here — unit-testable.
public enum VoiceOverlayPolicy {

    // MARK: - Placement (compact top-center pill)

    /// Top-center origin for the listening/status pill, inside
    /// `visibleFrame` (which already excludes the menu bar and the notch
    /// region). Clamps inside the visible frame on narrow or multi-screen
    /// setups so the pill can never sit under the notch or off-screen.
    /// - `topInset`: gap below the top of the visible frame.
    public static func pillOrigin(
        visibleFrameMinX: Double,
        visibleFrameMinY: Double,
        visibleFrameWidth: Double,
        visibleFrameHeight: Double,
        pillWidth: Double,
        pillHeight: Double,
        topInset: Double = 12
    ) -> (x: Double, y: Double) {
        let width = max(0, pillWidth)
        let height = max(0, pillHeight)
        let maxX = visibleFrameMinX + max(0, visibleFrameWidth)
        let maxY = visibleFrameMinY + max(0, visibleFrameHeight)
        // macOS screen coordinates: y grows upward. Top of the visible
        // frame is maxY; the pill hangs below it by topInset.
        var y = maxY - height - topInset
        var x = visibleFrameMinX + ((max(0, visibleFrameWidth) - width) / 2)
        // Clamp fully inside the visible frame.
        x = min(max(x, visibleFrameMinX), max(visibleFrameMinX, maxX - width))
        y = min(max(y, visibleFrameMinY), max(visibleFrameMinY, maxY - height))
        return (x, y)
    }

    // MARK: - Progress copy (two-decimal GB, never raw bytes)

    /// Two-decimal gigabytes, e.g. 731_400_000 → "0.73 GB".
    public static func gigabytes(_ bytes: Int64) -> String {
        let gb = Double(max(0, bytes)) / 1_000_000_000.0
        return String(format: "%.2f GB", gb)
    }

    /// "0.73 out of 3.47 GB" — downloaded / total, two decimals, no raw
    /// bytes. The unit appears once, on the total. Unknown or zero total
    /// degrades to "X.XX GB downloaded".
    public static func progressLabel(received: Int64, total: Int64) -> String {
        guard total > 0 else { return "\(gigabytes(received)) downloaded" }
        let clamped = min(max(0, received), total)
        return "\(gbNumber(clamped)) out of \(gigabytes(total))"
    }

    /// Bare two-decimal gigabyte number, e.g. "0.73" (no unit).
    private static func gbNumber(_ bytes: Int64) -> String {
        String(format: "%.2f", Double(max(0, bytes)) / 1_000_000_000.0)
    }

    // MARK: - Voice gate (concise blocked reasons, never silent)

    public enum VoiceGateOutcome: Equatable {
        case ready
        case blocked(reason: String)
    }

    /// Pre-flight gate before a hold starts listening. The pill must show a
    /// short, non-technical reason when voice cannot run — never silence.
    /// `micPermissionGranted` mirrors `AVCaptureDevice.authorizationStatus`:
    /// `true` = granted, `nil` = not determined (the app never asked —
    /// 0.3.11: the user's hold key or the capture-panel mic button is the
    /// reachable request action; the system prompt fires from that intent,
    /// never automatically), `false` = denied (System Settings is the right
    /// fix). This gate never requests or prompts by itself.
    public static func gate(
        modelReady: Bool,
        micPermissionGranted: Bool?
    ) -> VoiceGateOutcome {
        if !modelReady {
            return .blocked(reason: "The voice model isn't downloaded yet. You can still type.")
        }
        switch micPermissionGranted {
        case .some(true):
            break
        case .none:
            return .blocked(reason: micNotDeterminedCopy)
        case .some(false):
            return .blocked(reason: micDeniedCopy)
        }
        return .ready
    }

    // MARK: - Mic permission copy (shared by gate + hold-intent prompt flow)

    /// Shown while the official system mic prompt is up (fired by the
    /// user's hold or mic-button tap — never on launch / permission pages /
    /// downloads). This hold never records; the next hold does.
    public static var micNotDeterminedCopy: String {
        "Allow microphone access in the pop-up to talk. Your next hold records."
    }

    /// Grant arrived after the hold already ended — never an auto recording;
    /// the user's next hold records.
    public static var micGrantedNextHoldCopy: String {
        "Microphone ready — hold again to talk."
    }

    /// Denied (or re-denied): System Settings is the honest fix.
    public static var micDeniedCopy: String {
        "Microphone access is off. Enable it in System Settings to talk."
    }

    // MARK: - Hold cancel copy (fail-safe, 2026-11-07)
    //
    // A CANCELLED hold is never submitted — the pill must say the
    // recording STOPPED and why, concisely and honestly. These strings
    // are the ONLY user-facing cancel copy (asserted by tests).

    /// Pill copy for each cancel reason. `.appTerminating` returns an
    /// empty string — no pill is shown while the app is quitting.
    public static func holdCancelCopy(for reason: HoldToTalkCancelReason) -> String {
        switch reason {
        case .listenerLost:
            return "Shortcut disconnected. Recording stopped."
        case .permissionLost:
            return "Accessibility was lost. Recording stopped."
        case .monitoringStopped:
            return "Hold-to-talk was turned off. Recording stopped."
        case .lostRelease:
            return "Key release was missed. Recording stopped — hold again to talk."
        case .maxDuration:
            return "Recording stopped at the 90-second safety limit. Hold again to continue."
        case .appTerminating:
            return ""
        }
    }

    // MARK: - Accessibility mismatch (honest diagnosis, no TCC touch)

    /// When `AXIsProcessTrusted` is false, the app cannot observe the actual
    /// System Settings toggle or prove WHY an entry does not match — so the
    /// copy says "Permission not detected", never "switched off". The older
    /// entry mention is conditional troubleshooting, not an asserted fact.
    /// Pure diagnosis from the bundle path; never fakes "enabled", never
    /// touches TCC, and stays silent for developer / DMG copies (the guide's
    /// install-first warning already covers those).
    ///
    /// 2026-11-07 mismatch evidence (owner screenshot): the System Settings
    /// switch can be ON while the running process honestly reads untrusted —
    /// every QuikCal build is ad-hoc re-signed, and macOS re-evaluates
    /// Accessibility trust against the CURRENT binary. That is OS truth, not
    /// a stale check: the hint gives the two standard regrant actions
    /// (switch off/on once, or remove + re-add) without ever asserting the
    /// toggle's state or faking trust.
    public static func accessibilityMismatchHint(
        trusted: Bool,
        bundlePath: String
    ) -> String? {
        guard !trusted else { return nil }
        guard bundlePath.hasPrefix("/Applications/") else { return nil }
        return "Permission not detected. App updates re-sign QuikCal, and macOS re-checks trust per version. If QuikCal is already listed with its switch on, turn the switch off and on once — or remove that entry, then add this QuikCal again (drag it in or use +)."
    }
}
