import SwiftUI
import QuietCalendarCore

// MARK: - Shared QuikCal design tokens + integration components (0.3.16)
//
// One design language for every QuikCal surface: the onboarding REV2.1
// tokens (serif display headings, soft sage accent, deep sage primary
// fill, matte rounded surfaces that stay coordinated in light mode) are
// now shared with Settings, the confirmation card, the saved-event
// receipt, and the Google destination picker — instead of each surface
// restyling the stock Form chrome.
//
// Honesty rules carried over from the backend contracts:
// - Receipts render ONLY from `SavedEventReceipt` (confirmed persisted
//   writes); nothing here claims a save before one happened.
// - Google failure copy comes ONLY from the sanitized
//   `GoogleCalendarListFailure` category — never a guessed cause, and
//   `.apiNotEnabled` names the OWNER action (Cloud Console), never a
//   pretend fix from inside the app.

// MARK: - 2026-11-12 onboarding redesign — shared design tokens (phase 1)
//
// The approved 2026-11-12 macOS onboarding redesign (Figma page 49:2, main
// board 49:66, supporting board 54:222) replaces the old serif display
// voice with SF Pro system type, neutral native surfaces, and the existing
// sage accent. These tokens are the SHARED foundation for the redesigned
// onboarding surfaces (phase 1) and the voice/glass overlay (phase 2).
//
// Light/Dark contract: every color resolves through `QuietDesign.Color`
// with a `ColorScheme` argument. Never hardcode a light or dark value at a
// call site — the resolved value is what keeps a surface coordinated when
// the Mac's appearance changes. The values are sampled from the approved
// Figma PNGs (archived 2026-11-12 macOS-onboarding design-review captures).
//
// Reduce Motion: `QuietDesign.Motion.fadeDuration` (~90 ms) is the
// fade-only duration. Callers opt out of movement transitions via the
// `accessibilityReduceMotion` environment value; no token here invents a
// movement curve.
//
// `QuietPalette` (below) stays as the legacy accent/primary API used by
// Settings, Capture, and the receipt cards — the new tokens are additive
// and keep its semantics.

/// Semantic design tokens for the approved onboarding redesign.
enum QuietDesign {

    /// SF Pro system type scale — named text styles only (Dynamic Type).
    enum Typography {
        /// Welcome display heading (design ~32 pt; `.largeTitle` = 34).
        static let display = SwiftUI.Font.largeTitle
        /// Section heading (design 28 pt).
        static let title = SwiftUI.Font.title
        /// Card / row title (design ~16 pt semibold; `.headline` = 17).
        static let cardTitle = SwiftUI.Font.headline
        /// Body text (17 pt).
        static let body = SwiftUI.Font.body
        /// Card subtitle (design ~13–15 pt; `.subheadline` = 15).
        static let subtitle = SwiftUI.Font.subheadline
        /// Caption (design ~12 pt).
        static let caption = SwiftUI.Font.caption
        /// Meta / micro label (design ~11 pt).
        static let meta = SwiftUI.Font.caption2
    }

    /// Semantic colors, resolved per `ColorScheme`.
    enum Color {
        /// Soft sage — rings, icons, checkmarks, selected labels.
        static let accent = QuietPalette.accent
        /// Deep sage #4e7a62 — the only white-text fill (AA).
        static let primaryFill = QuietPalette.primaryFill
        /// Success green #1d8e3e (progress ✓ / "Ready").
        static let success = SwiftUI.Color(red: 0.114, green: 0.557, blue: 0.247)
        /// Warning #c93400 (honest attention, never a user-failure claim).
        static let warning = SwiftUI.Color(red: 0.788, green: 0.204, blue: 0.0)
        /// Warning card tint. Light #FFF6E8 / Dark #3C3225 — sampled from
        /// the approved calendar-error frames.
        static func warningFill(_ scheme: ColorScheme) -> SwiftUI.Color {
            scheme == .dark
                ? SwiftUI.Color(red: 0.235, green: 0.196, blue: 0.145)
                : SwiftUI.Color(red: 1.0, green: 0.965, blue: 0.910)
        }
        /// Warning card hairline — the warning hue at low opacity.
        static func warningStroke(_ scheme: ColorScheme) -> SwiftUI.Color {
            warning.opacity(scheme == .dark ? 0.38 : 0.30)
        }

        /// Root window background. Light #F8FAF9 / Dark #202423.
        static func background(_ scheme: ColorScheme) -> SwiftUI.Color {
            scheme == .dark
                ? SwiftUI.Color(red: 0.125, green: 0.141, blue: 0.137)
                : SwiftUI.Color(red: 0.973, green: 0.980, blue: 0.976)
        }

        /// Title-bar strip. Light #F0F3F1 / Dark #282D2B.
        static func titleBar(_ scheme: ColorScheme) -> SwiftUI.Color {
            scheme == .dark
                ? SwiftUI.Color(red: 0.157, green: 0.176, blue: 0.169)
                : SwiftUI.Color(red: 0.941, green: 0.953, blue: 0.945)
        }

