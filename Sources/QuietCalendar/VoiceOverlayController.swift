import AppKit
import SwiftUI
import QuietCalendarCore

/// Compact, top-center "Dynamic-Island-like" pill shown while the user holds
/// the hold-to-talk shortcut. Replaces the old behaviour of popping the full
/// capture panel on hold:
///
/// - Appears instantly on hold, on the screen under the mouse (else main).
/// - **No focus theft**: the panel is non-activating, can never become key,
///   and ignores mouse events entirely — the user keeps typing/working.
/// - States: `listening` (with REAL amplitude + genuine live partial words,
///   wrapping DOWNWARD inside a stable top-anchored frame) → `processing`
///   (phase-specific: Transcribing… / Understanding…) → hidden (the
///   existing full capture panel then presents the explicit confirmation).
/// - `blocked` shows one concise, non-technical reason (model / mic /
///   permission unavailable) and auto-dismisses — never silent.
/// - P0: `.processing` is NEVER terminal — a 95 s backstop resolves it
///   (cancelling the underlying generation via the AppDelegate) with an
///   honest Retry/Type message.
/// - Honors Reduce Motion (no expansion animation) and clamps to the visible
///   frame (menu bar / notch / multi-screen safe via `VoiceOverlayPolicy`).
///
/// ## 0.3.17 streaming-stability rework (owner-reported vertical vibration)
///
/// Root causes found in the previous implementation, all fixed here:
/// 1. `show()` replaced `panel.contentView` with a BRAND-NEW `NSHostingView`
///    on every live update (every partial word + every ~20 Hz amplitude
///    tick) — the whole AppKit view tree was rebuilt per word.
/// 2. `panel.setFrame(..., animate: true)` ran on EVERY live update, and
///    the width policy re-estimated the width from the character count per
///    word — so the top-CENTER origin (x = center − width/2) shifted per
///    word and each setFrame interrupted the previous frame animation
///    mid-flight: continuous x/y "vibration".
/// 3. The amplitude waveform changed its FONT SIZE with the live level, so
///    the (vertically centered) content row changed height at ~20 Hz — the
///    text bobbed up and down while the user spoke.
///
/// The bar now keeps ONE stable frame for the whole listening state (one
/// animated transition when the first live word arrives), the content is
/// TOP-anchored so wrapped transcript lines extend DOWNWARD without moving
/// existing lines, the waveform glyph lives in a FIXED frame (only opacity
/// follows the level), and live updates only swap the SwiftUI root value —
/// never the hosting view, never the window frame.
@MainActor
final class VoiceOverlayController {
    enum State: Equatable {
        case listening(preview: LiveVoicePreview?, amplitude: Double)
        case processing(phase: HoldProcessingPhase)
        case blocked(reason: String)
    }

    /// Compact pill base size (no preview text yet).
    private let pillWidth: Double = 260
    private let pillHeight: Double = 44
    /// Stable LISTENING frame once live words exist: up to 3 wrapped
    /// transcript lines + the "Release to finish" caption + padding. The
    /// transcript wraps DOWNWARD inside the stable width; the oldest words
    /// head-truncate so the TAIL (the latest words the user just said)
    /// stays visible.
    private let listeningExpandedHeight: Double = 88
    /// Blocked reasons self-dismiss after this long.
    private let blockedAutoDismissSeconds: TimeInterval = 4
    /// P0: hard ceiling for the visible processing state (never a default
    /// wait — first transcription pops the draft in typically < 2 s).
    private let processingBackstopSeconds: TimeInterval = ProcessingBackstopPolicy.maxProcessingSeconds

    /// The Glass slider's live value for the pill background (2026-11-07:
    /// the setting now affects the REAL voice bar, not just previews).
    /// Wired by the AppDelegate to the persisted preference; the default
    /// keeps a sensible mid value if never set.
    var glassIntensityProvider: () -> Double = { 0.65 }

    /// P0 backstop: fired by the controller when the processing state has
    /// been visible for the full backstop window. The AppDelegate cancels
    /// the underlying generation/tasks and surfaces the honest message.
    var onProcessingBackstop: (() -> Void)?

