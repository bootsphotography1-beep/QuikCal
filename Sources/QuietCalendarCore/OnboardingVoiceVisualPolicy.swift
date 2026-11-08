import Foundation

/// Pure, unit-testable policy for the 0.3.13 onboarding visual pass
/// (owner-approved Figma REV2.1, 2026-11-07). No AppKit/SwiftUI here.
public enum OnboardingVoiceVisualPolicy: Sendable {

    // MARK: - Welcome (design 6:14 / 7:251 — short what/how only)

    public enum WelcomeCopy {
        public static let brand = "QuikCal"
        public static let headline = "Speak to manage your calendar."
        public static let how = "Hold Fn to add or delete an event. Review it, then confirm."
    }

    // MARK: - Voice-bar glass (2026-11-07 owner revision)
    //
    // The 0.3.13 glass comparison tiles (Low/Current/High, design
    // 26:2–26:32) were REMOVED per the owner's one-preview revision —
    // superseded by `VoiceBarGlassPolicy` (bar-background material only,
    // content never blurred) and the single `VoiceBarPreviewStage`.

    // MARK: - Fn key practice visual (design 24:46–24:53, 7:69/7:95/7:121/7:154)

    /// The visual state of the practice key cap. Derived ONLY from real
    /// monitor state — never from a timer or a button press.
    public enum PracticeKeyState: String, Sendable, Equatable {
        /// Waiting: neutral sage cap.
        case neutral
        /// Real hold detected: cap fills RED and (unless Reduce Motion)
        /// lifts up. Recording/holding semantics — nothing destructive.
        case holding
        /// Real release detected: settled back to neutral.
        case released
        /// Detection not installed (Accessibility not granted): honest
        /// muted cap, never a faked hold.
        case unavailable
    }

    public static func practiceKeyState(
        phase: HoldToTalkPhase,
        listenerInstalled: Bool
    ) -> PracticeKeyState {
        if !listenerInstalled { return .unavailable }
        switch phase {
        case .holding: return .holding
        case .releasing, .idle: return .neutral
        }
    }

    /// Lift offset (pt) for the held cap. Reduce Motion: no movement —
    /// the red fill and label carry the state instead.
    public static func keyLiftOffset(state: PracticeKeyState, reduceMotion: Bool) -> Double {
        state == .holding && !reduceMotion ? -6 : 0
    }

    /// True when the cap fills red (holding) — with or without motion.
    public static func keyIsRed(state: PracticeKeyState) -> Bool {
        state == .holding
    }

    // MARK: - Root background + primary fill (owner rule, 0.3.13 final pass)
    //
    // Design 6:14/6:41/6:122/6:211/7:95 are all `bg-white` (light) with a
    // dark equivalent; the owner rule pins solid #FFFFFF light / #1E1E1E
    // dark, native automatic appearance, gradient ONLY inside the glass
    // sample tiles.

    /// Solid root background, light: #FFFFFF.
    public static let rootBackgroundLightRGB = (red: 1.0, green: 1.0, blue: 1.0)
    /// Solid root background, dark: #1E1E1E.
    public static let rootBackgroundDarkRGB = (red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0)

    /// Primary-button fill: deep sage #4e7a62 (design 6:39/6:67/6:151/
    /// 6:246/7:119). White text on it is AA (≈4.9:1); the lighter accent
    /// #739e85 (≈3:1) is reserved for rings/dots/icons, never a fill under
    /// white text.
    public static let primaryFillRGB = (red: 78.0 / 255.0, green: 122.0 / 255.0, blue: 98.0 / 255.0)

    // MARK: - Google signed-out (design 6:122 / 24:45 / 6:147)

    public enum GoogleSignedOutCopy {
        public static let importLinkLabel = "Import Google configuration…"
        /// Full accessible name for the tiny link (44 pt hit target).
        public static let importAccessibilityLabel = "Import Google configuration"
    }

    #if DEBUG
    /// DEBUG QA fixture only (labelled in-frame): the status text that
    /// pairs with a simulated TRUSTED monitor for the held/neutral cap
    /// fixtures, so a screenshot never shows a held-red cap next to a
    /// "detection is not active" warning. `.unavailable`, `.released` and
    /// `nil` (production) return nil — the REAL honest status stands and
    /// detection is never faked there.
    public static func qaPracticeStatusOverride(fixture: PracticeKeyState?) -> String? {
        switch fixture {
        case .holding:
            return PracticeDetectionPolicy.practiceStatusText(
                phase: .holding, releaseDetected: false,
                listenerInstalled: true, accessibilityTrusted: true, shortcutName: "")
        case .neutral:
            return PracticeDetectionPolicy.practiceStatusText(
                phase: .idle, releaseDetected: false,
                listenerInstalled: true, accessibilityTrusted: true, shortcutName: "")
        default:
            return nil
        }
    }
    #endif
}