        /// Card surface. Light #FFFFFF / Dark #2A302D.
        static func card(_ scheme: ColorScheme) -> SwiftUI.Color {
            scheme == .dark
                ? SwiftUI.Color(red: 0.165, green: 0.188, blue: 0.176)
                : .white
        }

        /// Card hairline. Light #E4E9E5 / Dark #3A423E.
        static func cardStroke(_ scheme: ColorScheme) -> SwiftUI.Color {
            scheme == .dark
                ? SwiftUI.Color(red: 0.227, green: 0.259, blue: 0.239)
                : SwiftUI.Color(red: 0.894, green: 0.914, blue: 0.898)
        }

        /// Selected / current fill. Light #E9F2ED / Dark #283E32.
        static func selectedFill(_ scheme: ColorScheme) -> SwiftUI.Color {
            scheme == .dark
                ? SwiftUI.Color(red: 0.157, green: 0.243, blue: 0.196)
                : SwiftUI.Color(red: 0.914, green: 0.949, blue: 0.929)
        }

        /// Selected border — the deep sage in dark, a soft sage in light.
        static func selectedStroke(_ scheme: ColorScheme) -> SwiftUI.Color {
            scheme == .dark
                ? SwiftUI.Color(red: 0.306, green: 0.478, blue: 0.384)
                : QuietPalette.accent.opacity(0.45)
        }

        /// Idle step circle / neutral pill fill.
        /// Light #EEF3F0 / Dark #303B34.
        static func pillIdle(_ scheme: ColorScheme) -> SwiftUI.Color {
            scheme == .dark
                ? SwiftUI.Color(red: 0.188, green: 0.231, blue: 0.204)
                : SwiftUI.Color(red: 0.933, green: 0.953, blue: 0.941)
        }

        /// Hairline separator. Light #E4E9E5 / Dark #3A423E.
        static func separator(_ scheme: ColorScheme) -> SwiftUI.Color {
            scheme == .dark
                ? SwiftUI.Color(red: 0.227, green: 0.259, blue: 0.239)
                : SwiftUI.Color(red: 0.894, green: 0.914, blue: 0.898)
        }

        /// Primary label. Light #1D1F1C / Dark #F2F5F3.
        static func labelPrimary(_ scheme: ColorScheme) -> SwiftUI.Color {
            scheme == .dark
                ? SwiftUI.Color(red: 0.949, green: 0.961, blue: 0.953)
                : SwiftUI.Color(red: 0.114, green: 0.122, blue: 0.110)
        }

        /// Secondary label. Light #6E756F / Dark #A9B1AC.
        static func labelSecondary(_ scheme: ColorScheme) -> SwiftUI.Color {
            scheme == .dark
                ? SwiftUI.Color(red: 0.663, green: 0.694, blue: 0.675)
                : SwiftUI.Color(red: 0.431, green: 0.459, blue: 0.435)
        }

        /// Tertiary label. Light #9AA19C / Dark #7C847F.
        static func labelTertiary(_ scheme: ColorScheme) -> SwiftUI.Color {
            scheme == .dark
                ? SwiftUI.Color(red: 0.486, green: 0.518, blue: 0.498)
                : SwiftUI.Color(red: 0.604, green: 0.631, blue: 0.612)
        }
    }

    /// Layout metrics (points).
    enum Metric {
        /// Max width of the left-aligned content column.
        static let contentWidth: CGFloat = 440
        /// Horizontal padding around the content column.
        static let contentPadding: CGFloat = 40
        /// Horizontal padding of the bottom bar / title bar.
        static let chromePadding: CGFloat = 28
        /// Title-bar height.
        static let titleBarHeight: CGFloat = 52
        /// Bottom bar height.
        static let bottomBarHeight: CGFloat = 80
        /// Space between the title bar and the step indicator.
        static let stepTopPadding: CGFloat = 20
        /// Card corner radius.
        static let cardCorner: CGFloat = 12
        /// Step circle diameter.
        static let circleSize: CGFloat = 24
        /// Large practice keycap side.
        static let keycapSide: CGFloat = 72
        /// Small keycap side (welcome row).
        static let keycapSmallSide: CGFloat = 32
    }

    /// Motion durations (seconds).
    enum Motion {
        /// Standard step transition.
        static let stepDuration: Double = 0.28
        /// Reduce Motion fade-only duration (~90 ms).
        static let fadeDuration: Double = 0.09
    }
}

/// Neutral card surface shared by the redesigned onboarding screens.
/// `selected` swaps the fill/border to the sage selection tokens.
struct QuietCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var selected: Bool = false
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: QuietDesign.Metric.cardCorner, style: .continuous)
                    .fill(selected
                          ? QuietDesign.Color.selectedFill(colorScheme)
                          : QuietDesign.Color.card(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: QuietDesign.Metric.cardCorner, style: .continuous)
                    .strokeBorder(selected
                                   ? QuietDesign.Color.selectedStroke(colorScheme)
                                   : QuietDesign.Color.cardStroke(colorScheme),
                                   lineWidth: 1)
            )
    }
}

/// The three-step onboarding indicator (Calendar · Voice access · Try it).
/// `currentIndex` is 0-based; indices below it render a sage check, the
/// current index renders the sage number/label, the rest render a neutral
/// number/label. Pure presentation — the flow owner supplies the state.
struct QuietStepIndicator: View {
    @Environment(\.colorScheme) private var colorScheme
    let steps: [String]
    let currentIndex: Int

