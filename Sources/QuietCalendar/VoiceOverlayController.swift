import AppKit
import SwiftUI
import QuietCalendarCore

/// Compact, top-center voice/glass bar shown while the user holds the
/// hold-to-talk shortcut. 2026-11-12 (approved voice/glass overlay):
///
/// - Appears on the display under the mouse (else main), 12 pt below that
///   display's safe visible area (below the notch / menu bar).
/// - **No focus theft**: the panel is non-activating, can never become key,
///   and ignores mouse events entirely — the user keeps typing/working.
/// - **420 × 56 pt** compact surface; entry 180 ms (Y −12 → 0, opacity
///   0 → 1, no overshoot). Radius 28.
/// - States: `listening` (REAL microphone amplitude — silence NEVER
///   produces a fake pulse; genuine live partial words grow the SAME
///   surface DOWNWARD to ~138 pt (≤ 2 lines) / ~158 pt (≥ 3 lines) with the
///   top edge FIXED; the full transcript is preserved in a bounded scroll
///   region — nothing is truncated away) → `processing` (honest
///   preparation state, mic immediately off) → hidden (the capture panel
///   then presents the explicit confirmation).
/// - `blocked` shows one concise, non-technical reason and auto-dismisses —
///   never silent.
/// - P0: `.processing` is NEVER terminal — a 95 s backstop resolves it
///   (cancelling the underlying generation via the AppDelegate) with an
///   honest Retry/Type message.
/// - Reduce Motion: ~90 ms opacity-only fades — no translation, no resizing,
///   no equalizer movement. Reduce Transparency: fully opaque scheme-solid
///   surface (handled in `VoiceBarSurface`); content/contrast preserved.
/// - Light/Dark: fully adaptive via `QuietDesign.Voice` tokens.
/// - Honors Reduce Motion and clamps to the visible frame
///   (notch / multi-screen safe via `VoiceOverlayPolicy`).
@MainActor
final class VoiceOverlayController {
    enum State: Equatable {
        case listening(preview: LiveVoicePreview?, amplitude: Double)
        case processing(phase: HoldProcessingPhase)
        case blocked(reason: String)
    }

    /// Compact surface (the approved 420 × 56 geometry).
    private let pillWidth: Double = QuietDesign.Voice.Metric.listeningWidth
    private let pillHeight: Double = QuietDesign.Voice.Metric.listeningHeight
    /// Growth geometry: transcript states grow DOWNWARD, top edge fixed.
    private let transcriptTwoLineHeight: Double = QuietDesign.Voice.Metric.transcriptTwoLineHeight
    private let transcriptThreeLineHeight: Double = QuietDesign.Voice.Metric.transcriptThreeLineHeight
    /// Blocked reasons self-dismiss after this long.
    private let blockedAutoDismissSeconds: TimeInterval = 4
    /// P0: hard ceiling for the visible processing state (never a default
    /// wait — first transcription pops the draft in typically < 2 s).
    private let processingBackstopSeconds: TimeInterval = ProcessingBackstopPolicy.maxProcessingSeconds

    /// The Glass slider's live value for the bar background.
    var glassIntensityProvider: () -> Double = { 0.65 }

    /// The user's configured shortcut — displayed as the bar's key badge and
    /// release hint ("Release Fn to review" / "Release Option to review" …).
    /// Read from the same persisted preference the app uses; in the ephemeral
    /// QA domain (`--qc-qa-defaults`) the QA suite is read instead so QA
    /// fixtures never observe the owner's real toggles.
    var shortcutProvider: () -> HoldToTalkShortcutKind = {
        #if DEBUG
        let qaMode = ProcessInfo.processInfo.arguments.contains(QAHostRouter.defaultsFlag)
        let defaults = qaMode
            ? UserDefaults(suiteName: QAHostRouter.qaDefaultsSuiteName) ?? .standard
            : .standard
        #else
        let defaults = UserDefaults.standard
        #endif
        let raw = defaults.string(forKey: AppPreferenceKey.holdToTalkShortcut)
        return HoldToTalkShortcutKind(rawValue: raw ?? "") ?? .fn
    }

    /// P0 backstop: fired by the controller when the processing state has
    /// been visible for the full backstop window. The AppDelegate cancels
    /// the underlying generation/tasks and surfaces the honest message.
    var onProcessingBackstop: (() -> Void)?