    private var panel: NSPanel?
    /// ONE hosting view for the panel's lifetime — live updates replace the
    /// SwiftUI root VALUE (an in-place diff), never the NSView tree itself.
    private var hostingView: NSHostingView<VoiceOverlayPillView>?
    private(set) var state: State?
    private var autoDismissTask: Task<Void, Never>?
    private var backstopTask: Task<Void, Never>?
    /// Visible frame the current hold is anchored to. Captured when the
    /// pill appears (or on a state-kind change) and REUSED for every live
    /// listening update — the top edge never re-anchors (or follows the
    /// mouse) mid-hold while words stream.
    private var anchoredVisibleFrame: NSRect?

    /// True while the phase-specific processing pill is visible.
    var isProcessingState: Bool {
        if case .processing = state { return true }
        return false
    }

    /// Shows (or updates) the pill on the screen under the mouse.
    func show(_ newState: State) {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        backstopTask?.cancel()
        backstopTask = nil
        let previousState = state
        state = newState

        // Anchor resolution: while the pill is visible AND the state stays
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
            pillHeight: height
        )
        let newFrame = NSRect(x: origin.x, y: origin.y, width: width, height: height)

        let panel = self.panel ?? makePanel()
        self.panel = panel

        // ONE hosting view for the panel's lifetime; updates swap the root
        // value in place (SwiftUI diffs the same view type). The NSView
        // tree, the window backing and the responder chain are never
        // rebuilt per word.
        let rootView = VoiceOverlayPillView(
            state: newState,
            glassIntensity: glassIntensityProvider(),
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
        // like compact→expanded or listening→processing) — a live word
        // update keeps the exact same frame, so nothing animates per word.
        let frameChanged = panel.frame != newFrame
        if frameChanged {
            panel.setFrame(
                newFrame,
                display: true,
                animate: !reduceMotion && panel.isVisible
            )
        }

        if !panel.isVisible {
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    panel.animator().alphaValue = 1
                }
            }
        } else if panel.alphaValue < 1 {
            // A hide() fade-out is still in flight (e.g. release → new hold
            // within the 150 ms fade). Re-target the fade so the new state is
            // actually visible instead of fading out with the old one.
            panel.animator().alphaValue = 1
        }

        switch newState {
        case .blocked:
            autoDismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(self?.blockedAutoDismissSeconds ?? 4 * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.hideIfBlocked()
            }
        case .processing:
            // P0: the pill is never a terminal state — the backstop fires
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

    /// P2 live update WHILE CAPTURING: re-renders the listening pill with
    /// the genuine partial words + real amplitude. No-op in any other
    /// state. A nil preview keeps the current words (amplitude-only
    /// update). The frame is stable across these updates by design — only
    /// the content re-renders.
    func updateLive(preview: LiveVoicePreview?, amplitude: Double) {
        guard case .listening(let currentPreview, let currentAmplitude) = state else { return }
        let newPreview = preview ?? currentPreview
        guard newPreview != currentPreview || abs(amplitude - currentAmplitude) > 0.001 else { return }
        show(.listening(preview: newPreview, amplitude: amplitude))
    }

    func hide() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        backstopTask?.cancel()
        backstopTask = nil
        state = nil
        anchoredVisibleFrame = nil
        guard let panel else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: { Task { @MainActor in
                // A newer show() may have re-used the panel (state != nil) —
                // never order it out from under a visible pill.
                guard self.state == nil, let panel = self.panel else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            } })
        }
    }

    /// A blocked pill auto-hides; listening/processing pills never do.
    private func hideIfBlocked() {
        guard case .blocked = state else { return }
        hide()
    }

    private func isListening(_ state: State) -> Bool {
        if case .listening = state { return true }
        return false
    }

    /// STABLE width (0.3.17): compact until the first live word, then the
    /// fixed screen-aware expanded width for the REST of the hold — the
    /// width no longer chases the streaming character count, so the
    /// top-center origin never shifts per word.
    private func frameWidth(for newState: State, visibleWidth: Double) -> Double {
        switch newState {
        case .listening(let preview, _):
            return VoiceBarWidthPolicy.width(
                previewCharacterCount: preview?.text.count ?? 0,
                visibleFrameWidth: visibleWidth
            )
        case .processing, .blocked:
            return pillWidth
        }
    }

    /// STABLE height: one fixed height per state. The listening state
    /// keeps ONE height for the whole hold (the compact→expanded jump
    /// happens at most ONCE, when the first live word arrives — animated
    /// as a state transition, top edge anchored, growing downward).
    private func frameHeight(for newState: State) -> Double {
        switch newState {
        case .listening(let preview, _) where preview != nil:
            return listeningExpandedHeight
        default:
            return pillHeight
        }
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
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// Phase-specific processing status (P0): never a generic "Working" for the
/// entire flow — Transcribing while inference runs, Understanding while the
/// parse pipeline runs.
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

/// The pill itself: shared glass surface (the SAME `VoiceBarSurface` the
/// Appearance preview uses — the Glass slider drives the REAL bar's
/// background), charcoal-tinted at every setting so the fixed light
/// content keeps contrast. Content is NEVER blurred — the material lives
/// on the background only.
///
/// 0.3.17 streaming stability: when `fillsFrame` is true (the overlay
/// panel), the content is TOP-LEADING anchored inside the panel's stable
/// frame — wrapped transcript lines extend DOWNWARD and existing lines
/// never shift up; the transcript is bounded to 3 lines with HEAD
/// truncation so the tail (the words the user just said) stays visible.
/// The waveform glyph sits in a FIXED 22 pt frame (only opacity follows
/// the live amplitude) so the content row's height never changes at 20 Hz.
struct VoiceOverlayPillView: View {
    var state: VoiceOverlayController.State
    /// Live Glass-slider value for the bar background (0…1).
    var glassIntensity: Double
    /// Overlay panel hosting: fill the panel's stable frame, top-leading
    /// anchored. The Appearance preview keeps the pill's intrinsic size.
    var fillsFrame: Bool = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var sage: Color { Color(red: 0.45, green: 0.62, blue: 0.52) }
    /// Fixed light content on the always-charcoal-tinted bar — legible at
    /// every glass setting, in both appearances (the tint never drops
    /// below `VoiceBarGlassPolicy.minTintAlpha`).
    private var primaryText: Color { Color.white.opacity(0.96) }
    private var secondaryText: Color { Color.white.opacity(0.68) }

    var body: some View {
        pillContent
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minWidth: 260, alignment: .leading)
            .frame(when: fillsFrame, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(VoiceBarSurface(intensity: glassIntensity, cornerRadius: 20))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var pillContent: some View {
        HStack(alignment: .top, spacing: 8) {
            switch state {
            case .listening(let preview, let amplitude):
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                    .accessibilityHidden(true)
                waveformDot(amplitude: amplitude)
                if let preview, !preview.text.isEmpty {
                    // GENUINE captured-so-far words (non-authoritative
                    // preview — the final transcript still comes from the
                    // full release transcription). Wraps DOWNWARD inside
                    // the stable width; bounded to 3 lines with the TAIL
                    // (latest words) kept visible.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preview.text)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(primaryText)
                            .lineLimit(3)
                            .truncationMode(.head)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Release to finish")
                            .font(.system(size: 10.5))
                            .foregroundStyle(secondaryText)
                    }
                } else {
                    Text("Listening…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(primaryText)
                    Spacer(minLength: 0)
                    Text("Release to finish")
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryText)
                }
            case .processing(let phase):
                ProgressView()
                    .controlSize(.small)
                Text(phase.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(primaryText)
                Spacer(minLength: 0)
            case .blocked(let reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.system(size: 12.5))
                    .foregroundStyle(primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    /// REAL amplitude waveform in a FIXED frame: the glyph's opacity (and,
    /// only when Reduce Motion is off, a layout-neutral inner scale)
    /// follows the actual microphone RMS published ~20 Hz by SpeechCapture.
    /// The frame NEVER changes size with the level — that per-tick height
    /// change is what made the old bar's text bob vertically while talking.
    @ViewBuilder
    private func waveformDot(amplitude: Double) -> some View {
        let level = min(1, max(0, amplitude))
        Image(systemName: "waveform")
            .font(.system(size: 14, weight: .medium))
            .frame(width: 22, height: 22)
            .foregroundStyle(sage.opacity(0.55 + level * 0.45))
            .animation(nil, value: level)
            .accessibilityHidden(true)
    }

    private var accessibilityText: String {
        switch state {
        case .listening(let preview, _):
            if let preview, !preview.text.isEmpty {
                return "Listening. So far: \(preview.text). Release to finish."
            }
            return "Listening. Release to finish."
        case .processing(let phase):
            return "\(phase.label.replacingOccurrences(of: "…", with: "")) your recording."
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
