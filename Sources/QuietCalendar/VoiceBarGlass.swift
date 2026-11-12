import SwiftUI
import AppKit
import QuietCalendarCore

// MARK: - Voice-bar glass (2026-11-07 owner requirement; restyled 2026-11-12)
//
// ONE preview, ONE full-size voice bar; the Glass slider applies MATERIAL
// to the bar BACKGROUND ONLY. Content (text / waveform / icons) is NEVER
// blurred. Three renderers, honestly chosen:
//
//   • macOS 26+  → native Liquid Glass (`.glassEffect(.regular, in:)`) —
//                  the real system material, not an opacity fake.
//   • macOS 14/15 → NSVisualEffectView capsule (`.hudWindow`,
//                  behind-window blending) — still a REAL material.
//   • Reduce Transparency → fully opaque scheme-solid surface — no
//                  material, contrast preserved (accessible fallback).
//
// 2026-11-12 (approved voice/glass overlay): the surface is now
// scheme-adaptive — near-white glass in Light, deep green-charcoal in
// Dark — with a thin inset top highlight (Spotlight rim), a hairline
// stroke and a soft drop shadow. The slider drives the solid tint OVER the
// material exactly like before (never below `VoiceBarGlassPolicy.minTintAlpha`).

/// REAL behind-window material fallback for pre-macOS-26 systems:
/// NSVisualEffectView masked to the bar's capsule. Never opacity-only.
struct VisualEffectCapsule: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.layer?.cornerRadius = cornerRadius
    }
}

/// The shared voice-bar BACKGROUND surface (production pill + previews use
/// the SAME component). Scheme-adaptive glass per the approved 2026-11-12
/// voice/glass design; the Glass slider drives the solid tint over the
/// real material; Reduce Transparency flattens everything to an opaque
/// scheme-coordinated solid.
struct VoiceBarSurface: View {
    var intensity: Double
    var cornerRadius: CGFloat = QuietDesign.Voice.Metric.barCorner

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tintAlpha = reduceTransparency
            ? 1.0
            : VoiceBarGlassPolicy.tintAlpha(intensity: intensity)
        ZStack {
            if reduceTransparency {
                // Accessible opaque fallback — no material, full contrast.
                shape.fill(QuietDesign.Voice.VoiceColor.reduceTransparencyFill(colorScheme))
            } else if #available(macOS 26.0, *) {
                // NATIVE Liquid Glass base — the real system material.
                shape
                    .fill(Color.clear)
                    .glassEffect(.regular, in: shape)
                // The slider's tint sits OVER the glass, BEHIND content.
                shape.fill(QuietDesign.Voice.VoiceColor.barFill(colorScheme).opacity(tintAlpha))
            } else {
                // Pre-26: REAL NSVisualEffectView capsule material.
                VisualEffectCapsule(material: .hudWindow, cornerRadius: cornerRadius)
                shape.fill(QuietDesign.Voice.VoiceColor.barFill(colorScheme).opacity(tintAlpha))
            }
            shape.strokeBorder(
                contrast == .increased
                    ? Color.primary.opacity(0.35)
                    : QuietDesign.Voice.VoiceColor.barStroke(colorScheme),
                lineWidth: contrast == .increased ? 1.5 : 1
            )
        }
        .overlay(alignment: .top) {
            // Thin soft inset highlight along the top edge (the lit rim).
            // Hidden under Reduce Transparency / Increased Contrast.
            if !reduceTransparency && contrast != .increased {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [QuietDesign.Voice.VoiceColor.barTopHighlight(colorScheme), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(height: 1.5)
                    .padding(.horizontal, 10)
                    .allowsHitTesting(false)
            }
        }
        .shadow(
            color: .black.opacity(
                reduceTransparency
                    ? (colorScheme == .dark ? 0.25 : 0.10)
                    : (colorScheme == .dark
                        ? QuietDesign.Voice.Material.shadowDarkOpacity
                        : QuietDesign.Voice.Material.shadowLightOpacity)),
            radius: QuietDesign.Voice.Material.shadowRadius,
            y: QuietDesign.Voice.Material.shadowY
        )
    }
}

/// ONE large gradient preview scene with ONE full-size voice bar — the
/// owner-approved replacement for the removed Low/Current/High tiles.
/// The sharp gradient exists ONLY inside this preview (the onboarding /
/// Settings canvas stays solid); the bar sits TOP-CENTER of the scene,
/// mirroring the real recording bar's top-center-of-screen placement.
struct VoiceBarPreviewStage: View {
    var intensity: Double
    var cornerRadius: CGFloat = QuietDesign.Voice.Metric.barCorner

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .top) {
            GlassDemoBackdrop(cornerRadius: cornerRadius + 6)
            // ONE full-size bar: the REAL production pill view itself
            // (shared background + shared content) in its listening state.
            VoiceOverlayPillView(
                state: .listening(preview: nil, amplitude: 0),
                glassIntensity: intensity
            )
            .padding(.top, 22)
            .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            reduceTransparency
                ? "Voice bar preview. Reduce Transparency is on, so the bar is solid."
                : "Voice bar preview over a colorful backdrop. Glass \(Int(min(1, max(0, intensity)) * 100)) percent — the material applies to the bar background only; text stays sharp."
        )
    }
}
