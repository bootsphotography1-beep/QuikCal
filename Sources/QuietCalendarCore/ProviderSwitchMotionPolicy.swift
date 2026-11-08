import Foundation

// MARK: - Calendar provider switch motion (pure, unit-testable) — 2026-11-07
//
// Owner requirement: switching Mac calendars ↔ Google animates the
// selection indicator and the details body with a smooth ~180–250 ms
// transition. The preference/destination updates IMMEDIATELY (no auth, no
// network, no permission, no model call — just the switch), the outgoing
// details lane is NON-INTERACTIVE from the moment the switch lands, and
// Reduce Motion gets an instant/fade switch with no spring.
//
// Implementation contract (pinned by tests): both lanes stay in the
// hierarchy and crossfade via opacity; the unselected lane is opacity 0,
// hit-testing disabled and accessibility-hidden — so the outgoing lane can
// never receive a tap mid-transition (no double submit) and the height is
// stable (no jump/flicker). No Timer ever delays the business logic; the
// animation is purely visual (`withAnimation` around the state change).

public enum ProviderSwitchMotionPolicy: Sendable {

    /// Crossfade duration in seconds: 220 ms — inside the approved
    /// 180–250 ms band.
    public static let crossfadeDurationSeconds: Double = 0.22

    /// Animation duration to use for the switch. Reduce Motion → nil
    /// (instant switch, no animation delay at all).
    public static func duration(reduceMotion: Bool) -> Double? {
        reduceMotion ? nil : crossfadeDurationSeconds
    }

    /// The crossfade duration, when animated, stays inside the owner's
    /// 180–250 ms band.
    public static func durationInsideApprovedBand(_ duration: Double) -> Bool {
        duration >= 0.18 && duration <= 0.25
    }

    /// Selected lane is fully visible; unselected lane is invisible.
    public static func laneOpacity(isSelected: Bool) -> Double {
        isSelected ? 1 : 0
    }

 /// The unselected lane is non-interactive from the instant the switch
    /// lands — the outgoing details can never take a tap or focus.
    public static func laneIsInteractive(isSelected: Bool) -> Bool {
        isSelected
    }

    /// The unselected lane is hidden from accessibility (no ghost focus).
    public static func laneIsAccessibilityVisible(isSelected: Bool) -> Bool {
        isSelected
    }

    /// Exactly ONE lane is interactive at any time (single-lane XOR is
    /// preserved — confirmed writes go to the selected destination only).
    public static func exactlyOneLaneInteractive(eventKitSelected: Bool, googleSelected: Bool) -> Bool {
        laneIsInteractive(isSelected: eventKitSelected)
            != laneIsInteractive(isSelected: googleSelected)
    }
}