    var body: some View {
        HStack(spacing: 20) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, label in
                HStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .fill(index == currentIndex
                                  ? QuietDesign.Color.selectedFill(colorScheme)
                                  : QuietDesign.Color.pillIdle(colorScheme))
                            .frame(width: QuietDesign.Metric.circleSize,
                                   height: QuietDesign.Metric.circleSize)
                        if index < currentIndex {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(QuietDesign.Color.accent)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(index == currentIndex
                                                 ? QuietDesign.Color.accent
                                                 : QuietDesign.Color.labelSecondary(colorScheme))
                        }
                    }
                    Text(label)
                        .font(.system(size: 13,
                                      weight: index == currentIndex ? .semibold : .regular))
                        .foregroundStyle(index == currentIndex
                                         ? QuietDesign.Color.accent
                                         : QuietDesign.Color.labelSecondary(colorScheme))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(label), \(stateLabel(index))")
            }
        }
    }

    private func stateLabel(_ index: Int) -> String {
        if index < currentIndex { return "completed" }
        if index == currentIndex { return "current step" }
        return "upcoming"
    }
}

/// The hold-to-talk keycap. `state` is the real monitor-derived state (never
/// a timer or button press); Reduce Motion drops the lift but keeps the
/// red fill. `subtitle` ("Hold to speak") shows only in the large size.
struct QuietKeyCap: View {
    @Environment(\.colorScheme) private var colorScheme
    var keyLabel: String
    var subtitle: String? = nil
    var state: OnboardingVoiceVisualPolicy.PracticeKeyState = .neutral
    var reduceMotion: Bool = false
    var size: QuietKeyCapSize = .large

    enum QuietKeyCapSize {
        case small
        case large
    }

    private static let holdingRed = SwiftUI.Color(red: 0.843, green: 0.0, blue: 0.082)

    var body: some View {
        let isHolding = state == .holding
        let isUnavailable = state == .unavailable
        let side = size == .large ? QuietDesign.Metric.keycapSide : QuietDesign.Metric.keycapSmallSide
        let corner: CGFloat = size == .large ? 18 : 9
        VStack(spacing: size == .large ? 2 : 0) {
            Text(keyLabel)
                .font(.system(size: size == .large ? 28 : 14, weight: .semibold))
                .foregroundStyle(isHolding
                                 ? .white
                                 : (isUnavailable
                                    ? QuietDesign.Color.labelSecondary(colorScheme)
                                    : QuietDesign.Color.labelPrimary(colorScheme)))
            if size == .large, let subtitle {
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isHolding
                                     ? .white.opacity(0.85)
                                     : QuietDesign.Color.labelSecondary(colorScheme))
                    // One line, always: the cap is only 72 pt wide. If SF
                    // Pro metrics ever exceed the cap, the text shrinks
                    // (never wraps, never clips mid-word).
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: side, height: side)
        .background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(isHolding
                      ? Self.holdingRed
                      : (isUnavailable
                         ? QuietDesign.Color.pillIdle(colorScheme)
                         : QuietDesign.Color.card(colorScheme)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(QuietDesign.Color.cardStroke(colorScheme), lineWidth: 1)
        )
        .offset(y: isHolding && !reduceMotion ? -4 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hold-to-talk key \(keyLabel)")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        switch state {
        case .neutral: return "Waiting for a hold"
        case .holding: return "Holding"
        case .released: return "Released"
        case .unavailable: return "Shortcut detection is not active"
        }
    }
}

/// Pale-sage rounded-square tile with a deep-sage SF Symbol — the icon
/// container used by destination rows, permission rows, and ready marks.
struct QuietIconTile: View {
    @Environment(\.colorScheme) private var colorScheme
    var systemImage: String
    var side: CGFloat = 38

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
            .fill(QuietDesign.Color.selectedFill(colorScheme))
            .frame(width: side, height: side)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: side * 0.44, weight: .medium))
                    .foregroundStyle(QuietDesign.Color.primaryFill)
            )
            .accessibilityHidden(true)
    }
}

/// Small-caps section label ("TRY SAYING", "PRACTICE TRANSCRIPT").
/// Tracked uppercase microtype in the secondary label color.
struct QuietSectionLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
    }
}

/// Filled sage circle with a white check — the selected-option indicator
/// (calendar destination rows). Distinct from `QuietStatusChip`: this is a
/// state mark, not a text status.
struct QuietSelectionMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(QuietDesign.Color.primaryFill)
                .frame(width: 22, height: 22)
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}

/// Small status chip ("Connected", "Allowed", "Not enabled").
/// `tone` selects the semantic color; the fill is always a soft tint of it.
struct QuietStatusChip: View {
    @Environment(\.colorScheme) private var colorScheme
    var text: String
    var tone: QuietStatusTone = .neutral

    enum QuietStatusTone {
        case neutral
        case success
        case warning
    }

