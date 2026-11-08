import AppKit
import SwiftUI
import AVFoundation
import QuietCalendarCore
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        viewModel: AppViewModel,
        googleAuth: GoogleOAuthService,
        holdToTalk: HoldToTalkMonitor,
        prefs: AppPreferencesStore,
        modelDownload: ParakeetModelDownloadController = .shared,
        appUpdater: AppUpdaterController,
        onReplayOnboarding: @escaping () -> Void,
        onOpenHoldGuide: @escaping () -> Void = {},
        onShowMenuBarHint: @escaping () -> Void = {}
    ) {
        let root = SettingsView(
            vm: viewModel,
            googleAuth: googleAuth,
            holdToTalk: holdToTalk,
            modelDownload: modelDownload,
            prefs: prefs,
            appUpdater: appUpdater,
            onReplayOnboarding: onReplayOnboarding,
            onOpenHoldGuide: onOpenHoldGuide,
            onShowMenuBarHint: onShowMenuBarHint
        )
        let host = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = host
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - HEX-inspired settings (QuikCal sections only)

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case calendars
    case appearance
    case speech

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .calendars: return "Calendars & Accounts"
        case .appearance: return "Appearance"
        case .speech: return "Speech & Parsing"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .calendars: return "calendar"
        case .appearance: return "circle.lefthalf.filled"
        case .speech: return "waveform"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var googleAuth: GoogleOAuthService
    @ObservedObject var holdToTalk: HoldToTalkMonitor
    @ObservedObject var modelDownload: ParakeetModelDownloadController
    var prefs: AppPreferencesStore
    @ObservedObject var appUpdater: AppUpdaterController
    var onReplayOnboarding: () -> Void
    var onOpenHoldGuide: () -> Void
    var onShowMenuBarHint: () -> Void

    @State private var pane: SettingsPane = SettingsView.qaInitialPane()
    @State private var glass: Double = 0.72
    @State private var micStatusRaw = "notDetermined"
    @State private var modelStatusText = ""
    @State private var modelActionNote: String?
    @State private var shortcutSelection: HoldToTalkShortcutKind = .fn
    /// 0.3.13 local Google client-secret import status (concise, safe text).
    @State private var googleImportStatus: String?
    @State private var isImportingGoogleConfig = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// DEBUG-only QA host routing (2026-11-07 review pass): the QA capture
    /// host can open the Settings window directly on a given section so the
    /// Appearance preview is actually captured (the previous QA shot caught
    /// the default General pane). Compiled out of Release — production
    /// always opens General.
    private static func qaInitialPane() -> SettingsPane {
#if DEBUG
        if let qa = QAHostRouter.parse(arguments: ProcessInfo.processInfo.arguments),
           let raw = qa.settingsSection,
           let pane = SettingsPane(rawValue: raw) {
            return pane
        }
#endif
        return .general
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 196)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 520)
        .background(settingsChrome)
        .onAppear {
            glass = prefs.glassIntensity
            shortcutSelection = prefs.holdToTalkShortcut
            holdToTalk.refreshPermissionFlags()
            googleAuth.reload()
            modelDownload.refresh()
            refreshSpeechStatus()
        }
    }

    private var settingsChrome: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Color(nsColor: .windowBackgroundColor).opacity(0.92)
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("QuikCal")
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ForEach(SettingsPane.allCases) { item in
                Button {
                    pane = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 18)
                        Text(item.title)
                            .font(.system(size: 13, weight: pane == item ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(pane == item ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(pane == item ? Color.primary.opacity(0.10) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text("Version \(appVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .background(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.03))
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 0.3.16 restyle: the onboarding serif display voice —
                // Settings reads as the same product, not a stock Form.
                QuietSerifHeading(text: pane.title)
                    .padding(.top, 8)

                switch pane {
                case .general:
                    generalSection
                case .calendars:
                    calendarsSection
                case .appearance:
                    appearanceSection
                case .speech:
                    speechSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: General

    /// Concise, user-facing Fn conflict helper for Settings (0.3.5).
    private var conflictHelperText: String {
        switch shortcutSelection {
        case .fn:
            return "Fn may also control macOS features. You can choose another key."
        default:
            return HoldToTalkGuideCopy.conflictExplanation(for: shortcutSelection)
        }
    }

    /// Capability chips name each permission's ACTUAL role for the
    /// selected shortcut (2026-11-07 privacy repair) — Input Monitoring
    /// is required for Fn (the listen-only key tap), Accessibility is
    /// required for other keys, and each is the alternative/optional one
    /// for the other case. Never mislabels one as the other.
    private var accessibilityRequirementChip: String {
        shortcutSelection == .fn ? "Optional" : "Required"
    }

    private var inputMonitoringRequirementChip: String {
        shortcutSelection == .fn ? "Required" : "Alternative"
    }

    private var generalSection: some View {
        VStack(spacing: 12) {
            settingsGroup {
                Text("Hold-to-talk shortcut")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                HoldShortcutGradientPicker(selection: $shortcutSelection) { kind in
                    holdToTalk.setShortcut(kind)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                Text("Hold your shortcut to speak. Release to review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)

                Text(conflictHelperText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                divider

                // Capability-aware permission rows (2026-11-07 privacy
                // repair): each row shows its OWN real per-app probe status
                // and opens its OWN pane — no blanket requests, no
                // automatic panel parade. The chips name each capability's
                // actual role for the selected shortcut (Fn → Input
                // Monitoring required; other keys → Accessibility required,
                // Input Monitoring as alternative) — never mislabeling one
                // as the other.
                settingsRow(symbol: "accessibility", title: "Accessibility") {
                    HStack(spacing: 8) {
                        statusPill(holdToTalk.accessibilityTrusted ? "Granted" : accessibilityRequirementChip)
                        Button("Open…") {
                            holdToTalk.openAccessibilitySettings()
                            // Compact drag-assist panel alongside System
                            // Settings (0.3.16) — the pane-open itself
                            // grants nothing.
                            PrivacyDragPanelPresenter.shared.present(for: .accessibility, monitor: holdToTalk)
                        }
                            .controlSize(.small)
                    }
                }
                divider
                settingsRow(symbol: "directcurrent", title: "Input Monitoring") {
                    HStack(spacing: 8) {
                        statusPill(holdToTalk.inputMonitoringAllowed ? "Granted" : inputMonitoringRequirementChip)
                        Button("Open…") {
                            holdToTalk.openInputMonitoringSettings()
                            PrivacyDragPanelPresenter.shared.present(for: .inputMonitoring, monitor: holdToTalk)
                        }
                            .controlSize(.small)
                        Button("Request…") { holdToTalk.requestInputMonitoring() }
                            .controlSize(.small)
                    }
                }
                Text(HoldToTalkPermissionCopy.requirementExplanation(for: shortcutSelection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                Text(HoldToTalkPermissionCopy.inputMonitoringRestartNote)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)

                // ADVANCED only (2026-11-07): no QuikCal feature records
                // the screen or system audio — the link is completeness,
                // never a request or a gate on Fn/mic.
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 6) {
                        settingsRow(symbol: "rectangle.on.rectangle", title: PrivacyPaneKind.screenRecording.paneDisplayName) {
                            Button("Open…") { holdToTalk.openScreenRecordingSettings() }
                                .controlSize(.small)
                        }
                        Text(HoldToTalkPermissionCopy.screenRecordingNotNeededNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

                HStack(spacing: 8) {
                    Button("Hold-to-talk setup guide…") { onOpenHoldGuide() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.45, green: 0.62, blue: 0.52))
                    Button("Enable hold-to-talk") { holdToTalk.enablePersistedMonitoring() }
                        .buttonStyle(.bordered)
                    Button("Turn off") { holdToTalk.disablePersistedMonitoring() }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

                if let status = holdToTalk.lastStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }

            settingsGroup {
                settingsRow(symbol: "arrow.counterclockwise", title: "Replay onboarding") {
                    Button("Replay…") { onReplayOnboarding() }
                        .controlSize(.small)
                }
                Text("Resets onboarding completion and the resume cursor only. Calendar, glass, shortcut, and Google links stay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                divider

                settingsRow(symbol: "point.3.connected.trianglepath.dotted", title: "Menu bar hint") {
                    Button("Show menu bar hint") { onShowMenuBarHint() }
                        .controlSize(.small)
                }
                Text("Shows the same hint as after onboarding. Dismissing it never resets setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }

            settingsGroup {
                // 0.3.19 Sparkle updates (owner-approved 2026-11-08):
                // automatic periodic CHECKS are enabled by default
                // (Info.plist SUEnableAutomaticChecks, which also suppresses
                // Sparkle's second-launch consent prompt) and NOTIFY through
                // Sparkle's native update alert. The toggle binds directly
                // to Sparkle's KVO-compliant, self-persisted
                // `automaticallyChecksForUpdates` — no separate app
                // preference is stored.
                settingsRow(symbol: "arrow.triangle.2.circlepath", title: "Automatically check for updates") {
                    Toggle("", isOn: $appUpdater.automaticallyChecksForUpdates)
                        .labelsHidden()
                        .controlSize(.small)
                }
                Text("QuikCal checks the public GitHub Releases feed about once a day (Sparkle's default cadence) and shows Sparkle's update alert when a new version is available. It only notifies — downloading, installing, and relaunching happen only when you choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                divider

                // Manual check stays available regardless of the toggle.
                // The button binds to the live `canCheckForUpdates`
                // (honestly disabled while the updater service is
                // unavailable).
                settingsRow(symbol: "arrow.down.circle", title: "Check right now") {
                    Button("Check for Updates…") { appUpdater.checkForUpdates(nil) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.45, green: 0.62, blue: 0.52))
                        .disabled(!appUpdater.canCheckForUpdates)
                }
                Text("Works even with automatic checking off. Updates are EdDSA-signed; nothing is ever downloaded, installed, or relaunched without your explicit action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }

            DisclosureGroup("Technical details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(SpeechParsingStatusCopy.accessibilityHoldNote)
                    Text("Launch at login is not offered yet (would need a real ServiceManagement action).")
                    Text("Updates: Sparkle from the public GitHub Releases appcast; automatic daily checks notify via the native update alert; installs are always explicit.")
                    Text("Event extraction uses Apple Foundation Models on-device when available. macOS manages the language model; QuikCal does not download it. Every generated draft remains editable and requires your explicit confirmation.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
    }

    // MARK: Calendars

    private var calendarsSection: some View {
        VStack(spacing: 12) {
            settingsGroup {
                settingsRow(symbol: "tray.full", title: "Write destination") {
                    Picker("", selection: Binding(
                        get: { prefs.calendarDestinationKind },
                        set: { prefs.calendarDestinationKind = $0 }
                    )) {
                        Text("Mac calendars (EventKit)").tag(CalendarDestinationKind.eventKit)
                        Text("Google").tag(CalendarDestinationKind.google)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                divider

                if prefs.calendarDestinationKind == .eventKit {
                    settingsRow(symbol: "calendar.badge.checkmark", title: "EventKit calendar") {
                        Text(eventKitStatusLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Button("Choose EventKit calendar…") {
                        vm.openOnboardingInline()
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)

                    if !vm.calendarChoices.isEmpty {
                        ForEach(vm.calendarChoices) { choice in
                            Button {
                                vm.selectCalendar(choice)
                            } label: {
                                HStack {
                                    Text(choice.displayName)
                                    Spacer()
                                    if prefs.selectedCalendarID == choice.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.bottom, 8)
                    }
                } else {
                    googleBlock
                    googleSecretImportSection
                }
            }
        }
    }

    private var eventKitStatusLabel: String {
        if let name = vm.selectionState.choice?.displayName {
            return name
        }
        switch vm.accessPhase {
        case .denied:
            return "Permission denied"
        case .granted:
            return "No calendar selected"
        case .writeOnly:
            // 2026-11-07 owner correction: a write-only grant is a real
            // connection (default calendar) — honest label, never a
            // demand for full access from the UI.
            return "Connected — add events only"
        case .notDetermined, .unknown:
            return "Not configured"
        }
    }

    /// 0.3.13: local import of the Google "Desktop app" client JSON — the
    /// OWNER picks the downloaded file (NSOpenPanel; the app never scans for
    /// or reads credentials on its own). Validation is strict + atomic: the
    /// secret only reaches the dedicated Keychain item after full validation,
    /// and failures change NOTHING (no auto sign-in, no revoke, no writes).
    @ViewBuilder
    private var googleSecretImportSection: some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Import Google configuration…") {
                    pickAndImportGoogleClientJSON()
                }
                .controlSize(.small)
                .disabled(isImportingGoogleConfig)
                if isImportingGoogleConfig {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let status = googleImportStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @MainActor
    private func pickAndImportGoogleClientJSON() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Pick the client JSON you downloaded from Google Cloud Console (Desktop app)."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.runGoogleClientJSONImport(fileURL: url)
            }
        }
    }

    /// The heavy work runs OFF the main thread (file read + strict validation
    /// + Keychain write); the main actor only applies the final status and
    /// adopts the validated secret. No file content ever reaches the UI,
    /// logs, or this status — failures show structural reasons only.
    @MainActor
    private func runGoogleClientJSONImport(fileURL url: URL) {
        isImportingGoogleConfig = true
        googleImportStatus = "Importing Google configuration…"
        let boundClientID = googleAuth.config.clientID
        let service = GoogleClientSecretImportService(
            persisting: KeychainGoogleClientSecretStore()
        )
        Task.detached(priority: .utility) {
            let result: Result<ImportedGoogleClientConfiguration, Error> = {
                do {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    let imported = try service.importConfiguration(
                        fileData: data, boundClientID: boundClientID)
                    return .success(imported)
                } catch {
                    return .failure(error)
                }
            }()
            await MainActor.run {
                self.isImportingGoogleConfig = false
                switch result {
                case .success(let imported):
                    self.googleAuth.adoptClientSecret(imported.clientSecret)
                    self.googleImportStatus = "Imported Google configuration — client matches the bundled app. Press “Sign in with Google…” to connect."
                case .failure(let error):
                    // Structural reason only — never file content, never the
                    // secret or client id.
                    self.googleImportStatus = (error as? GoogleClientSecretImportError)?
                        .errorDescription ?? "The Google configuration file could not be imported (unexpected format)."
                }
            }
        }
    }

    @ViewBuilder
    private var readinessStatusBlock: some View {
        let readiness = googleAuth.destinationReadiness
        VStack(alignment: .leading, spacing: 6) {
            switch readiness {
            case .ready(_, _, let summary):
                Label("Ready — confirmed Adds write to \(summary) (Google).",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .notReady(let block):
                Label(block.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(block.requiresReauthentication ? .orange : .secondary)
                if block.requiresReauthentication {
                    Button("Sign in again") { googleAuth.beginSignIn() }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var googleBlock: some View {
        switch googleAuth.phase {
        case .unconfigured:
            VStack(alignment: .leading, spacing: 6) {
                Text("Unconfigured — a Google Cloud Desktop OAuth client ID is required.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("This build’s Info.plist is missing GoogleDesktopOAuthClientID. Rebuild with the owner-supplied public Desktop client ID, or set the QUIET_CALENDAR_GOOGLE_CLIENT_ID environment override before launching. No redirect URI registration is needed — Google accepts loopback (127.0.0.1) redirects on any port. Steps: GOOGLE-CALENDAR-INTEGRATION.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        case .signedOut, .error:
            Button("Sign in with Google…") { googleAuth.beginSignIn() }
                .controlSize(.small)
                .padding(14)
        case .authorizing:
            ProgressView("Waiting for browser…")
                .padding(14)
            Button("Cancel") { googleAuth.cancelSignIn() }
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        case .signedIn:
            ForEach(googleAuth.directory.accounts) { account in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.email)
                        // Distinct account-connected state — a connected
                        // account is not a ready destination; the list /
                        // target states below carry their own lines.
                        Text("Account connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect") { googleAuth.disconnect(accountID: account.id) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            // 0.3.16: a categorized calendar-list failure gets the
            // actionable banner (sanitized backend classification; the
            // `.apiNotEnabled` copy names the OWNER action in Google
            // Cloud Console — the app never pretends it can enable the
            // API or load the list). The generic readiness block covers
            // every other state so the same reason is never shown twice.
            if let failure = googleAuth.calendarFailure {
                GoogleCalendarFailureBanner(failure: failure) {
                    googleAuth.loadCalendars()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            } else {
                // Live readiness of confirmed Adds — derived from the real
                // account/token/calendar state, shown so the owner can see
                // exactly what (if anything) still blocks Add.
                readinessStatusBlock
            }

            divider

            // Target calendar selection — writable calendars only.
            HStack {
                Text("Target calendar")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(googleAuth.isFetchingCalendars ? "Loading…" : "Refresh calendars") {
                    googleAuth.loadCalendars()
                }
                .controlSize(.small)
                .disabled(googleAuth.isFetchingCalendars)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if googleAuth.isFetchingCalendars {
                // Distinct list-loading state (spinner + label — the
                // destination is NOT ready while the list is pending).
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading calendars…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            } else if googleAuth.calendarFailure != nil {
                // The banner above carries the failure + retry — nothing
                // more is duplicated here.
                EmptyView()
            } else if googleAuth.calendars.isEmpty {
                Text(googleAuth.calendarError ?? "No calendars loaded yet — press Refresh calendars.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else {
                ForEach(googleAuth.calendars) { calendar in
                    Button {
                        if let account = googleAuth.activeAccount {
                            googleAuth.setTargetCalendar(
                                accountID: account.id,
                                calendarID: calendar.id,
                                summary: calendar.summary
                            )
                        }
                    } label: {
                        HStack {
                            Text(calendar.summary)
                                .lineLimit(1)
                            if calendar.primary {
                                Text("primary")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if googleAuth.activeAccount?.targetCalendarID == calendar.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
                Text("Only calendars Google reports as writable are listed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            divider

            Text("Confirmed Add writes to the target Google calendar only — never to EventKit at the same time, and never automatically. Every add still shows the confirmation screen first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
        }
        if let status = googleAuth.statusMessage {
            Text(status).font(.caption).padding(.horizontal, 14).padding(.bottom, 10)
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(spacing: 12) {
            settingsGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Glass preview")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.top, 12)

                    // 2026-11-07 owner revision: ONE large preview with the
                    // REAL production voice bar (shared surface + content).
                    // The slider's material applies to the bar BACKGROUND
                    // ONLY — text stays crisp at every setting.
                    VoiceBarPreviewStage(intensity: glass)
                        .frame(height: 220)
                        .padding(.horizontal, 10)

                    HStack {
                        Text("Glass")
                        Spacer()
                        Text("\(Int(glass * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 14)

                    Slider(value: $glass, in: 0...1)
                        .padding(.horizontal, 14)
                        .onChange(of: glass) { _, value in
                            prefs.glassIntensity = value
                        }

                    Text(reduceTransparency
                         ? "Reduce Transparency is on — the colorful stage stays for contrast, but the bar is solid."
                         : "Soft blue / coral / lilac behind the real voice bar. Drag the slider — the material applies to the bar background only; text stays sharp.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    // MARK: Speech & Parsing

    private var speechSection: some View {
        VStack(spacing: 12) {
            settingsGroup {
                settingsRow(symbol: "sparkles", title: "Event extraction") {
                    Text("Apple Intelligence")
                        .foregroundStyle(.secondary)
                }
                Text(SpeechParsingStatusCopy.parserDeterministicNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)

                settingsRow(symbol: "checkmark.icloud", title: "Apple Intelligence") {
                    statusPill(vm.foundationModelsReadiness.shortLabel)
                }
                Text(vm.foundationModelsReadiness.userFacingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                Button("Refresh status") { vm.refreshFoundationModelsReadiness() }
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)

                // Legal licenses / notices live HERE (owner, 2026-11-06):
                // moved out of onboarding so the setup flow stays concise.
                DisclosureGroup("Licenses & notices") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Parakeet speech weights use the NVIDIA Open Model License.")
                        Text("Full license texts ship in the app bundle under Resources/Notices.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

                divider

                settingsRow(symbol: "waveform", title: "Speech engine") {
                    Text("Local Parakeet")
                        .foregroundStyle(.secondary)
                }
                Text(SpeechParsingStatusCopy.speechEngine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)

                settingsRow(symbol: "externaldrive", title: "Speech model") {
                    statusPill(modelDownload.isSpeechReady ? "Ready" : "Needs setup")
                }
                Text(modelStatusText.isEmpty ? SpeechParsingStatusCopy.modelReadinessLabel(vm.speech.modelReadiness) : modelStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)

                if let message = modelDownload.snapshot.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                }
                if let fraction = modelDownload.snapshot.progress.fraction, modelDownload.isTransferring {
                    ProgressView(value: fraction)
                        .padding(.horizontal, 14)
                    Text("Speech model \(VoiceOverlayPolicy.progressLabel(received: modelDownload.snapshot.bytesReceived, total: modelDownload.snapshot.bytesExpected ?? 0))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                }

                HStack(spacing: 10) {
                    if modelDownload.isTransferring {
                        Button("Cancel download") { modelDownload.cancel() }
                    } else if !modelDownload.isSpeechReady {
                        Button("Download speech model") { modelDownload.startSpeechInstall() }
                    }
                    Button("Select speech GGUF…") { selectParakeetGGUF() }
                    Button("Use existing speech") { useExistingParakeetModel() }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

                Text("The speech model is fetched from its pinned source and verified before use. Apple Foundation Models are supplied and managed by macOS; QuikCal does not download or import them.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)

                if let modelActionNote {
                    Text(modelActionNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }

                divider

                settingsRow(symbol: "mic", title: "Microphone") {
                    HStack(spacing: 8) {
                        statusPill(shortAuth(micStatusRaw))
                        Button("Open…") { holdToTalk.openMicrophoneSettings() }
                            .controlSize(.small)
                    }
                }
                Text(SpeechParsingStatusCopy.microphoneAuthorizationLabel(micStatusRaw))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)

                Text("No hardware microphone picker — system default input only when you capture. Permission is requested only on mic / hold-to-talk, never at launch.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .onAppear(perform: refreshSpeechStatus)
    }

    // MARK: Shared chrome

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(QuietPalette.surface(colorScheme: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(QuietPalette.surfaceStroke(colorScheme: colorScheme), lineWidth: 1)
        )
    }

    private func settingsRow<Trailing: View>(
        symbol: String,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Divider().padding(.leading, 50)
    }

    private func statusPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }

    private func shortAuth(_ raw: String) -> String {
        switch raw {
        case "authorized", "granted": return "Authorized"
        case "denied", "restricted": return "Denied"
        case "notDetermined": return "Not asked"
        default: return raw
        }
    }

    private func refreshSpeechStatus() {
        vm.refreshFoundationModelsReadiness()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micStatusRaw = "authorized"
        case .denied: micStatusRaw = "denied"
        case .restricted: micStatusRaw = "restricted"
        case .notDetermined: micStatusRaw = "notDetermined"
        @unknown default: micStatusRaw = "unknown"
        }
        vm.speech.refreshModelReadiness()
        modelDownload.refresh()
        let validation = prefs.parakeetModelValidation(requireChecksum: false)
        modelStatusText = validation.readiness.userFacingStatus
        if let path = validation.path {
            modelStatusText += "\n\(path)"
        }
    }

    private func selectParakeetGGUF() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.title = "Select Parakeet GGUF"
        panel.message = "Choose a Parakeet Unified EN GGUF. QuikCal validates architecture/size before use."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let validation = ParakeetModelValidator.validate(fileURL: url, requireChecksum: false)
        guard validation.readiness == .ready else {
            modelActionNote = validation.readiness.userFacingStatus
            refreshSpeechStatus()
            return
        }
        do {
            let installed = try ParakeetModelInstaller.copyExistingModel(
                from: url,
                requireChecksum: true
            )
            prefs.parakeetModelPath = installed.path
            modelActionNote = installed.readiness == .ready
                ? "Installed into QuikCal Application Support."
                : installed.readiness.userFacingStatus
        } catch {
            modelActionNote = "Could not install model: \(error.localizedDescription)"
        }
        vm.speech.refreshModelReadiness()
        refreshSpeechStatus()
    }

    private func useExistingParakeetModel() {
        let source = ParakeetModelStore.hexDevModelURL
        let validation = ParakeetModelValidator.validate(fileURL: source, requireChecksum: true)
        guard validation.readiness == .ready else {
            modelActionNote = "No usable existing model at \(source.path). \(validation.readiness.userFacingStatus)"
            refreshSpeechStatus()
            return
        }
        do {
            let installed = try ParakeetModelInstaller.copyExistingModel(
                from: source,
                requireChecksum: true
            )
            prefs.parakeetModelPath = installed.path
            modelActionNote = installed.readiness == .ready
                ? "Copied existing model (read-only source) into QuikCal Application Support. NVIDIA license notice stamped."
                : installed.readiness.userFacingStatus
        } catch {
            modelActionNote = "Could not copy existing model: \(error.localizedDescription)"
        }
        vm.speech.refreshModelReadiness()
        refreshSpeechStatus()
    }
}
