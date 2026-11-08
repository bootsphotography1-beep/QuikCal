import Foundation

// MARK: - Hold outcome policy (P0 hang fix, 2026-11-07)
//
// The stuck-"Working…" defect class (preflight DIAGNOSIS §1–2): the
// `.processing` pill had exactly two recovery signals and no timeout, and
// the begin/end hold pair was asymmetric (the pill claimed Listening before
// the ViewModel gate ran). This file is the pure, unit-testable contract for
// the typed outcomes so EVERY begin/end route — success, failure, cancel,
// gated, empty, clarification, timed out — terminates the visible
// processing state and shows the correct panel/action.

/// Typed terminal outcome of a hold-originated voice flow. Set by every
/// terminal path; nil means no hold flow is pending. The app layer observes
/// this (alongside the existing `isParsing` / `speech.$message` signals) so
/// the processing pill can never become a terminal state.
public enum HoldOutcome: Equatable, Sendable {
    /// The transcript was accepted and a parse is in flight — the parse
    /// pipeline owns the next visible transition (confirm / clarify / fail).
    case submitted
    /// The flow ended without a submittable transcript (gated begin, early
    /// failure, empty capture, requesting-race release). Honest, retryable.
    case nothingRecorded
    /// The flow ended with something the user must see in the panel
    /// (clarification, blocked destination, honest failure, backstop).
    case needsAttention(String)
}

/// Pinned user-facing copy for the hold outcome paths. These are the ONLY
/// strings for the P0 resolution paths (asserted by tests) so the pill and
/// panel never disagree.
public enum HoldOutcomeCopy: Sendable {
    /// Release entered with nothing actually recorded (begin was gated or
    /// capture already failed) — never a silent stuck bar.
    public static let nothingRecordedRetryCopy =
        "Nothing was recorded — hold a moment longer, or type below."
    /// Trusted release during the async permission/start window (the
    /// `.requesting` race): nothing was captured yet.
    public static let nothingCaughtCopy =
        "Didn't catch that — try again or type."
    /// Begin was blocked because the confirmation screen is open.
    public static let confirmOpenBlockedCopy =
        "Finish or close the current review first."
    /// 95 s processing backstop: the underlying generation was cancelled —
    /// honest retry, never a silent copy change.
    public static let backstopCopy =
        "That took too long — it was stopped. Hold to speak again, or type below."
}

/// Pure begin-decision for the hold-to-talk pill (P0 §1: symmetric begin).
public enum HoldBeginPolicy: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Capture actually started (state left `.idle` — `.requesting`
        /// counts as started). The pill may honestly claim Listening.
        case started
        /// The confirmation screen is open — no mic, no Listening claim.
        /// Show the blocked reason or bring the review forward.
        case blockedConfirmOpen
        /// Mic / model gate refused the hold (existing `VoiceOverlayPolicy.gate`).
        case blocked(String)
        /// First-hold mic prompt flow (existing 0.3.11 behavior) — the
        /// prompting hold never records.
        case micPromptPending
    }

    /// Decide the begin outcome. `captureStarted` mirrors the ViewModel's
    /// post-call speech state (`.requesting`/`.recording`/`.finishing`).
    public static func outcome(
        screenIsConfirm: Bool,
        modelReady: Bool,
        micPermissionGranted: Bool?,
        captureStarted: Bool
    ) -> Outcome {
        if screenIsConfirm {
            return .blockedConfirmOpen
        }
        switch VoiceOverlayPolicy.gate(
            modelReady: modelReady,
            micPermissionGranted: micPermissionGranted
        ) {
        case .blocked(let reason):
            return .blocked(reason)
        case .ready:
            return captureStarted ? .started : .blockedConfirmOpen
        }
    }
}

/// Pure end-decision for the hold-to-talk pill (P0 §2: every release
/// resolves). The app layer must map every outcome to a visible resolution.
public enum HoldEndPolicy: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Capture is active — the normal release: stop, transcribe, parse.
        case finishCapture
        /// Nothing was actually recording (begin gated or capture already
        /// failed). Resolve IMMEDIATELY — never show a processing pill.
        case resolveImmediately(HoldOutcome)
    }

    /// `speechState` mirrors `SpeechCapture.state` at release time.
    public static func outcome(speechStateIsIdle: Bool, speechMessagePending: Bool) -> Outcome {
        if speechStateIsIdle {
            return .resolveImmediately(.nothingRecorded)
        }
        _ = speechMessagePending // message, if any, is surfaced by the panel
        return .finishCapture
    }
}

extension HoldEndPolicy.Outcome {
    /// True when the release must resolve the pill IMMEDIATELY (no
    /// processing state may be entered).
    public var isImmediateResolution: Bool {
        if case .resolveImmediately = self { return true }
        return false
    }
}

/// Pure processing-backstop decision (P0 §4: the pill is never terminal).
///
/// Contract: the backstop is a MAXIMUM bound, not a default wait — first
/// successful transcription should pop the draft promptly (typically < 2 s
/// on the owner's hardware, probe-proven). The backstop fires only when the
/// whole release→transcribe→parse chain has produced no observable signal.
/// When it fires, the app layer CANCELS the underlying generation/tasks
/// (so a late completion can never overwrite the resolved UI) and shows an
/// honest Retry/Type message.
public enum ProcessingBackstopPolicy: Sendable {
    /// Hard ceiling for the visible processing state. Strictly above the
    /// 90 s speech-recording cap and the helper's own 90 s timeout so the
    /// backstop is a last resort, never a parallel path.
    public static let maxProcessingSeconds: TimeInterval = 95

    /// True when the backstop must fire and cancel the underlying work.
    public static func shouldFire(elapsed: TimeInterval) -> Bool {
        elapsed >= maxProcessingSeconds
    }

    /// The pill phase shown for a phase-specific, honest status — never a
    /// generic "Working" for the entire flow.
    public static func phaseLabel(isParsing: Bool) -> String {
        isParsing ? "Understanding…" : "Transcribing…"
    }
}
