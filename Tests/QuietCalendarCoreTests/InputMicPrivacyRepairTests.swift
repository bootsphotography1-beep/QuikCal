import Testing
import Foundation
@testable import QuietCalendarCore

/// 2026-11-07 input/mic privacy repair: the REAL capability model pinned.
/// Fn/Globe is only seen globally by the listen-only CGEventTap → its
/// event DELIVERY is gated by Input Monitoring (`CGPreflightListenEventAccess`
/// / `CGRequestListenEventAccess`); tap creation succeeds untrusted and is
/// NEVER delivery proof. Other modifiers are captured by the AX-gated
/// global NSEvent monitor OR the IM-gated tap. Mic is its own
/// AVCaptureDevice authorization (hold-action only). Screen & System
/// Audio Recording is consumed by NO feature — advanced link only.
struct InputMicPrivacyRepairTests {

    // MARK: - Privacy pane deep links (validated System Settings anchors)

    @Test func privacyPaneAnchorsAreTheRealSystemSettingsAnchors() {
        // The pane anchors used by System Settings (macOS 13+). The Screen
        // pane keeps the Privacy_ScreenCapture anchor on macOS 15+ where
        // its row is renamed "Screen & System Audio Recording".
        #expect(PrivacyPaneKind.accessibility.settingsURLCandidates.contains(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))
        #expect(PrivacyPaneKind.inputMonitoring.settingsURLCandidates.contains(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"))
        #expect(PrivacyPaneKind.microphone.settingsURLCandidates.contains(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))
        #expect(PrivacyPaneKind.screenRecording.settingsURLCandidates.contains(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))
        // Every pane also carries the modern extension-variant candidate.
        for kind in PrivacyPaneKind.allCases {
            #expect(kind.settingsURLCandidates.contains { $0.contains("com.apple.settings.PrivacySecurity.extension?") })
            #expect(kind.settingsURLCandidates.count == 2)
        }
    }

