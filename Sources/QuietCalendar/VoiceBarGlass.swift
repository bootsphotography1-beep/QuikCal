import SwiftUI
import AppKit
import QuietCalendarCore

// MARK: - Voice-bar glass (2026-11-07 owner requirement)
//
// ONE preview, ONE full-size voice bar; the Glass slider applies MATERIAL
// to the bar BACKGROUND ONLY. Content (text / waveform / icons) is NEVER
// blurred — the old comparison tiles blurred the whole pill including its
// letters, which is what the owner saw. Three renderers, honestly chosen:
//
//   • macOS 26+  → native Liquid Glass (`.glassEffect(.regular, in:)`) —
//                  the real system material, not an opacity fake.
//   • macOS 14/15 → NSVisualEffectView capsule (`.hudWindow`,
//                  behind-window blending) — still a REAL material.
//   • Reduce Transparency → fully opaque charcoal surface — no material,
//                  contrast preserved (accessible fallback).
//
// The charcoal tint OVER the material is what the slider drives: more
// glass → less tint (never below `VoiceBarGlassPolicy.minTintAlpha`, so
// light content keeps contrast over any backdrop).

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
/// the SAME component, so the slider affects the REAL voice bar too).
struct VoiceBarSurface: View {
    var intensity: Double
    var cornerRadius: CGFloat = 20

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// Charcoal base tone rgb(41,43,46) — the production voice-bar family.
    static let charcoal = Color(red: 0.161, green: 0.169, blue: 0.180)
    private static let sage = Color(red: 0.45, green: 0.62, blue: 0.52)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tint = reduceTransparency
            ? VoiceBarGlassPolicy.reduceTransparencyTintAlpha
            : VoiceBarGlassPolicy.tintAlpha(intensity: intensity)
        ZStack {
            if reduceTransparency {
                // Accessible opaque fallback — no material, full contrast.
                shape.fill(Self.charcoal.opacity(tint))
            } else if #available(macOS 26.0, *) {
                // NATIVE Liquid Glass base — the real system material.
                shape
                    .fill(Color.clear)
                    .glassEffect(.regular, in: shape)
                // The slider's tint sits OVER the glass, BEHIND content.
                shape.fill(Self.charcoal.opacity(tint))
            } else {
                // Pre-26: REAL NSVisualEffectView capsule material.
                VisualEffectCapsule(material: .hudWindow, cornerRadius: cornerRadius)
                shape.fill(Self.charcoal.opacity(tint))
            }
            shape.strokeBorder(
                Self.sage.opacity(0.35),
                lineWidth: contrast == .increased ? 1.5 : 1
            )
        }
    }
}

/// ONE large gradient preview scene with ONE full-size voice bar — the
/// owner-approved replacement for the removed Low/Current/High tiles.
/// The sharp gradient exists ONLY inside this preview (the onboarding /
/// Settings canvas stays solid); the bar sits TOP-CENTER of the scene,
/// mirroring the real recording bar's top-center-of-screen placement.
struct VoiceBarPreviewStage: View {
    var intensity: Double
    var cornerRadius: CGFloat = 20

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
