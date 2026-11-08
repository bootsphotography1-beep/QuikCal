import SwiftUI
import QuietCalendarCore

/// Design tokens for the launch cards (Figma 7:330 / 7:349 / 7:385).
/// Light frames pin #4e7a62 (primary), #1d8e3e (✓), #c93400 (•); surfaces
/// and borders adapt natively to light/dark Mac appearance (no theme
/// selector — per REV2.1).
enum LaunchCardTone {
    /// #4e7a62 — the deep sage primary (design 7:342/7:367/7:394).
    static let deepSage = Color(red: 0.306, green: 0.478, blue: 0.384)
    /// #1d8e3e — progress ✓ green (design 7:354/7:357).
    static let checkGreen = Color(red: 0.114, green: 0.557, blue: 0.247)
    /// #c93400 — pending • (design 7:360/7:363).
    static let pendingDot = Color(red: 0.788, green: 0.204, blue: 0.0)

    /// Card surface: native control background at the design's 0.96
    /// opacity — follows the Mac's light/dark appearance automatically.
    static let surface = Color(nsColor: .controlBackgroundColor).opacity(0.96)
    /// Hairline border ≈ the light #d8ddd6 (design 7:330), native-adapted.
    static let border = Color.primary.opacity(0.12)
}

/// The approved launch setup/resume card (design 7:330 / 7:349) rendered
/// INSIDE the existing onboarding window as its opening content for
/// launch-auto opens of an incomplete profile. Pure presentation: every
/// bullet/progress row arrives computed from live state by
/// `LaunchSetupCardPolicy`; the actions are supplied by the owner surface.
struct LaunchSetupCardView: View {
    var kind: LaunchSetupCardKind
    var onPrimary: () -> Void
    var onOpenSettings: () -> Void

    private var title: String {
        switch kind {
        case .setupNeeded: return LaunchSetupCardCopy.setupNeededTitle
        case .resume: return LaunchSetupCardCopy.resumeTitle
        }
    }

    private var subtitle: String {
        switch kind {
        case .setupNeeded: return LaunchSetupCardCopy.setupNeededSubtitle
        case .resume: return LaunchSetupCardCopy.resumeSubtitle
        }
    }