    @Test func legacyAccessibilityCandidatesDelegateToTheUnifiedPaneLinks() {
        #expect(HoldToTalkGuideCopy.accessibilitySettingsURLCandidates
                == PrivacyPaneKind.accessibility.settingsURLCandidates)
    }

    @Test func screenPaneDisplayNameMatchesMacOS15RowName() {
        #expect(PrivacyPaneKind.screenRecording.paneDisplayName.contains("Screen & System Audio Recording"))
        #expect(PrivacyPaneKind.inputMonitoring.paneDisplayName == "Input Monitoring")
    }

    // MARK: - Capability model (gate on the actual required capability)

    @Test func fnRequiresInputMonitoringNotArbitraryAX() {
        #expect(HoldToTalkPermissionPolicy.requiredCapability(for: .fn) == .inputMonitoring)
        // AX alone never starts Fn monitoring — creation ≠ delivery.
        #expect(!HoldToTalkPermissionPolicy.mayStartMonitoring(
            shortcut: .fn, accessibilityTrusted: true, inputMonitoringAllowed: false))
        #expect(HoldToTalkPermissionPolicy.mayStartMonitoring(
            shortcut: .fn, accessibilityTrusted: false, inputMonitoringAllowed: true))
    }

    @Test func modifierShortcutsAcceptEitherCapability() {
        #expect(HoldToTalkPermissionPolicy.requiredCapability(for: .option) == .accessibility)
        #expect(HoldToTalkPermissionPolicy.mayStartMonitoring(
            shortcut: .option, accessibilityTrusted: true, inputMonitoringAllowed: false))
        #expect(HoldToTalkPermissionPolicy.mayStartMonitoring(
            shortcut: .option, accessibilityTrusted: false, inputMonitoringAllowed: true))
        #expect(!HoldToTalkPermissionPolicy.mayStartMonitoring(
            shortcut: .option, accessibilityTrusted: false, inputMonitoringAllowed: false))
    }

    @Test func launchRestoreGatesOnRequiredCapabilityNotAXLabel() {
        // The renamed parameter is semantic, not cosmetic: the required
        // capability (Fn → Input Monitoring) is what authorizes restore.
        #expect(HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: true, requiredCapabilityGranted: true, monitoringInstalled: false))
        #expect(!HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: true, requiredCapabilityGranted: false, monitoringInstalled: false))
        #expect(!HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: nil, requiredCapabilityGranted: true, monitoringInstalled: false))
        #expect(!HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: true, requiredCapabilityGranted: true, monitoringInstalled: true))
    }

    // MARK: - Honest copy (per-app probes; creation ≠ delivery; restart truth)

    @Test func grantedCopyNeverClaimsCreationEqualsDelivery() {
        let fn = HoldToTalkPermissionCopy.grantedStatus(for: .fn)
        #expect(fn.contains("Input Monitoring granted"))
        // The FIRST HOLD is the delivery confirmation — never the tap
        // creation succeeding.
        #expect(fn.contains("first hold confirms delivery"))
        let modifier = HoldToTalkPermissionCopy.grantedStatus(for: .option)
        #expect(modifier.contains("first hold confirms delivery"))
    }

    @Test func revokedAndBlockedStatusesNameTheActualCapability() {
        // Fn revoke names Input Monitoring — never mislabels it as AX.
        #expect(HoldToTalkPermissionCopy.revokedStatus(for: .fn).contains("Input Monitoring"))
        #expect(!HoldToTalkPermissionCopy.revokedStatus(for: .fn).contains("Accessibility access was lost"))
        #expect(HoldToTalkPermissionCopy.revokedStatus(for: .option).contains("Accessibility"))
        // Blocked start tells the user exactly which pane to open.
        #expect(HoldToTalkPermissionCopy.requiredNotGrantedStatus(for: .fn).contains("Input Monitoring"))
        #expect(HoldToTalkPermissionCopy.requiredNotGrantedStatus(for: .option).contains("Accessibility"))
        // Every blocked status keeps the typing-always-works honesty.
        for shortcut in HoldToTalkShortcutKind.allCases {
            #expect(HoldToTalkPermissionCopy.requiredNotGrantedStatus(for: shortcut).contains("typing still works"))
        }
    }

    @Test func restartNoteIsHonestAboutListenAccessChanges() {
        #expect(HoldToTalkPermissionCopy.inputMonitoringRestartNote.lowercased().contains("quit"))
        #expect(HoldToTalkPermissionCopy.inputMonitoringRestartNote.contains("newly launched event taps"))
    }

    @Test func permissionStepCopyIsCapabilityAwareAndSkippable() {
        #expect(HoldToTalkPermissionCopy.stepTitle() == "Permissions")
        // Once-only onboarding semantics preserved: skip stays offered.
        #expect(HoldToTalkPermissionCopy.stepSubtitle(for: .fn).contains("Skip"))
        #expect(HoldToTalkPermissionCopy.stepSubtitle(for: .fn).contains("Input Monitoring"))
        #expect(HoldToTalkPermissionCopy.stepSubtitle(for: .option).contains("Accessibility"))
        #expect(HoldToTalkPermissionCopy.stepSubtitle(for: .option).contains("Skip"))
    }

    @Test func micIsRequestedOnHoldOnlyNeverFromThePermissionPage() {
        #expect(HoldToTalkPermissionCopy.micRequestedOnHoldNote.contains("first hold"))
        #expect(HoldToTalkPermissionCopy.micRequestedOnHoldNote.contains("never from this page"))
    }

    @Test func screenRecordingIsHonestlyOptional() {
        // No QuikCal feature consumes screen/system audio — the note says
        // so, and nothing gates Fn/mic on screen recording.
        #expect(HoldToTalkPermissionCopy.screenRecordingNotNeededNote.contains("No QuikCal feature records"))
        #expect(HoldToTalkPermissionCopy.screenRecordingNotNeededNote.contains("microphone-only"))
    }
}
