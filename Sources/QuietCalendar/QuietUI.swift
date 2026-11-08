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