    private var panel: NSPanel?
    /// ONE hosting view for the panel's lifetime; live updates swap the
    /// SwiftUI root value in place.
    private var hostingView: NSHostingView<VoiceOverlayPillView>?
    private(set) var state: State?
    private var autoDismissTask: Task<Void, Never>?
    private var backstopTask: Task<Void, Never>?
    /// The last fully-renderable state, kept so `hide()` can animate the
    /// dismiss of the CURRENT surface (Y 0 → −8 + fade) instead of cutting.
    private var dismissingState: State?
    /// Visible frame the current hold is anchored to. Captured when the
    /// pill appears (or on a state-kind change) and REUSED for every live
    /// listening update — the top edge never re-anchors (or follows the
    /// mouse) mid-hold while words stream.
    private var anchoredVisibleFrame: NSRect?

    /// True while the preparation (processing) surface is visible.
    var isProcessingState: Bool {
        if case .processing = state { return true }
        return false
    }

    /// Shows (or updates) the bar on the screen under the mouse.
    func show(_ newState: State) {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        backstopTask?.cancel()
        backstopTask = nil
        let previousState = state
        state = newState

        // Anchor resolution: while the bar is visible AND the state stays
        // `.listening` (live partials/amplitude), the previously anchored
        // visible frame is REUSED — no per-word re-anchoring, no following
        // the mouse across displays mid-hold. A fresh anchor is computed on
        // first appearance and on every state-KIND transition.
        let isLiveListeningUpdate = panel?.isVisible == true
            && previousState != nil
            && isListening(previousState!) && isListening(newState)
        let visible: NSRect
        if isLiveListeningUpdate, let anchored = anchoredVisibleFrame {
            visible = anchored
        } else {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            guard let screen else { return }
            visible = screen.visibleFrame
            anchoredVisibleFrame = visible
        }

        let width = frameWidth(for: newState, visibleWidth: Double(visible.width))
        let height = frameHeight(for: newState)
        let origin = VoiceOverlayPolicy.pillOrigin(
            visibleFrameMinX: Double(visible.origin.x),
            visibleFrameMinY: Double(visible.origin.y),
            visibleFrameWidth: Double(visible.width),
            visibleFrameHeight: Double(visible.height),
            pillWidth: width,
            pillHeight: height,
            topInset: QuietDesign.Voice.Metric.topInset
        )
        let newFrame = NSRect(x: origin.x, y: origin.y, width: width, height: height)

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let rootView = VoiceOverlayPillView(
            state: newState,
            glassIntensity: glassIntensityProvider(),
            shortcut: shortcutProvider(),
            fillsFrame: true
        )
        if let hosting = hostingView {
            hosting.rootView = rootView
        } else {
            let hosting = NSHostingView(rootView: rootView)
            panel.contentView = hosting
            hostingView = hosting
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Frame animation ONLY for real geometry changes (state transitions
        // like compact → grown transcript, or listening → processing) — a
        // live word update that keeps the same frame animates nothing.
        let frameChanged = panel.frame != newFrame
        if frameChanged {
            panel.setFrame(
                newFrame,
                display: true,
                animate: !reduceMotion && panel.isVisible
            )
        }

        if !panel.isVisible {
            panel.orderFrontRegardless()
        } else if hostingView != nil {
            // A dismiss() is still animating (e.g. release → new hold within
            // the 140 ms window). The swap to a fresh (non-dismissing) root
            // view animates the content back down into place.
        }

        switch newState {
        case .blocked:
            autoDismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(self?.blockedAutoDismissSeconds ?? 4 * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.hideIfBlocked()
            }
        case .processing:
            // P0: the bar is never a terminal state — the backstop fires
            // through the AppDelegate (which cancels the underlying work).
            let seconds = processingBackstopSeconds
            backstopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.onProcessingBackstop?()
            }
        case .listening:
            break
        }
    }

    /// P2 live update WHILE CAPTURING: re-renders the listening bar with
    /// the genuine partial words + real amplitude. No-op in any other
    /// state. A nil preview keeps the current words (amplitude-only
    /// update). The frame is stable across these updates except for the
    /// fixed compact → grown transition; nothing re-anchors mid-hold.
    func updateLive(preview: LiveVoicePreview?, amplitude: Double) {
        guard case .listening(let currentPreview, let currentAmplitude) = state else { return }
        let newPreview = preview ?? currentPreview
        guard newPreview != currentPreview || abs(amplitude - currentAmplitude) > 0.001 else { return }
        show(.listening(preview: newPreview, amplitude: amplitude))
    }

    /// Dismiss with the approved motion: 140 ms — Y 0 → −8 + fade (~90 ms
    /// opacity-only under Reduce Motion).
    func hide() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        backstopTask?.cancel()
        backstopTask = nil
        dismissingState = state
        state = nil
        anchoredVisibleFrame = nil
        guard let panel, panel.isVisible else {
            dismissingState = nil
            return
        }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? QuietDesign.Voice.Motion.fade
            : QuietDesign.Voice.Motion.dismiss
        if let hostingView, let dismissingState {
            // Swap to the same surface with `dismissing: true` — SwiftUI
            // animates Y 0 → −8 and opacity → 0 (`.animation` on the
            // modifiers). No panel-level alpha fade double-dip.
            hostingView.rootView = VoiceOverlayPillView(
                state: dismissingState,
                glassIntensity: glassIntensityProvider(),
                shortcut: shortcutProvider(),
                fillsFrame: true,
                dismissing: true
            )
        }
        let panelRef = panel
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000) + 20_000_000)
            // A newer show() may have re-used the panel — never order it
            // out from under a visible bar.
            guard self.state == nil else { return }
            panelRef.orderOut(nil)
            self.hostingView?.rootView = VoiceOverlayPillView(
                state: .listening(preview: nil, amplitude: 0),
                glassIntensity: self.glassIntensityProvider(),
                shortcut: self.shortcutProvider(),
                fillsFrame: true
            )
            self.dismissingState = nil
        }
    }

    /// A blocked bar auto-hides; listening/processing bars never do.
    private func hideIfBlocked() {
        guard case .blocked = state else { return }
        hide()
    }

    private func isListening(_ state: State) -> Bool {
        if case .listening = state { return true }
        return false
    }

    /// STABLE width (the approved 420 pt), clamped to the visible frame so
    /// the bar can never spill off a narrow display or under the notch.
    private func frameWidth(for newState: State, visibleWidth: Double) -> Double {
        let maxWidth = max(pillWidth, visibleWidth - 2 * 16)
        _ = newState
        return min(pillWidth, maxWidth)
    }

    /// STABLE height per state: 56 pt compact (listening-idle / processing /
    /// blocked); the listening state grows DOWNWARD (top edge fixed) to
    /// ~138 pt for a ≤ 2-line transcript or ~158 pt for ≥ 3 lines.
    private func frameHeight(for newState: State) -> Double {
        switch newState {
        case .listening(let preview, _):
            guard let preview, !preview.text.isEmpty else { return pillHeight }
            return estimatedTranscriptLines(preview.text) <= 2
                ? transcriptTwoLineHeight
                : transcriptThreeLineHeight
        case .processing, .blocked:
            return pillHeight
        }
    }

    /// Rough wrap estimate for SF Pro 13 pt medium in the transcript
    /// column (≈ 52 chars per line at 348 pt text width). Conservative —
    /// when in doubt the taller (3-line) height wins; content is never
    /// clipped either way (the transcript scrolls inside the fixed height).
    private func estimatedTranscriptLines(_ text: String) -> Int {
        let charsPerLine = 52
        var lines = 0
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += max(1, Int(ceil(Double(paragraph.count) / Double(charsPerLine))))
        }
        return max(1, lines)
    }

    /// Non-activating, click-through, floating — never steals focus or input.
    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the surface draws its own soft shadow
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// Phase-specific processing status (P0): honest, never a generic
/// "Working" claim. The preparation surface presents one calm status
/// ("Preparing your event…"); the phase drives VoiceOver only.
enum HoldProcessingPhase: Equatable {
    case transcribing
    case understanding

