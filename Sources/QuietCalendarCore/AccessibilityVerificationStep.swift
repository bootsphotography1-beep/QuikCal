import Foundation

// MARK: - Dedicated Accessibility verification step (2026-11-07 owner correction)
//
// The onboarding flow now has its OWN Accessibility permission page BEFORE
// voice practice. This file is the pure, unit-testable contract for that
// step: a small state machine driven ONLY by real probes, bounded polling
// constants, and truthful copy.
//
// Honesty rules (pinned by tests):
// - Success is claimed ONLY when the live `AXIsProcessTrusted()` probe says
//   the process is trusted. A drag ending, a drop callback, an Open
//   Settings tap, or the app regaining focus NEVER implies the grant —
//   they only cause a CHECK.
// - Polling is BOUNDED and runs ONLY while the permission step is visible.
// - The timeout never claims failure of the user — it explains the two
//   honest remaining actions (Check again, or quit + reopen after the OS
//   re-evaluates trust for the running copy).

/// Phase of the dedicated Accessibility verification step.
public enum AXPermissionStepPhase: Equatable, Sendable {
    /// Initial: nothing attempted yet this presentation.
    case idle
    /// The user tapped Open Settings or started a drag — the step is
    /// waiting for them to act in System Settings. Polling is live.
    case waiting
    /// A check is running right now (app returned, drag ended, poll
    /// tick, or explicit Check again).
    case checking
    /// The REAL probe says trusted. Terminal success.
    case granted
    /// A check ran and the probe still says untrusted. Non-terminal —
    /// the user can keep trying; polling may continue while visible.
    case notDetected
    /// The bounded wait elapsed without trust. Non-terminal — the copy
    /// explains Check again / restart; nothing is reset.
    case timedOut
}

/// Pure decision logic + pinned copy for the Accessibility verification
/// step. No AppKit, no probes — callers supply live probe results.
public enum AXPermissionStepPolicy: Sendable {
    /// Poll cadence while the step is visible (seconds).
    public static let pollIntervalSeconds: TimeInterval = 1.0
    /// Bounded poll window: the step NEVER polls forever. After this many
    /// seconds of waiting/checking without trust, the phase becomes
    /// `timedOut` and polling stops.
    public static let maxWaitSeconds: TimeInterval = 120

    /// A drag ending NEVER implies success — it only triggers a check.
    /// (The drag could have landed anywhere, or been cancelled.)
    public static func phase(afterDragEnded phase: AXPermissionStepPhase) -> AXPermissionStepPhase {
        isLive(phase) ? .checking : phase
    }

    /// Tapping Open Settings enters the bounded waiting window.
    public static func phase(afterOpenSettingsTapped phase: AXPermissionStepPhase) -> AXPermissionStepPhase {
        .waiting
    }

    /// The app became active again (user returned from System Settings) —
    /// check, never auto-success.
    public static func phase(afterAppReturned phase: AXPermissionStepPhase) -> AXPermissionStepPhase {
        isLive(phase) ? .checking : phase
    }

    /// The result of one REAL probe. The ONLY path to `.granted`.
    public static func probeResult(trusted: Bool) -> AXPermissionStepPhase {
        trusted ? .granted : .notDetected
    }

    /// Whether the phase is inside the live waiting/checking window.
    public static func isLive(_ phase: AXPermissionStepPhase) -> Bool {
        switch phase {
        case .idle, .waiting, .checking, .notDetected: return true
        case .granted, .timedOut: return false
        }
    }

    /// Whether the bounded poll should keep running for a phase + elapsed
    /// wait. Trust ends the poll (success); the bound ends it (timeout).
    public static func shouldPoll(phase: AXPermissionStepPhase, elapsedWait: TimeInterval) -> Bool {
        guard isLive(phase) else { return false }
        return elapsedWait < maxWaitSeconds
    }

    /// The bounded wait elapsed without trust → timeout (never a user
    /// failure claim; the copy explains the honest next actions).
    public static func timeoutIfNeeded(phase: AXPermissionStepPhase, elapsedWait: TimeInterval) -> AXPermissionStepPhase {
        guard isLive(phase), elapsedWait >= maxWaitSeconds else { return phase }
        return .timedOut
    }
}

/// Pinned user-facing copy for the Accessibility verification step. These
/// are the ONLY strings for the step's status lines (asserted by tests).
public enum AXPermissionStepCopy: Sendable {
    public static let stepTitle = "Accessibility"
    public static let stepSubtitle =
        "One permission lets QuikCal see the key hold. Skip anytime — typing always works."
    /// Idle (nothing attempted yet): the clear first action.
    public static let idleCopy =
        "Press Open Settings, then turn on QuikCal in Accessibility — or drag the app file into the list."
    public static let waitingCopy =
        "Waiting for permission… turn on QuikCal in Accessibility, then come back."
    public static let checkingCopy = "Checking…"
    /// Success is shown ONLY from a real trusted probe.
    public static let grantedCopy =
        "Accessibility granted — hold-to-talk is permitted on this Mac."
    public static let notDetectedCopy =
        "Still not detected. Check that QuikCal's switch is on in Accessibility, then Check again."
    /// Timeout: honest restart explanation, never a user-failure claim.
    public static let timedOutCopy =
        "Not detected after a couple of minutes. If the switch is on, quit QuikCal from the menu bar and open it again — macOS re-checks permission for the running copy. Or press Check again."
    /// Trailing honesty note on the step (drag never grants by itself).
    public static let dragDoesNotGrantNote =
        "Dragging the app file adds it to the list — you still turn on its switch yourself."
}
