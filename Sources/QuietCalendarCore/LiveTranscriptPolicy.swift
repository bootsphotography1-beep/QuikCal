import Foundation

// MARK: - Live transcript policy (P2, 2026-11-07)
//
// Parent correction honored: the pinned helper CLI loads a COMPLETE WAV
// from a file path (exact frame count required — `drwav_init_file` +
// short-read rejection), so a live stdin PCM feed is NOT possible with the
// existing runtime. The sanctioned alternative is a BOUNDED ROLLING
// CAPTURED-SO-FAR snapshot engine: while recording, the app periodically
// transcribes the audio captured SO FAR through the EXISTING client (one
// owned helper process in flight at a time) and shows the genuine result
// as a non-authoritative live preview. Partials reach the UI WHILE
// CAPTURING; the authoritative transcript is still the full one-shot
// transcription at release (unchanged path).

/// Bounded rolling-snapshot decisions (pure, unit-testable).
public enum LiveSnapshotPolicy: Sendable {
    /// Minimum captured audio before the first snapshot (model load +
    /// a word or two — no point transcribing silence).
    public static let minCapturedSeconds: Double = 1.5
    /// Minimum NEW audio between snapshot starts (bounded engine: never a
    /// new process per 640 ms frame; one snapshot roughly every 2.5 s).
    public static let minIntervalSeconds: Double = 2.5
    /// Captured-audio ceiling for STARTING new snapshots. Beyond this the
    /// preview freezes at the last good partial (the bar keeps showing
    /// amplitude + the honest last preview) — CPU stays bounded even at
    /// the 90 s recording cap.
    public static let maxPreviewSeconds: Double = 30.0

    /// True when a new rolling snapshot should start now.
    ///
    /// - `capturedSeconds`: audio captured so far (the audio clock, not a
    ///   wall timer — pauses in mic delivery never trigger snapshots).
    /// - `lastSnapshotAtCapturedSeconds`: captured-audio clock at the last
    ///   snapshot start (nil = none yet).
    /// - `snapshotInFlight`: one owned helper process at a time — a new
    ///   snapshot is never started while one is running.
    public static func shouldStartSnapshot(
        capturedSeconds: Double,
        lastSnapshotAtCapturedSeconds: Double?,
        snapshotInFlight: Bool
    ) -> Bool {
        guard !snapshotInFlight else { return false }
        guard capturedSeconds >= minCapturedSeconds else { return false }
        guard capturedSeconds < maxPreviewSeconds else { return false }
        guard let last = lastSnapshotAtCapturedSeconds else { return true }
        return capturedSeconds - last >= minIntervalSeconds
    }
}

/// Non-authoritative live-preview state (pure, unit-testable).
///
/// Latest-wins with a revision guard: only the NEWEST started snapshot's
/// result may update the preview; an older snapshot completing late can
/// never overwrite a newer partial. The preview NEVER feeds the parser —
/// only the final validated transcript at release does (unchanged).
public struct LivePreviewState: Equatable, Sendable {
    public private(set) var text: String = ""
    public private(set) var revision: Int = 0
    public private(set) var finalized: Bool = false

    public init() {}

    /// A new snapshot started — bump the revision so older completions
    /// are dropped by `apply`.
    public mutating func beginRevision() -> Int {
        revision += 1
        return revision
    }

    /// Apply a snapshot completion. Stale revisions (an older snapshot
    /// finishing late) are discarded; empty transcripts keep the previous
    /// preview (silence mid-hold must not blank real words).
    /// Returns true when the preview actually changed.
    @discardableResult
    public mutating func apply(text: String, revision: Int) -> Bool {
        guard !finalized else { return false }
        guard revision == self.revision else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != self.text else { return false }
        self.text = trimmed
        return true
    }

    /// The authoritative final transcript arrived (release path). After
    /// this, no preview update can land — an old snapshot process can
    /// never overwrite the final text.
    public mutating func markFinalized() {
        finalized = true
    }

    /// Reset for the next capture session.
    public mutating func reset() {
        self = LivePreviewState()
    }
}

/// A live preview payload for the expanding voice bar (UI value type).
public struct LiveVoicePreview: Equatable, Sendable {
    /// Genuine captured-so-far transcript (non-authoritative).
    public var text: String
    public init(text: String) {
        self.text = text
    }
}

/// Stable voice-bar width policy (pure, unit-testable; 0.3.17 rework).
///
/// 0.3.17 root-cause fix for the streaming jitter: the bar previously
/// re-estimated its width from the live character count on EVERY partial
/// word, and the panel re-centered (animated) per word — the visible
/// "vibration". The bar now keeps ONE width for the whole listening state:
/// compact while no preview text exists, then ONE transition to a stable
/// screen-aware expanded width when the first live word arrives. The
/// transcript WRAPS DOWNWARD inside that stable width (the view bounds the
/// line count and keeps the tail — the latest words — visible); it never
/// grows across the screen and the top edge is never re-centered per word.
public enum VoiceBarWidthPolicy: Sendable {
    /// Compact pill width with no preview.
    public static let compactWidth: Double = 260
    /// Stable expanded width for the live transcript — comfortably wide for
    /// reading, small enough to stay a top-center pill on any display.
    public static let expandedWidth: Double = 520
    /// Horizontal margin kept inside the visible frame on each side
    /// (notch / multi-monitor safety — the caller passes the same
    /// `visibleFrame` width the origin policy uses).
    public static let visibleFrameHorizontalInset: Double = 16

    /// Bar width for the listening state, clamped to the visible frame.
    /// `previewCharacterCount > 0` selects the STABLE expanded width — the
    /// value is independent of how many words have streamed.
    public static func width(
        previewCharacterCount: Int,
        visibleFrameWidth: Double
    ) -> Double {
        let maxWidth = max(compactWidth, visibleFrameWidth - 2 * visibleFrameHorizontalInset)
        guard previewCharacterCount > 0 else { return min(compactWidth, maxWidth) }
        return min(max(compactWidth, expandedWidth), maxWidth)
    }
}