    var label: String {
        switch self {
        case .transcribing: return ProcessingBackstopPolicy.phaseLabel(isParsing: false)
        case .understanding: return ProcessingBackstopPolicy.phaseLabel(isParsing: true)
        }
    }
}

/// The bar itself: scheme-adaptive glass (`VoiceBarSurface`), mic-live
/// accents, the configured key badge, REAL amplitude equalizer, and the
/// genuine live transcript in a bounded, top-anchored scroll region.
///
/// 2026-11-12 streaming stability: content is TOP-LEADING anchored inside
/// the panel's stable frame — wrapped transcript lines extend DOWNWARD and
/// existing lines never shift up. The full transcript is preserved in a
/// bounded scroll region (never truncated, never re-anchored); the live
/// tail stays visible (auto-scrolled to the end on each update).
struct VoiceOverlayPillView: View {
    var state: VoiceOverlayController.State
    /// Live Glass-slider value for the bar background (0…1).
    var glassIntensity: Double
    /// The user's configured shortcut (key badge + release hint).
    var shortcut: HoldToTalkShortcutKind = .fn
    /// Overlay panel hosting: fill the panel's stable frame, top-leading
    /// anchored. The Appearance preview keeps the bar's intrinsic size.
    var fillsFrame: Bool = false
    /// Set by `hide()` for the 140 ms dismiss — the surface animates Y
    /// 0 → −8 + fade (opacity only under Reduce Motion).
    var dismissing: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    /// Entry animation anchor: the surface rises Y −12 → 0 + fade in.
    @State private var entered = false