    private var foreground: SwiftUI.Color {
        switch tone {
        case .neutral: return QuietDesign.Color.labelSecondary(colorScheme)
        case .success: return QuietDesign.Color.accent
        case .warning: return QuietDesign.Color.warning
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(foreground.opacity(0.10))
            )
    }
}

/// The welcome app mark — a sage rounded square with a calendar glyph.
struct QuietAppMark: View {
    @Environment(\.colorScheme) private var colorScheme
    var side: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
            .fill(QuietDesign.Color.selectedFill(colorScheme))
            .frame(width: side, height: side)
            .overlay(
                Image(systemName: "calendar")
                    .font(.system(size: side * 0.42, weight: .semibold))
                    .foregroundStyle(QuietDesign.Color.primaryFill)
            )
            .accessibilityHidden(true)
    }
}

/// Shared quiet text button (onboarding-only; the primary/secondary styles
/// above stay the filled/capsule actions).
struct QuietTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary.opacity(configuration.isPressed ? 0.6 : 1))
    }
}

/// Shared product palette (onboarding `OnboardTone` values, made
/// cross-surface). The soft sage is accents/rings/checkmarks only; the
/// deep sage is the only white-text fill (AA).
enum QuietPalette {
    /// Soft sage — quiet accent for rings, icons, checkmarks.
    static let accent = Color(red: 0.45, green: 0.62, blue: 0.52)
    /// Deep sage #4e7a62 — primary fill (AA with white 15 pt medium text).
    static let primaryFill = Color(red: 0.306, green: 0.478, blue: 0.384)
    /// Matte grouped-card surface, coordinated light/dark: near-flat in
    /// light, a touch stronger in dark so cards read as matte surfaces
    /// rather than the stock flat grey Form fill.
    static func surface(colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.045)
    }

    static func surfaceStroke(colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06)
    }
}

/// Serif display heading — the onboarding scene-title voice, shared with
/// Settings pane titles so the whole app reads as one product.
struct QuietSerifHeading: View {
    var text: String
    var size: Double = 24

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .serif))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }
}

// MARK: - Shared buttons (onboarding REV2.1 primary/secondary, 0.3.20)
//
// The onboarding primary/secondary button styles made cross-surface so the
// saved/schedule screen (and future surfaces) use the SAME sage capsule
// actions as onboarding — never stock-blue bordered chrome.

/// Deep-sage capsule primary (#4e7a62, AA with white 14 pt semibold) — the
/// onboarding primary action style, made cross-surface (identical body; the
/// onboarding file's former private duplicate was removed in favor of this
/// shared one).
struct QuietPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.85 : 1))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    // Deep sage fill (#4e7a62, AA for white text). The
                    // lighter #739e85 accent stays for rings/dots/icons,
                    // never as a white-text fill.
                    .fill(isEnabled
                          ? QuietPalette.primaryFill.opacity(configuration.isPressed ? 0.75 : 1)
                          : QuietPalette.primaryFill.opacity(0.35))
            )
    }
}

/// Matte capsule secondary — the onboarding secondary action style: soft
/// primary-opacity fill, 13 pt medium label.
struct QuietSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.07))
            )
    }
}

// MARK: - Reminder lead formatting + preset picker

/// Human phrasing for a reminder lead ("1 hour 30 minutes before").
/// Pure formatting only — the backend owns validation/refusal.
enum ReminderLeadFormat {
    /// "15 minutes before", "1 hour before", "1 hour 30 minutes before",
    /// "1 day before". 0 → "at the event's start".
    static func phrase(minutes: Int) -> String {
        let m = max(0, minutes)
        if m == 0 { return "at the event's start" }
        let days = m / 1440
        let hours = (m % 1440) / 60
        let mins = (m % 1440) % 60
        var parts: [String] = []
        if days > 0 { parts.append(days == 1 ? "1 day" : "\(days) days") }
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if mins > 0 { parts.append(mins == 1 ? "1 minute" : "\(mins) minutes") }
        return parts.joined(separator: " ") + " before"
    }

    /// Card line: "Reminder: 15 minutes before".
    static func cardLine(minutes: Int?) -> String {
        minutes.map { "Reminder: \(phrase(minutes: $0))" } ?? "No reminder"
    }
}

/// Compact reminder preset menu (confirmation surfaces). Choosing a
/// preset routes through the ViewModel's explicit setters, which refuse
/// out-of-range values — this control never clamps or invents values.
/// A parsed custom lead (e.g. 90) shows its own phrase as the label and
/// simply isn't checkmarked against the presets.
struct ReminderPresetMenu: View {
    var leadMinutes: Int?
    var onPick: (Int?) -> Void

    private struct Preset: Identifiable {
        let id: Int?
        let label: String
    }

    private static let presets: [Preset] = [
        Preset(id: nil, label: "No reminder"),
        Preset(id: 5, label: "5 minutes before"),
        Preset(id: 10, label: "10 minutes before"),
        Preset(id: 15, label: "15 minutes before"),
        Preset(id: 30, label: "30 minutes before"),
        Preset(id: 60, label: "1 hour before"),
        Preset(id: 120, label: "2 hours before"),
        Preset(id: 1440, label: "1 day before")
    ]

