import Testing
import Foundation
@testable import QuietCalendarCore

// 0.3.13 follow-up (2026-11-07): trust/listener separation + floating
// window policy for the targeted repair card and the onboarding window.
// Owner evidence driving these pins: "Accessibility enabled [in System
// Settings] but it doesn't show on app" — the card must never present a
// bare misleading "Not yet", must never label Accessibility "off" when
// only the LISTENER is missing, and must name the honest cause (stale
// entry vs transient copy). Window pins: Spotlight-like floating level,
// yield to System Settings/browser, never screen-saver level, bounded
// lifecycle-aware poll.

struct AccessibilityWindowFixTests {

    // MARK: - Repair status policy (trust vs listener vs location)

    @Test func grantedAndListeningIsTheReadyState() {
        let status = AccessibilityRepairStatusPolicy.status(
            accessibilityTrusted: true,
            listenerInstalled: true,
            location: .installedApplications
        )
        #expect(status == .grantedAndListening)
        #expect(AccessibilityRepairStatusPolicy.statusLine(status)
                == AccessibilityRepairStatusCopy.grantedListeningLine)
    }

    @Test func trustedWithoutListenerIsListenerNotReady_NeverAccessibilityOff() {
        // The exact conflation the owner saw: trust real, listener not
        // installed. The copy must name the LISTENER and an action — it
        // must NOT claim Accessibility is off / "Not yet".
        let status = AccessibilityRepairStatusPolicy.status(
            accessibilityTrusted: true,
            listenerInstalled: false,
            location: .installedApplications
        )
        #expect(status == .grantedListenerNotReady)
        let line = AccessibilityRepairStatusPolicy.statusLine(status)
        #expect(line == AccessibilityRepairStatusCopy.grantedListenerNotReadyLine)
        #expect(!line.contains("Not yet"))
        #expect(!line.contains("not enabled"))
        #expect(line.lowercased().contains("listener"))
    }

    @Test func untrustedMountedDMGCopiesGetInstallFirstAdvice() {
        // A grant in System Settings can never apply to a DMG copy —
        // the card must say WHY (transient copy), not a bare "Not yet".
        for location in [AccessibilityAppLocation.mountedDiskImage, .appTranslocation] {
            let status = AccessibilityRepairStatusPolicy.status(
                accessibilityTrusted: false,
                listenerInstalled: false,
                location: location
            )
            #expect(status == .notTrustedInstallFirst)
            let line = AccessibilityRepairStatusPolicy.statusLine(status)
            #expect(line == AccessibilityRepairStatusCopy.installFirstLine)
            #expect(line.contains("temporary location"))
        }
    }

    @Test func untrustedInstalledCopyGetsStaleEntryTroubleshooting() {
        let status = AccessibilityRepairStatusPolicy.status(
            accessibilityTrusted: false,
            listenerInstalled: false,
            location: .installedApplications
        )
        #expect(status == .notTrustedPossibleStaleEntry)
        // Reuses the pinned non-assertive mismatch hint — never claims
        // the System Settings toggle is off.
        #expect(AccessibilityRepairStatusPolicy.statusLine(status)
                == VoiceOverlayPolicy.accessibilityMismatchHint(
                    trusted: false,
                    bundlePath: "/Applications/QuikCal.app"
                ))
    }

    @Test func untrustedOtherCopiesGetPlainPendingGrantCopy() {
        for location in [AccessibilityAppLocation.developerBuild, .other] {
            let status = AccessibilityRepairStatusPolicy.status(
                accessibilityTrusted: false,
                listenerInstalled: false,
                location: location
            )
            #expect(status == .notTrustedPendingGrant)
            #expect(AccessibilityRepairStatusPolicy.statusLine(status)
                    == AccessibilityRepairStatusCopy.pendingGrantLine)
        }
    }

    @Test func repairStatusNeverFakesReadyFromIntentAlone() {
        // Untrusted + listener somehow installed (e.g. monitors left over
        // from a trust flip window): trust is still the authority for the
        // chip; the policy must not report granted states.
        let status = AccessibilityRepairStatusPolicy.status(
            accessibilityTrusted: false,
            listenerInstalled: true,
            location: .installedApplications
        )
        #expect(status == .notTrustedPossibleStaleEntry)
    }

    // MARK: - Floating surface policy (Spotlight-like, yields, never screen-saver)

    @Test func presentedFloats_YieldedDropsToNormal() {
        #expect(FloatingSurfacePolicy.level(for: .presented) == .floating)
        #expect(FloatingSurfacePolicy.level(for: .yieldedForExternalSurface) == .normal)
    }

    @Test func yieldOnlyOnExternalHandoffWhilePresented() {
        #expect(FloatingSurfacePolicy.shouldYield(onExternalHandoff: true, state: .presented))
        #expect(!FloatingSurfacePolicy.shouldYield(onExternalHandoff: false, state: .presented))
        // Already yielded: no repeat transitions.
        #expect(!FloatingSurfacePolicy.shouldYield(onExternalHandoff: true, state: .yieldedForExternalSurface))
    }

    @Test func restoreOnlyWhenYielded_OnActivationOrPresentation() {
        #expect(FloatingSurfacePolicy.shouldRestore(onAppActivation: true, onPresentation: false, state: .yieldedForExternalSurface))
        #expect(FloatingSurfacePolicy.shouldRestore(onAppActivation: false, onPresentation: true, state: .yieldedForExternalSurface))
        #expect(!FloatingSurfacePolicy.shouldRestore(onAppActivation: false, onPresentation: false, state: .yieldedForExternalSurface))
        // Already presented: restoring is a no-op decision.
        #expect(!FloatingSurfacePolicy.shouldRestore(onAppActivation: true, onPresentation: true, state: .presented))
    }

    @Test func floatingSurfaceJoinsAllSpacesAndFullScreenAuxiliary() {
        #expect(FloatingSurfacePolicy.joinsAllSpaces)
        #expect(FloatingSurfacePolicy.fullScreenAuxiliary)
    }

    @Test func screenSaverLevelIsNotRepresentable() {
        // The policy's level type has exactly two cases; the forbidden
        // screen-saver extreme cannot be expressed through it.
        #expect(FloatingSurfaceLevel.allCases.count == 2)
        #expect(FloatingSurfaceLevel.allCases.contains(.floating))
        #expect(FloatingSurfaceLevel.allCases.contains(.normal))
    }

    // MARK: - Bounded lifecycle-aware poll

    @Test func pollContinuesOnlyWhileVisibleUntrustedAndUnderCap() {
        #expect(RepairCardPollPolicy.shouldContinue(
            elapsedSeconds: 0, accessibilityTrusted: false, windowVisible: true))
        // Trust reached: stop immediately (goal achieved).
        #expect(!RepairCardPollPolicy.shouldContinue(
            elapsedSeconds: 1, accessibilityTrusted: true, windowVisible: true))
        // Window closed: stop (lifecycle-aware).
        #expect(!RepairCardPollPolicy.shouldContinue(
            elapsedSeconds: 1, accessibilityTrusted: false, windowVisible: false))
        // Hard cap: never an endless background loop.
        #expect(!RepairCardPollPolicy.shouldContinue(
            elapsedSeconds: RepairCardPollPolicy.maximumDurationSeconds,
            accessibilityTrusted: false,
            windowVisible: true))
    }

    @Test func pollBoundsAreLightweightAndBounded() {
        #expect(RepairCardPollPolicy.intervalSeconds > 0)
        #expect(RepairCardPollPolicy.intervalSeconds < 5)
        #expect(RepairCardPollPolicy.maximumDurationSeconds >= RepairCardPollPolicy.intervalSeconds)
        #expect(RepairCardPollPolicy.maximumDurationSeconds <= 3600)
    }

    @Test func pollReattachesOnlyOnRealTrustFlip() {
        #expect(RepairCardPollPolicy.mayReattachListenerOnTrustFlip(accessibilityTrustedNow: true))
        #expect(!RepairCardPollPolicy.mayReattachListenerOnTrustFlip(accessibilityTrustedNow: false))
    }

    // MARK: - Launch readiness repair policy (unchanged semantics re-pinned)

    @Test func repairDecisionStillRequiresCompletedExplicitIntentUntrusted() {
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true,
            holdToTalkEnabledIntent: true,
            accessibilityTrustedNow: false
        ) == .repairHoldToTalkGuide)
        // Trusted now → no repair card (the live probe is the authority).
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true,
            holdToTalkEnabledIntent: true,
            accessibilityTrustedNow: true
        ) == .none)
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true,
            holdToTalkEnabledIntent: nil,
            accessibilityTrustedNow: false
        ) == .none)
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: false,
            holdToTalkEnabledIntent: true,
            accessibilityTrustedNow: false
        ) == .none)
    }

    // MARK: - QA routing (DEBUG host; ephemeral domain only)

    @Test func repairCardFixtureParsesOnlyWithDefaultsFlag() {
        #expect(QAHostRouter.repairStateFlag == "--qc-qa-repair-state")
        // Without the QA defaults flag: no QA routing at all.
        #expect(QAHostRouter.parse(arguments: ["--qc-qa-repair-state", "trustedNoListener"]) == nil)
        let config = QAHostRouter.parse(arguments: [
            "--qc-qa-defaults", "1",
            "--qc-qa-surface", "repairCard",
            "--qc-qa-repair-state", "trustedNoListener"
        ])
        #expect(config?.repairCardState == "trustedNoListener")
        #expect(config?.surface == .repairCard)
        // An unknown fixture value is carried as-is and ignored by the
        // controller's `flatMap(QARepairCardFixture.init(rawValue:))`.
        let unknown = QAHostRouter.parse(arguments: [
            "--qc-qa-defaults", "1",
            "--qc-qa-repair-state", "nonsense"
        ])
        #expect(unknown?.repairCardState == "nonsense")
    }

    @Test func repairCardDiagnosticsCopyIsPinned() {
        #expect(AccessibilityRepairStatusCopy.copyDiagnosticsAction == "Copy shortcut diagnostics")
        // The granted-listening line tells the truth about BOTH facts.
        #expect(AccessibilityRepairStatusCopy.grantedListeningLine.contains("Accessibility is on"))
        #expect(AccessibilityRepairStatusCopy.grantedListeningLine.contains("ready"))
    }

    // MARK: - QA settings-section routing (2026-11-07 review pass)

    @Test func settingsSectionFixtureParsesOnlyWithDefaultsFlag() {
        #expect(QAHostRouter.settingsSectionFlag == "--qc-qa-settings-section")
        // Without the QA defaults flag: no QA routing at all.
        #expect(QAHostRouter.parse(arguments: ["--qc-qa-settings-section", "appearance"]) == nil)
        let config = QAHostRouter.parse(arguments: [
            "--qc-qa-defaults", "1",
            "--qc-qa-surface", "settings",
            "--qc-qa-settings-section", "appearance"
        ])
        #expect(config?.settingsSection == "appearance")
        #expect(config?.surface == .settings)
        // Absent flag → nil section (production default pane).
        let plain = QAHostRouter.parse(arguments: [
            "--qc-qa-defaults", "1",
            "--qc-qa-surface", "settings"
        ])
        #expect(plain?.settingsSection == nil)
    }
}
