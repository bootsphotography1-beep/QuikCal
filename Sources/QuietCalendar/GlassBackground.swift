import SwiftUI
import AppKit

/// Voice-glass surface for the capture/review surfaces (2026-11-12 approved
/// voice/glass design): scheme-adaptive — near-white in Light, deep
/// green-charcoal in Dark — a REAL material with a scheme tint over it, a
/// thin inset top highlight, a hairline stroke and a soft drop shadow.
/// Reduce Transparency flattens to an opaque scheme-solid; Increased
/// Contrast strengthens the stroke; content and controls stay sharp.
struct GlassBackground: View {
    var intensity: Double
    var cornerRadius: CGFloat = QuietDesign.Voice.Metric.cardCorner

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let clamped = min(1, max(0, intensity))
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if reduceTransparency {
                // Accessible opaque fallback — no material, full contrast.
                shape.fill(QuietDesign.Voice.VoiceColor.cardFill(colorScheme))
            } else {
                Rectangle().fill(.ultraThinMaterial)
                // More glass (slider) → less solid fill, same curve as the
                // voice bar; the floor keeps content contrast over any backdrop.
                shape.fill(
                    QuietDesign.Voice.VoiceColor.cardFill(colorScheme)
                        .opacity(0.55 + 0.35 * (1 - clamped))
                )
            }
        }
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(
                    contrast == .increased
                        ? Color.primary.opacity(0.35)
                        : QuietDesign.Voice.VoiceColor.cardStroke(colorScheme),
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
        }
        .overlay(alignment: .top) {
            // Thin inset top highlight (the lit rim) — hidden under Reduce
            // Transparency / Increased Contrast.
            if !reduceTransparency && contrast != .increased {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [QuietDesign.Voice.VoiceColor.barTopHighlight(colorScheme), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(height: 1.5)
                    .padding(.horizontal, 12)
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

// MARK: - Spotlight capsule glass (0.3.21 capture-bar redesign)
//
// The single-capsule capture bar's background: a REAL material with a
// scheme-coordinated tint (Spotlight-dark in dark mode, light neutral in
// light mode), a thin inset top highlight, a hairline edge, and a soft
// drop shadow — per the owner's desired screenshot. The Glass slider
// drives the tint exactly like the voice bar (more glass → less tint);
// Reduce Transparency replaces the material with a fully opaque,
// scheme-coordinated surface so contrast is preserved.

/// Spotlight-style capsule background for the capture bar.
struct SpotlightCapsuleBackground: View {
    var intensity: Double

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    /// Charcoal tone shared with the voice-pill family (VoiceBarSurface).
    private static let charcoal = Color(red: 0.161, green: 0.169, blue: 0.180)
    private static let sage = Color(red: 0.45, green: 0.62, blue: 0.52)

    var body: some View {
        let clamped = min(1, max(0, intensity))
        // Dark mode: near-Spotlight dark translucent glass. Light mode:
        // light neutral translucent glass — coordinated, never inverted.
        // More glass (user slider) → less tint, same as the voice bar.
        let tintAlpha = reduceTransparency
            ? 1.0
            : (colorScheme == .dark ? 0.55 * (1 - 0.45 * clamped) + 0.20 : 0.35 * (1 - 0.5 * clamped) + 0.35)
        ZStack {
            if reduceTransparency {
                // Accessible opaque fallback — real material flattened,
                // scheme-coordinated, full contrast.
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.ultraThinMaterial)
                (colorScheme == .dark ? Self.charcoal : Color(nsColor: .windowBackgroundColor))
                    .opacity(tintAlpha)
            }
        }
        .overlay(alignment: .top) {
            // Thin soft inset highlight along the top edge (Spotlight's
            // lit rim) — hidden under Reduce Transparency / increased
            // contrast for maximum legibility.
            if !reduceTransparency && contrast != .increased {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(colorScheme == .dark ? 0.14 : 0.45), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(height: 1.5)
                    .padding(.horizontal, 10)
                    .allowsHitTesting(false)
            }
        }
        .overlay(
            Capsule()
                .strokeBorder(
                    contrast == .increased
                        ? Color.primary.opacity(0.35)
                        : (colorScheme == .dark ? Self.sage.opacity(0.30) : Color.primary.opacity(0.10)),
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
        )
        .shadow(
            color: .black.opacity(reduceTransparency ? 0.10 : (colorScheme == .dark ? 0.30 : 0.18)),
            radius: 14, y: 6
        )
    }
}

/// Soft blue → coral → lilac scene placed **behind** a glass preview so the
/// transparency slider has a visibly distinct backdrop (not flat sage chrome).
struct GlassDemoBackdrop: View {
    var cornerRadius: CGFloat = 20
    var animate: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var drift = false

    var body: some View {
        let colors: [Color] = colorScheme == .dark
            ? [
                Color(red: 0.28, green: 0.42, blue: 0.72),
                Color(red: 0.72, green: 0.38, blue: 0.42),
                Color(red: 0.48, green: 0.36, blue: 0.72)
            ]
            : [
                Color(red: 0.55, green: 0.72, blue: 0.95),
                Color(red: 0.98, green: 0.72, blue: 0.68),
                Color(red: 0.78, green: 0.70, blue: 0.95)
            ]

        ZStack {
            if reduceTransparency {
                // Still colorful when materials are flattened — contrast for accessibility.
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.55)
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
            } else {
                LinearGradient(
                    colors: colors,
                    startPoint: drift ? .topLeading : .bottomLeading,
                    endPoint: drift ? .bottomTrailing : .topTrailing
                )
                RadialGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.12 : 0.28),
                        .clear
                    ],
                    center: .top,
                    startRadius: 4,
                    endRadius: 160
                )
                .blendMode(.plusLighter)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .onAppear {
            guard animate, !reduceMotion, !reduceTransparency else { return }
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}