    var body: some View {
        Menu {
            ForEach(Self.presets) { preset in
                Button {
                    onPick(preset.id)
                } label: {
                    if leadMinutes == preset.id {
                        Label(preset.label, systemImage: "checkmark")
                    } else {
                        Text(preset.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bell")
                    .font(.system(size: 11, weight: .medium))
                Text(leadMinutes.map { ReminderLeadFormat.phrase(minutes: $0) }
                     ?? "No reminder")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Reminder")
        .accessibilityValue(leadMinutes.map { ReminderLeadFormat.phrase(minutes: $0) } ?? "No reminder")
    }
}

// MARK: - Saved-event receipt (honest "saved" display)

/// One saved-event receipt card, rendered ONLY from a confirmed persisted
/// write (`SavedEventReceipt`). Google receipts carry Google's own
/// `htmlLink` — shown as a link when present; EventKit receipts have no
/// equivalent public URL and none is ever invented.
struct SavedReceiptCard: View {
    var receipt: SavedEventReceipt
    @Environment(\.colorScheme) private var colorScheme

    private var providerName: String {
        switch receipt.provider {
        case .eventKit: return "Apple Calendar"
        case .google: return "Google Calendar"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(receipt.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Label(providerName, systemImage: receipt.provider == .google ? "g.circle" : "calendar")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            Text(ConfirmationReviewFormat.dateTimeLine(start: receipt.start, end: receipt.end))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let calendar = receipt.calendarSummary, !calendar.isEmpty {
                Label(calendar, systemImage: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let location = receipt.location, !location.isEmpty {
                Label(location, systemImage: "mappin")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Description (0.3.17): the notes as ACTUALLY SAVED — the
            // receipt reflects the persisted values, wrapping fully.
            if let notes = receipt.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(ReminderLeadFormat.cardLine(minutes: receipt.reminderLeadMinutes))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let urlString = receipt.eventURL, let url = URL(string: urlString) {
                Link("View on Google Calendar", destination: url)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(QuietPalette.accent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(QuietPalette.surface(colorScheme: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(QuietPalette.surfaceStroke(colorScheme: colorScheme), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saved: \(receipt.title), \(ConfirmationReviewFormat.dateTimeLine(start: receipt.start, end: receipt.end)), \(providerName)")
    }
}

/// "Saved" section shown after a confirmed Add — the saved-event display
/// the owner asked for (the just-added event itself, never a bulk import
/// or history sync). Receipts exist only for writes that actually
/// persisted; a partial batch failure lists only the saved events.
struct SavedReceiptSection: View {
    var receipts: [SavedEventReceipt]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                receipts.count == 1 ? "Saved" : "Saved — \(receipts.count) events",
                systemImage: "checkmark.circle.fill"
            )
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(QuietPalette.primaryFill)
            ForEach(receipts) { receipt in
                SavedReceiptCard(receipt: receipt)
            }
        }
    }
}

// MARK: - Google calendar-list failure banner + destination picker

/// Actionable, categorized Google calendar-list failure banner. The copy
/// comes from the sanitized backend classification; `.apiNotEnabled`
/// explicitly names the OWNER action (Google Cloud Console) — the app
/// never pretends it can enable the API, change scopes, or load the list.
struct GoogleCalendarFailureBanner: View {
    var failure: GoogleCalendarListFailure
    var onRetry: () -> Void

    private var isOwnerAction: Bool {
        if case .apiNotEnabled = failure.category { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Google calendars could not load", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(failure.message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isOwnerAction {
                Text("This needs the Google Cloud project owner — QuikCal cannot enable the API or change scopes from here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Try again", action: onRetry)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

/// Explicit writable-calendar destination picker (onboarding + Settings
/// share the states). Distinct, honest states only — nothing here shows
/// a "connected" checkmark merely because the Google provider row is
/// selected:
/// - list loading (spinner, no auto-advance, no list yet)
/// - load failure (categorized banner + explicit retry)
/// - empty list (honest copy + explicit load action)
/// - loaded list (explicit selection ONLY — never an arbitrary default)
/// - target selected (sage readiness line naming the exact calendar)
struct GoogleDestinationPicker: View {
    @ObservedObject var googleAuth: GoogleOAuthService
    var onSelectionStateChange: (() -> Void)? = nil

    private var targetSelected: Bool {
        googleAuth.activeAccount?.targetCalendarID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if googleAuth.isFetchingCalendars {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading your calendars…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            } else if let failure = googleAuth.calendarFailure {
                GoogleCalendarFailureBanner(failure: failure) {
                    googleAuth.loadCalendars()
                }
            } else if googleAuth.calendars.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(googleAuth.calendarError ?? "No writable calendars yet.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Load calendars") { googleAuth.loadCalendars() }
                        .controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(googleAuth.calendars) { calendar in
                        Button {
                            if let account = googleAuth.activeAccount {
                                googleAuth.setTargetCalendar(
                                    accountID: account.id,
                                    calendarID: calendar.id,
                                    summary: calendar.summary
                                )
                                onSelectionStateChange?()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(calendar.summary)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                if calendar.primary {
                                    Text("primary")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                if googleAuth.activeAccount?.targetCalendarID == calendar.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(QuietPalette.accent)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.primary.opacity(
                                        googleAuth.activeAccount?.targetCalendarID == calendar.id ? 0.06 : 0.03))
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            googleAuth.activeAccount?.targetCalendarID == calendar.id ? [.isSelected] : []
                        )
                        .accessibilityLabel("Calendar \(calendar.summary)")
                    }
                }
                Text("Only calendars Google reports as writable are listed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Distinct readiness line — never a fake connected checkmark.
            if targetSelected {
                Label(
                    "Events you add will be saved to \(googleAuth.activeAccount?.targetCalendarSummary ?? "the selected calendar").",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(QuietPalette.primaryFill)
                .fixedSize(horizontal: false, vertical: true)
            } else if !googleAuth.isFetchingCalendars && googleAuth.calendarFailure == nil {
                Text("Choose a calendar, or continue and pick it later in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 2026-11-12 voice/glass overlay — additive shared tokens (phase 2)
//
// The approved 2026-11-12 voice/glass overlay (Figma page 58:2, main board
// 58:296; supporting board 59:5677; behavior handoff 59:6856) replaces the
// charcoal voice pill with a scheme-adaptive glass surface: light-near-white
// in Light appearance, deep green-charcoal in Dark. These tokens are ADDITIVE
// and shared by the production voice overlay (VoiceOverlayController), the
// capture/confirm surfaces (CaptureContentView) and the QA fixtures. Existing
// QuietDesign.* APIs are unchanged.
//
// Values were sampled from the approved exports
// (archived 2026-11-12 voice-glass design-review captures). The deep-sage
// primary fill keeps its AA contract (#4e7a62, white text); the destructive
// action uses the approved deep red #B83A42.
//
// Reduce Motion: `QuietDesign.Voice.Motion.fade` (~90 ms) is the fade-only
// duration. Motion specs never invent movement under Reduce Motion — callers
// gate translation/resize on `accessibilityReduceMotion`.
// Reduce Transparency: `voiceGlassFill` flattens to an opaque scheme-solid;
// content, contrast and controls are preserved.

extension QuietDesign {
    /// Shared tokens for the approved voice/glass overlay.
    enum Voice {

        /// Motion durations (seconds) — the approved spec.
        enum Motion {
            /// Bar entry: Y −12 → 0 + opacity 0 → 1 (no overshoot).
            static let entry: Double = 0.18
            /// Review expansion: 420×56 → 520×296, radius 28 → 24.
            static let reviewExpansion: Double = 0.24
            /// Dismiss: Y 0 → −8 + fade.
            static let dismiss: Double = 0.14
            /// Reduce Motion fade-only duration (~90 ms) — no translation,
            /// no resizing, no equalizer movement.
            static let fade: Double = QuietDesign.Motion.fadeDuration
        }

        /// Layout metrics (points) — the approved geometry.
        enum Metric {
            /// Compact listening bar: 420 × 56.
            static let listeningWidth: CGFloat = 420
            static let listeningHeight: CGFloat = 56
            /// Transcript growth (top edge fixed, grows downward).
            static let transcriptTwoLineHeight: CGFloat = 138
            static let transcriptThreeLineHeight: CGFloat = 158
            /// Review card: ~520 × 296.
            static let reviewWidth: CGFloat = 520
            static let reviewHeight: CGFloat = 296
            /// Listening bar corner radius 28; review card 24.
            static let barCorner: CGFloat = 28
            static let cardCorner: CGFloat = 24
            /// Gap below the display's safe visible area (notch / menu bar).
            static let topInset: CGFloat = 12
            /// Key-badge geometry.
            static let keyBadgeHeight: CGFloat = 22
            static let keyBadgeMinWidth: CGFloat = 26
            /// Mic-live circle in the bar.
            static let micCircle: CGFloat = 28
            /// Horizontal inner padding of the bar.
            static let barHorizontalPadding: CGFloat = 16
        }

        /// Semantic colors, resolved per `ColorScheme`.
        enum VoiceColor {

            // MARK: Bar surface (listening / preparing / saved / blocked)

            /// Bar tint over the material — sampled from the approved
            /// Listening frames (Light #EEF4F1-ish / Dark #283832-ish).
            static func barFill(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.157, green: 0.220, blue: 0.196)   // #283832
                    : SwiftUI.Color(red: 0.933, green: 0.957, blue: 0.945)   // #EEF4F1
            }

            /// Bar hairline — sage in Dark, neutral in Light.
            static func barStroke(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.243, green: 0.325, blue: 0.286)   // #3E5349
                    : SwiftUI.Color(red: 0.878, green: 0.894, blue: 0.882)   // #E0E4E1
            }

            /// Thin inset top highlight (hidden under Reduce Transparency /
            /// Increased Contrast).
            static func barTopHighlight(_ scheme: ColorScheme) -> SwiftUI.Color {
                SwiftUI.Color.white.opacity(scheme == .dark ? 0.10 : 0.55)
            }

            /// Idle (no words yet) — same glass, calmer mic tint.
            static func voicePillIdle(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.157, green: 0.220, blue: 0.196)
                    : SwiftUI.Color(red: 0.933, green: 0.957, blue: 0.945)
            }

            /// Active (genuine partial words arriving) — same fill; the mic
            /// circle carries the live state, never a second material.
            static func voicePillActive(_ scheme: ColorScheme) -> SwiftUI.Color {
                barFill(scheme)
            }

            /// Holding (key physically down, recording) — same fill; the key
            /// badge + live mic carry the holding state.
            static func voicePillHolding(_ scheme: ColorScheme) -> SwiftUI.Color {
                barFill(scheme)
            }

            /// Glass tint driven by the Glass slider (0…1): more glass →
            /// less solid fill, mirroring `VoiceBarGlassPolicy` semantics.
            /// Reduce Transparency flattens to opaque.
            static func voiceGlassFill(_ scheme: ColorScheme, transparency: Double) -> SwiftUI.Color {
                let clamped = min(1, max(0, transparency))
                let base = barFill(scheme)
                // Tint alpha follows the shared policy curve so the slider
                // behaves exactly like the existing voice bar.
                let alpha = VoiceBarGlassPolicy.tintAlpha(intensity: clamped)
                return base.opacity(alpha)
            }

            /// Opaque scheme-solid for Reduce Transparency — no material,
            /// no translucency, full contrast.
            static func reduceTransparencyFill(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.173, green: 0.224, blue: 0.200)   // solid #2C3933
                    : SwiftUI.Color(red: 0.925, green: 0.949, blue: 0.937)   // solid #ECF2EF
            }

            // MARK: Mic-live accents (real amplitude only — never faked)

            /// Mic-live circle fill. Light #FCF0EF-ish / Dark #5E3939-ish.
            static func micLiveTint(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.369, green: 0.224, blue: 0.224)   // #5E3939
                    : SwiftUI.Color(red: 0.988, green: 0.941, blue: 0.937)   // #FCF0EF
            }

            /// Mic-live glyph. Light #DC8682-ish / Dark #F0A09C-ish.
            static func micLiveGlyph(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.941, green: 0.627, blue: 0.612)   // #F0A09C
                    : SwiftUI.Color(red: 0.863, green: 0.525, blue: 0.510)   // #DC8682
            }

            /// Waveform bars — the "crest" that follows real RMS.
            /// Light #D05D58-ish / Dark #F7A2A0-ish.
            static func waveCrest(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.969, green: 0.635, blue: 0.627)   // #F7A2A0
                    : SwiftUI.Color(red: 0.816, green: 0.365, blue: 0.345)   // #D05D58
            }

            // MARK: Key badge (the configured shortcut, held)

            /// Key-badge fill. Light #F2CECD-ish / Dark #5E3939-ish.
            static func keyBadgeFill(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.369, green: 0.224, blue: 0.224)   // #5E3939
                    : SwiftUI.Color(red: 0.949, green: 0.808, blue: 0.804)   // #F2CECD
            }

            /// Key-badge glyph. Light #D6726E-ish / Dark #F0A09C-ish.
            static func keyBadgeGlyph(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.941, green: 0.627, blue: 0.612)   // #F0A09C
                    : SwiftUI.Color(red: 0.839, green: 0.447, blue: 0.431)   // #D6726E
            }

            // MARK: Card surface (review / edit / clarify / failed / delete)

            /// Card fill. Light #F2F6F4-ish / Dark #2A3732-ish.
            static func cardFill(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.165, green: 0.216, blue: 0.196)   // #2A3732
                    : SwiftUI.Color(red: 0.949, green: 0.965, blue: 0.957)   // #F2F6F4
            }

            /// Card hairline. Light #E0E7E2-ish / Dark #3B4A41-ish.
            static func cardStroke(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.231, green: 0.290, blue: 0.255)   // #3B4A41
                    : SwiftUI.Color(red: 0.878, green: 0.906, blue: 0.886)   // #E0E7E2
            }

            /// X-close button fill. Light #FFFFFF-ish / Dark #374741-ish.
            static func closeButtonFill(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.216, green: 0.278, blue: 0.255)   // #374741
                    : SwiftUI.Color(red: 1.0, green: 1.0, blue: 1.0)
            }

            // MARK: Status accents

            /// Deep red destructive action — the approved delete confirmation
            /// (#B83A42, white text; AA ≥ 5.5).
            static let deleteDestructive = SwiftUI.Color(red: 0.722, green: 0.227, blue: 0.259)

            /// Receipt check circle. Light #5D987C-ish / Dark #436152-ish.
            static func receiptCheckFill(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.263, green: 0.380, blue: 0.322)   // #436152
                    : SwiftUI.Color(red: 0.365, green: 0.596, blue: 0.486)   // #5D987C
            }

            /// Preparing/saving spinner sage. Light #69A086-ish / Dark #7FA896-ish.
            static func preparingSage(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.498, green: 0.659, blue: 0.588)   // #7FA896
                    : SwiftUI.Color(red: 0.412, green: 0.627, blue: 0.525)   // #69A086
            }

            /// Save-failure caption red.
            static let failureRed = SwiftUI.Color(red: 0.769, green: 0.231, blue: 0.227)   // #C43B3A

            /// Edit-card field fill. Light #FFFFFF-ish / Dark #303D36-ish.
            static func fieldFill(_ scheme: ColorScheme) -> SwiftUI.Color {
                scheme == .dark
                    ? SwiftUI.Color(red: 0.188, green: 0.239, blue: 0.212)   // #303D36
                    : SwiftUI.Color(red: 1.0, green: 1.0, blue: 1.0)
            }
        }

        /// Shadow + material specs for the floating glass surfaces.
        enum Material {
            /// Soft drop shadow under the bar / card (Light).
            static let shadowLightOpacity: Double = 0.22
            /// Soft drop shadow under the bar / card (Dark).
            static let shadowDarkOpacity: Double = 0.45
            /// Shadow radius / vertical offset.
            static let shadowRadius: CGFloat = 18
            static let shadowY: CGFloat = 8
        }
    }
}

/// Five-bar level indicator driven ONLY by the genuine microphone RMS the
/// capture pipeline publishes (~20 Hz). Silence renders the bars at their
/// minimum — no fake pulse, ever. Under Reduce Motion the bars render at a
/// fixed neutral height with constant opacity (no level movement).
struct QuietVoiceEqualizer: View {
    var amplitude: Double
    var tint: Color
    var reduceMotion: Bool = false

    private static let factors: [Double] = [0.55, 0.85, 1.15, 0.8, 0.6]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(Self.factors.enumerated()), id: \.offset) { index, factor in
                let level = reduceMotion ? 0.5 : min(1, max(0, amplitude))
                let height = 3 + level * 15 * factor
                Capsule(style: .continuous)
                    .fill(tint.opacity(reduceMotion ? 0.75 : (0.35 + 0.65 * level)))
                    .frame(width: 3, height: height)
            }
        }
        .frame(width: 30, height: 22, alignment: .center)
        .accessibilityHidden(true)
        .animation(nil, value: amplitude)
    }
}

/// The held-shortcut badge shown at the bar's trailing edge (e.g. `fn`,
/// `⌥`, `⌘`, `⌃`) with the configured shortcut's glyph or bare key name.
struct QuietVoiceKeyBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    var label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(QuietDesign.Voice.VoiceColor.keyBadgeGlyph(colorScheme))
            .frame(minWidth: QuietDesign.Voice.Metric.keyBadgeMinWidth, minHeight: QuietDesign.Voice.Metric.keyBadgeHeight)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(QuietDesign.Voice.VoiceColor.keyBadgeFill(colorScheme))
            )
            .accessibilityLabel("Held key")
            .accessibilityValue(label)
    }
}

/// Glyph/label for a shortcut kind, used by the overlay bar + previews.
enum QuietVoiceShortcutGlyph {
    static func badge(_ kind: HoldToTalkShortcutKind) -> String {
        switch kind {
        case .fn: return "fn"
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        }
    }

