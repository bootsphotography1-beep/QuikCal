import Foundation

// MARK: - Accessibility repair status honesty (0.3.13 follow-up, 2026-11-07)
//
// Live owner evidence (2026-11-07): the targeted repair card showed
// "Accessibility / Not yet" while the System Settings toggle was ON, with
// no further explanation. `AXIsProcessTrusted()` is per-process truth — the
// grant in System Settings can belong to a DIFFERENT copy of the app
// (mounted-DMG copy vs /Applications copy, or an older re-signed build),
// in which case the running process honestly reads "not trusted" even
// though the user sees an enabled switch. The repair card previously had no
// vocabulary for that distinction, and no separation between
// "Accessibility granted" and "the shortcut listener is actually
// installed" — two different facts that were conflated into one chip.
//
// This policy is the pure, unit-testable source of truth for what the
// repair card may claim. Rules:
// - The status is computed ONLY from live inputs (the real trust probe,
//   the observed monitor install state, the classified running-bundle
//   location). A pref or saved grant never fakes a state.
// - "Enabled" is claimed only when the process is really trusted.
// - When the process is trusted but the listener is not installed, the
//   copy says the LISTENER is not ready — it never labels Accessibility
//   "off" (that would be the exact false negative the owner saw).
// - When the process is not trusted, the copy distinguishes a
//   transient-location copy (install-first; a grant to another copy can
//   never apply) from an installed copy whose entry may be stale
//   (regrant advice) from a plain not-yet-granted state.

/// What the targeted hold-guide repair card truthfully shows right now.
public enum AccessibilityRepairStatus: Sendable, Equatable {
    /// Process trusted AND the event listener is really installed.
    case grantedAndListening
    /// Process trusted, but the shortcut listener is not installed —
    /// an actionable retry (Check again) can start it. This is NEVER
    /// presented as "Accessibility not enabled".
    case grantedListenerNotReady
    /// Not trusted AND the running copy lives in a transient location
    /// (mounted DMG / App Translocation): a grant to any other copy can
    /// never apply to this process. Install-first advice.
    case notTrustedInstallFirst
    /// Not trusted, installed under /Applications: the System Settings
    /// entry the user sees may point at an older copy — honest
    /// regrant troubleshooting (never asserts the toggle is off).
    case notTrustedPossibleStaleEntry
    /// Not trusted, no special diagnosis: plain "grant, then recheck".
    case notTrustedPendingGrant
}

/// Pinned copy for the repair card's honest status lines (design 7:385
/// card, extended 2026-11-07 with the trust/listener separation).
public enum AccessibilityRepairStatusCopy: Sendable {
    /// Under-chip line when everything is actually working.
    public static let grantedListeningLine =
        "Accessibility is on — hold-to-talk is ready."
    /// Under-chip line when trust is real but the listener is not
    /// installed. Names the LISTENER (never claims Accessibility is off)
    /// and the concrete action.
    public static let grantedListenerNotReadyLine =
        "Accessibility is on, but the shortcut listener isn’t running yet. Check again to start it — no restart needed."
    /// Install-first guidance for a transient copy, naming the honest
    /// cause: a permission granted to another copy does not apply here.
    public static let installFirstLine =
        "This copy runs from a temporary location (a mounted disk image), so an Accessibility switch enabled for another copy can’t apply to it. Move QuikCal to Applications, reopen it from there, then turn it on in Accessibility settings."
    /// Generic pending-grant guidance.
    public static let pendingGrantLine =
        "Turn on QuikCal in Accessibility settings, then Check again."
    /// Diagnostics affordance label (sanitized copy-to-clipboard facts).
    public static let copyDiagnosticsAction = "Copy shortcut diagnostics"
}

/// Pure decision policy for the repair card status.
public enum AccessibilityRepairStatusPolicy: Sendable {
    /// The truthful status for the card, from live inputs only.
    ///
    /// - Parameters:
    ///   - accessibilityTrusted: the LIVE `AXIsProcessTrusted()` result
    ///     for this process (never a pref or cached value).
    ///   - listenerInstalled: the OBSERVED presence of the event
    ///     monitors (`monitorsInstalled`) — intent never fakes this.
    ///   - location: the classified location of the RUNNING bundle
    ///     (`AccessibilityAppLocation.classify(bundlePath:)`).
    public static func status(
        accessibilityTrusted: Bool,
        listenerInstalled: Bool,
        location: AccessibilityAppLocation
    ) -> AccessibilityRepairStatus {
        if accessibilityTrusted {
            return listenerInstalled
                ? .grantedAndListening
                : .grantedListenerNotReady
        }
        if location.requiresInstallFirst {
            return .notTrustedInstallFirst
        }
        if location == .installedApplications {
            return .notTrustedPossibleStaleEntry
        }
        return .notTrustedPendingGrant
    }

    /// The card's under-chip status line for a status. The stale-entry
    /// line reuses the pinned mismatch hint (asserts nothing about the
    /// System Settings toggle).
    public static func statusLine(_ status: AccessibilityRepairStatus) -> String {
        switch status {
        case .grantedAndListening:
            return AccessibilityRepairStatusCopy.grantedListeningLine
        case .grantedListenerNotReady:
            return AccessibilityRepairStatusCopy.grantedListenerNotReadyLine
        case .notTrustedInstallFirst:
            return AccessibilityRepairStatusCopy.installFirstLine
        case .notTrustedPossibleStaleEntry:
            return VoiceOverlayPolicy.accessibilityMismatchHint(
                trusted: false,
                bundlePath: "/Applications/QuikCal.app"
            ) ?? AccessibilityRepairStatusCopy.pendingGrantLine
        case .notTrustedPendingGrant:
            return AccessibilityRepairStatusCopy.pendingGrantLine
        }
    }
}