    private var primaryLabel: String {
        switch kind {
        case .setupNeeded: return LaunchSetupCardCopy.startSetupAction
        case .resume: return LaunchSetupCardCopy.resumeSetupAction
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch kind {
            case .setupNeeded(let missing):
                // Design 7:333 — 6 pt dot + 12.5 pt line, real state only.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(missing, id: \.self) { bullet in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 6, height: 6)
                            Text(bullet)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            case .resume(let progress):
                // Design 7:352 — ✓ green / • warm, 12.5 pt labels.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(progress.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            Text(row.done ? "✓" : "•")
                                .font(.system(size: row.done ? 13 : 16, weight: .medium))
                                .foregroundStyle(row.done ? LaunchCardTone.checkGreen : LaunchCardTone.pendingDot)
                                .frame(width: 10, alignment: .center)
                            Text(row.title)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Button(primaryLabel, action: onPrimary)
                    .buttonStyle(LaunchCardPrimaryButtonStyle())
                Button(LaunchSetupCardCopy.openSettingsAction, action: onOpenSettings)
                    .buttonStyle(LaunchCardSecondaryButtonStyle())
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 480, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LaunchCardTone.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LaunchCardTone.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// The approved targeted hold-guide repair card (design 7:385): compact,
/// skippable, no resets. The Accessibility chip is the LIVE
/// `AXIsProcessTrusted()` probe mirrored by the monitor — never a pref.
/// 0.3.13 follow-up: the under-chip status line separates TRUST from
/// LISTENER READINESS via `AccessibilityRepairStatusPolicy` (live inputs
/// only), and an untrusted card names the honest cause — install-first
/// for a transient (DMG) copy, possible stale entry for an installed
/// copy — instead of a bare misleading "Not yet".
struct HoldGuideRepairCardView: View {
    @ObservedObject var holdToTalk: HoldToTalkMonitor
    /// DEBUG QA fixture only (labelled in-frame); production passes nil.
    var qaRepairState: QARepairCardFixture? = nil
    var onOpenSettings: () -> Void
    var onCheckAgain: () -> Void
    var onCopyDiagnostics: () -> Void = {}
    var onSkip: () -> Void

    /// The real running-bundle payload (read-only). The DEBUG QA host may
    /// inject a location fixture via `qaAppLocation`-style args — here
    /// the card always classifies the REAL running copy, because the
    /// whole point of the honest status is naming the copy that is
    /// actually running.
    private var dragPayload: AccessibilityDragPayload {
        AccessibilityDragGuideInfo.current()
    }

    /// LIVE trust — the DEBUG fixture may simulate the
    /// trusted-but-no-listener state for a labelled screenshot only.
    private var effectiveTrusted: Bool {
#if DEBUG
        if qaRepairState == .trustedNoListener { return true }
#endif
        return holdToTalk.accessibilityTrusted
    }

    private var repairStatus: AccessibilityRepairStatus {
        AccessibilityRepairStatusPolicy.status(
            accessibilityTrusted: effectiveTrusted,
            listenerInstalled: holdToTalk.listenerInstalled,
            location: dragPayload.location
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(HoldGuideRepairCardCopy.title)
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(.primary)
#if DEBUG
                if qaRepairState != nil {
                    Text("QA fixture")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                }
#endif
            }
            Text(HoldGuideRepairCardCopy.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Design 7:389 — status row + chip (7:391). The chip mirrors
            // the LIVE probe; the line under it separates listener
            // readiness and names the honest untrusted cause.
            HStack(spacing: 10) {
                Text(HoldGuideRepairCardCopy.statusLabel)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                Text(effectiveTrusted
                     ? HoldGuideRepairCardCopy.grantedChip
                     : HoldGuideRepairCardCopy.notYetChip)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(effectiveTrusted
                                     ? LaunchCardTone.checkGreen
                                     : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(effectiveTrusted
                                  ? LaunchCardTone.checkGreen.opacity(0.12)
                                  : Color.primary.opacity(0.14))
                    )
                Spacer(minLength: 0)
            }
            Text(AccessibilityRepairStatusPolicy.statusLine(repairStatus))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(HoldGuideRepairCardCopy.openSettingsAction, action: onOpenSettings)
                    .buttonStyle(LaunchCardPrimaryButtonStyle())
                Button(HoldGuideRepairCardCopy.checkAgainAction, action: onCheckAgain)
                    .buttonStyle(LaunchCardSecondaryButtonStyle())
                Button(HoldGuideRepairCardCopy.skipForNowAction, action: onSkip)
                    .buttonStyle(LaunchCardTertiaryButtonStyle())
            }
            .padding(.top, 2)
            // Sanitized per-process diagnostics (version, running path,
            // bundle id, signature shape, live trust as this process sees
            // it, listener install state, shortcut NAME, press/release
            // COUNTS) — owner-pasteable evidence for the
            // enabled-in-Settings-but-not-here diagnosis. No secrets.
            Button(AccessibilityRepairStatusCopy.copyDiagnosticsAction, action: onCopyDiagnostics)
                .buttonStyle(LaunchCardTertiaryButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 480, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LaunchCardTone.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LaunchCardTone.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(HoldGuideRepairCardCopy.title)
    }
}

// MARK: - Card buttons (design 7:342/7:344/7:394/7:396/7:398)
// 44 pt tall, corner radius 10, 20 pt horizontal padding, 15 pt medium
// labels — matching the card designs rather than the flow's capsule pills.

private struct LaunchCardPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.85 : 1))
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LaunchCardTone.deepSage.opacity(configuration.isPressed ? 0.85 : 1))
            )
    }
}

private struct LaunchCardSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LaunchCardTone.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LaunchCardTone.border, lineWidth: 1)
            )
    }
}

private struct LaunchCardTertiaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15))
            .foregroundStyle(.secondary.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}
