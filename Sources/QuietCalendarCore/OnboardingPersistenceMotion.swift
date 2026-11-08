import Foundation

/// 0.3.8 onboarding persistence + motion policies. Pure logic only — no GUI,
/// no network, no permission probes. Kept in core so the lifecycle is
/// unit-testable without AppKit (same pattern as `OnboardingPopAnimationSpec`).

/// Cross-page visibility of the compact speech-model download banner.
///
/// The shared `ParakeetModelDownloadController` keeps transferring regardless
/// of which onboarding page is shown, so a download started on Voice setup
/// keeps running while the user works through Calendar / hold-to-talk /
/// System Settings. The banner is the cross-page progress surface:
///
/// - Visible on every step **except** Voice setup (that page shows the speech
///   model progress row — a duplicate banner there would double-report).
/// - Visible while a transfer is active, and **also** while a transfer sits in
///   a failed/cancelled aftermath (honest retry surface — never silently hide
///   a dead download).
/// - Never visible merely because weights already sit on disk from a previous
///   setup (idle + ready shows nothing).
public enum OnboardingDownloadBannerPolicy: Sendable {
    public static let failedOrCancelledPhases: [ParakeetDownloadPhase] = [.failed, .cancelled]

    public static func isVisible(
        currentPage: OnboardingPage,
        isTransferring: Bool,
        speechPhase: ParakeetDownloadPhase
    ) -> Bool {
        guard currentPage != .voiceSetup else { return false }
        if isTransferring { return true }
        return failedOrCancelledPhases.contains(speechPhase)
    }
}

/// Which onboarding pages re-probe **live** permission state (read-only) when
/// the app becomes active again — e.g. the user returning from System
/// Settings after toggling a permission.
///
/// - `.calendar`: honest EventKit status refresh (granted / denied /
///   not-determined). Never a prompt, never a request, never auto-advance.
/// - `.axPermission`: the dedicated Accessibility verification step
///   (2026-11-07) — re-probe `AXIsProcessTrusted()` and run one check.
/// - `.voiceSetup`: existing `AXIsProcessTrusted()` recheck on reactivation.
/// - All other pages: no probe (nothing permission-bearing is on those pages).
public enum OnboardingActivationRecheckPolicy: Sendable {
    public static func shouldRecheck(page: OnboardingPage) -> Bool {
        switch page {
        case .calendar, .axPermission, .voiceSetup: return true
        case .welcome, .ready: return false
        }
    }
}

/// Motion for the download banner's insertion/removal. Reduce Motion
/// collapses to a short fade with no movement (mirrors the 0.3.6 pop's
/// fade-only contract); the normal path is a subtle rise + fade that matches
/// the step-transition language (small vertical offsets, ~0.25 s).
public struct OnboardingBannerMotionSpec: Sendable, Equatable {
    public var durationSeconds: Double
    public var fadeOnly: Bool
    /// Vertical offset (points) the banner rises from on insertion.
    /// Zero when `fadeOnly`.
    public var insertionOffsetPoints: Double

    public init(durationSeconds: Double, fadeOnly: Bool, insertionOffsetPoints: Double) {
        self.durationSeconds = durationSeconds
        self.fadeOnly = fadeOnly
        self.insertionOffsetPoints = insertionOffsetPoints
    }

    public static func spec(reduceMotion: Bool) -> OnboardingBannerMotionSpec {
        if reduceMotion {
            return OnboardingBannerMotionSpec(
                durationSeconds: 0.12, fadeOnly: true, insertionOffsetPoints: 0
            )
        }
        return OnboardingBannerMotionSpec(
            durationSeconds: 0.25, fadeOnly: false, insertionOffsetPoints: 8
        )
    }
}
