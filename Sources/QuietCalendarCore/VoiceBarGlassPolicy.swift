import Foundation

// MARK: - Voice-bar glass policy (pure, unit-testable) — 2026-11-07
//
// Owner requirement (supersedes the 0.3.13 three-tile Figma comparison):
// ONE large preview with ONE full-size voice bar; the Glass slider applies
// MATERIAL to the bar BACKGROUND ONLY. Text/waveform/icons stay CRISP at
// every setting — the old tiles blurred the whole pill INCLUDING its text
// (`.blur` on the content), which is what the owner saw as "blurred bar
// letters". That blur is gone by policy: content is never blurred.
//
// Semantics of the slider: MORE glass = MORE material, LESS solid charcoal.
// The charcoal tint OVER the material decreases with intensity, but never
// below `minTintAlpha` so light content keeps contrast over any desktop.

public enum VoiceBarGlassPolicy: Sendable {

    /// Charcoal tint alpha at 0% glass (near-solid bar, least material).
    public static let maxTintAlpha: Double = 0.94
    /// Charcoal tint alpha at 100% glass (most material). Kept high enough
    /// that white pill content stays legible over any backdrop.
    public static let minTintAlpha: Double = 0.55
    /// Reduce Transparency: fully opaque accessible surface — no material,
    /// full contrast, no fake glass.
    public static let reduceTransparencyTintAlpha: Double = 0.98

    /// Charcoal tint alpha over the material base for a glass intensity.
    /// Linear, DECREASING (more glass → less solid charcoal), clamped to
    /// [0, 1] on input and [minTintAlpha, maxTintAlpha] on output.
    public static func tintAlpha(intensity: Double) -> Double {
        let i = min(1, max(0, intensity))
        let alpha = maxTintAlpha + (minTintAlpha - maxTintAlpha) * i
        return min(maxTintAlpha, max(minTintAlpha, alpha))
    }

    /// Content (text / waveform / icons) is NEVER blurred at any setting.
    public static let contentBlurRadius: Double = 0

    /// Liquid Glass is native ONLY on macOS 26+. Older systems get the
    /// NSVisualEffectView capsule fallback — a REAL behind-window material,
    /// never an opacity-only fake. Reduce Transparency always gets the
    /// opaque surface regardless of OS.
    public static func usesNativeLiquidGlass(runtimeMajorVersion: Int) -> Bool {
        runtimeMajorVersion >= 26
    }

    /// The recording bar is TOP-CENTER OF THE SCREEN in production — the
    /// preview stages it top-center INSIDE the sample scene, mirroring
    /// reality; the preview never re-centers it mid-app.
    public static let previewBarPlacementTopCenter = true
}
