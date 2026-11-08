import Foundation

// MARK: - Ready-page completion copy (2026-11-07 final polish)
//
// Parent fix 1: the Ready page previously showed an owner-banned
// "Experimental AI" chip, a decorative fake entry bar, and a filler chip
// row. What remains is ONE short instruction naming the ACTUAL selected
// hold key, plus a truthful readiness summary only when something is
// genuinely not ready. Copy policy is pure and tested; the view renders
// exactly this — never a hardcoded key claim, never "all ready" when a
// page was skipped.

public enum OnboardingCompletionCopy: Sendable {
    /// The single completion instruction. `shortcutName` is the ACTUAL
    /// selected hold key from prefs (not always Fn). When voice setup was
    /// skipped, the copy stays honest: typing works now, hold-to-talk is
    /// NOT claimed ready and can be enabled later in Settings.
    public static func instruction(
        voiceSetupSkipped: Bool,
        shortcutName: String
    ) -> String {
        if voiceSetupSkipped {
            return "Click the menu bar icon to type. Hold-to-talk was skipped — enable it anytime in Settings."
        }
        return "Hold \(shortcutName) to speak, or click the menu bar icon to type."
    }

    /// Truthful readiness summary ONLY for the not-ready-yet cases
    /// (speech model transferring / pending). When it is ready the page
    /// shows no summary line and no badges — nothing to disclose.
    public static func readinessSummary(
        isTransferring: Bool,
        speechModelReady: Bool
    ) -> String? {
        if isTransferring {
            return "Speech model downloading in background — continue in Settings → Speech & Parsing."
        }
        if !speechModelReady {
            return "You can type now. Download the speech model later in Settings → Speech & Parsing."
        }
        return nil
    }
}