    /// "Release Fn to review" / "Release Option to review" …
    static func releaseHint(_ kind: HoldToTalkShortcutKind) -> String {
        "Release \(kind.shortName) to review"
    }
}

/// Compact glass saving bar (the approved "Adding to Calendar" state):
/// spinner + "Adding to {calendar}…" + a trailing "Saving" caption.
/// Rendered while a confirmed Add is in flight — repeated taps are gated
/// by the existing DraftSubmissionGate semantics; this surface is never a
/// cancel affordance for a submitted write.
struct VoiceSavingBar: View {
    var destination: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(QuietDesign.Voice.VoiceColor.preparingSage(colorScheme))
                .accessibilityHidden(true)
            Text("Adding to \(destination)…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("Saving")
                .font(.system(size: 11))
                .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
        }
        .padding(.horizontal, QuietDesign.Voice.Metric.barHorizontalPadding)
        .frame(height: QuietDesign.Voice.Metric.listeningHeight)
        // Fixed mid-glass intensity is intentional: these transient status
        // bars are not the interactive overlay, which follows the Settings
        // slider via glassIntensityProvider.
        .background(VoiceBarSurface(intensity: 0.65, cornerRadius: QuietDesign.Voice.Metric.barCorner))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Adding to \(destination). Saving.")
    }
}

/// Compact glass receipt bar (the approved "Added · quiet receipt" state):
/// check circle + "Added to {calendar}" + "{title} · {detail}". Rendered
/// ONLY after a CONFIRMED persisted write (receipts carry persisted
/// values) — never as a pre-save preview.
struct VoiceReceiptBar: View {
    var calendarName: String
    var title: String
    var detail: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(QuietDesign.Voice.VoiceColor.receiptCheckFill(colorScheme))
                    .frame(width: QuietDesign.Voice.Metric.micCircle,
                           height: QuietDesign.Voice.Metric.micCircle)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Added to \(calendarName)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                    .lineLimit(1)
                Text("\(title) · \(detail)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, QuietDesign.Voice.Metric.barHorizontalPadding)
        .frame(height: QuietDesign.Voice.Metric.listeningHeight)
        // Fixed mid-glass intensity is intentional (see VoiceSavingBar).
        .background(VoiceBarSurface(intensity: 0.65, cornerRadius: QuietDesign.Voice.Metric.barCorner))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Added to \(calendarName). \(title). \(detail).")
    }
}