    private var barWidth: CGFloat { QuietDesign.Voice.Metric.listeningWidth }
    private var compactHeight: CGFloat { QuietDesign.Voice.Metric.listeningHeight }
    private var twoLineHeight: CGFloat { QuietDesign.Voice.Metric.transcriptTwoLineHeight }
    private var threeLineHeight: CGFloat { QuietDesign.Voice.Metric.transcriptThreeLineHeight }

    #if DEBUG
    /// DEBUG-only QA override (2026-11-12): lets the labelled QA host dump
    /// specific listening fixtures without touching the AppDelegate. Never
    /// compiled into Release; the AppDelegate already labels these shots.
    private var qaPillTextOverride: String? {
        ProcessInfo.processInfo.environment["QC_QA_PILL_TEXT"]
    }
    private var qaPillAmplitudeOverride: Double? {
        ProcessInfo.processInfo.environment["QC_QA_PILL_AMPLITUDE"].flatMap(Double.init)
    }
    private var effectiveState: VoiceOverlayController.State {
        guard case .listening(let preview, let amplitude) = state else { return state }
        let overriddenPreview = qaPillTextOverride.map { LiveVoicePreview(text: $0) } ?? preview
        let overriddenAmplitude = qaPillAmplitudeOverride ?? amplitude
        return .listening(preview: overriddenPreview, amplitude: overriddenAmplitude)
    }
    #else
    private var effectiveState: VoiceOverlayController.State { state }
    #endif

    var body: some View {
        content
            .padding(.horizontal, QuietDesign.Voice.Metric.barHorizontalPadding)
            .padding(.vertical, 12)
            .frame(width: barWidth, alignment: .topLeading)
            .frame(when: fillsFrame, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(VoiceBarSurface(intensity: glassIntensity, cornerRadius: QuietDesign.Voice.Metric.barCorner))
            .offset(y: dismissing && !reduceMotion ? -8 : (entered || reduceMotion ? 0 : -12))
            .opacity(dismissing ? 0 : (entered || reduceMotion ? 1 : 0))
            .animation(reduceMotion ? .easeOut(duration: QuietDesign.Voice.Motion.fade) : .easeOut(duration: QuietDesign.Voice.Motion.entry), value: entered)
            .animation(reduceMotion ? .easeOut(duration: QuietDesign.Voice.Motion.fade) : .easeOut(duration: QuietDesign.Voice.Motion.dismiss), value: dismissing)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .onAppear {
                guard !entered else { return }
                if reduceMotion {
                    entered = true
                } else {
                    withAnimation(.easeOut(duration: QuietDesign.Voice.Motion.entry)) {
                        entered = true
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch effectiveState {
        case .listening(let preview, let amplitude):
            listeningContent(preview: preview, amplitude: amplitude)
        case .processing(let phase):
            processingContent(phase: phase)
        case .blocked(let reason):
            blockedContent(reason: reason)
        }
    }

    // MARK: Listening (the approved hold-to-talk surface)

    @ViewBuilder
    private func listeningContent(preview: LiveVoicePreview?, amplitude: Double) -> some View {
        let transcript = preview?.text ?? ""
        let hasTranscript = !transcript.isEmpty
        VStack(alignment: .leading, spacing: hasTranscript ? 8 : 0) {
            HStack(alignment: .center, spacing: 12) {
                // Live mic — recording indicator, never a static icon.
                ZStack {
                    Circle()
                        .fill(QuietDesign.Voice.VoiceColor.micLiveTint(colorScheme))
                        .frame(width: QuietDesign.Voice.Metric.micCircle,
                               height: QuietDesign.Voice.Metric.micCircle)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(QuietDesign.Voice.VoiceColor.micLiveGlyph(colorScheme))
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Listening…")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                    if !hasTranscript {
                        Text(QuietVoiceShortcutGlyph.releaseHint(shortcut))
                            .font(.system(size: 11))
                            .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    }
                }
                Spacer(minLength: 8)
                QuietVoiceEqualizer(
                    amplitude: amplitude,
                    tint: QuietDesign.Voice.VoiceColor.waveCrest(colorScheme),
                    reduceMotion: reduceMotion
                )
                QuietVoiceKeyBadge(label: QuietVoiceShortcutGlyph.badge(shortcut))
            }
            .frame(height: 32, alignment: .center)

            if hasTranscript {
                // The genuine captured-so-far words. Bounded to a scroll
                // region sized for the current growth step; the FULL text
                // is preserved (nothing truncated) and the tail stays
                // visible — auto-scrolled to the end on every live update.
                let lineCount = estimatedLines(transcript)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        Text(transcript)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 2)
                            .id("transcriptBottom")
                    }
                    .scrollIndicators(.never)
                    .frame(height: lineCount <= 2 ? 52 : 72)
                    .onChange(of: transcript) { _, _ in
                        proxy.scrollTo("transcriptBottom", anchor: .bottom)
                    }
                    .onAppear {
                        proxy.scrollTo("transcriptBottom", anchor: .bottom)
                    }
                }
                HStack {
                    Spacer(minLength: 8)
                    Text(QuietVoiceShortcutGlyph.releaseHint(shortcut))
                        .font(.system(size: 10.5))
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                }
                .frame(height: 14)
            }
        }
    }

    private func estimatedLines(_ text: String) -> Int {
        let charsPerLine = 52
        var lines = 0
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += max(1, Int(ceil(Double(paragraph.count) / Double(charsPerLine))))
        }
        return max(1, lines)
    }

    // MARK: Processing (honest preparation — mic immediately off)

    @ViewBuilder
    private func processingContent(phase: HoldProcessingPhase) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(QuietDesign.Voice.VoiceColor.preparingSage(colorScheme))
                .accessibilityHidden(true)
            Text("Preparing your event…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
            Spacer(minLength: 8)
            Text("Mic off")
                .font(.system(size: 11))
                .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
        }
        .frame(height: 32, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(phase.label.replacingOccurrences(of: "…", with: "") + ". Preparing your event.")
    }

    // MARK: Blocked (concise, honest, auto-dismisses)

    @ViewBuilder
    private func blockedContent(reason: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(QuietDesign.Voice.VoiceColor.micLiveTint(colorScheme))
                    .frame(width: QuietDesign.Voice.Metric.micCircle,
                           height: QuietDesign.Voice.Metric.micCircle)
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(QuietDesign.Voice.VoiceColor.micLiveGlyph(colorScheme))
            }
            .accessibilityHidden(true)
            Text(reason)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .frame(height: 32, alignment: .center)
    }

    private var accessibilityText: String {
        switch effectiveState {
        case .listening(let preview, _):
            if let preview, !preview.text.isEmpty {
                return "Listening. So far: \(preview.text). Release to finish."
            }
            return "Listening. \(QuietVoiceShortcutGlyph.releaseHint(shortcut))."
        case .processing(let phase):
            return phase.label.replacingOccurrences(of: "…", with: "") + ". Preparing your event."
        case .blocked(let reason):
            return reason
        }
    }
}

/// Conditional full-frame extension (SwiftUI has no optional-modifier).
private extension View {
    @ViewBuilder
    func frame(when condition: Bool, maxWidth: CGFloat, maxHeight: CGFloat, alignment: Alignment) -> some View {
        if condition {
            self.frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
        } else {
            self
        }
    }
}
