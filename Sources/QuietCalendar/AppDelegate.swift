import AppKit
import SwiftUI
import AVFoundation
import Combine
import QuietCalendarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// DEBUG QA host isolation (2026-11-07 review fix): in the QA host
    /// (`--qc-qa-defaults`) the ViewModel reads/writes the EPHEMERAL QA
    /// defaults suite, never the owner's real standard domain. A custom
    /// UserDefaults suite falls back to the app's standard domain for
    /// READS, so a plain `AppViewModel()` (defaults: .standard) would leak
    /// the OWNER's real persisted state (e.g. calendar destination) into
    /// the display-only fixtures. Production (no flag) is unchanged:
    /// the standard domain, exactly as before.
    private static func makeIsolatedViewModel() -> AppViewModel {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(QAHostRouter.defaultsFlag),
           let suite = UserDefaults(suiteName: QAHostRouter.qaDefaultsSuiteName) {
            return AppViewModel(defaults: suite)
        }
#endif
        return AppViewModel()
    }

    let viewModel = AppDelegate.makeIsolatedViewModel()
    let googleAuth = GoogleOAuthService()
    let holdToTalk = HoldToTalkMonitor()
    /// Compact top-center listening/status pill for hold-to-talk —
    /// replaces popping the full capture panel on hold (no focus theft).
    let voiceOverlay = VoiceOverlayController()
    let prefs: AppPreferencesStore = {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--qc-qa-defaults") {
            // Separate ephemeral QA domain — never the owner's real prefs.
            return AppPreferencesStore(defaults: UserDefaults(suiteName: QAHostRouter.qaDefaultsSuiteName) ?? .standard)
        }
#endif
        return AppPreferencesStore()
    }()
    /// Shared with onboarding + Settings — no duplicate concurrent transfers.
    let modelDownload = ParakeetModelDownloadController.shared
    /// Sparkle in-app updates (owner-approved 2026-11-08; auto-check
    /// notification 0.3.19): automatic periodic checks (default on,
    /// user-controllable in Settings) notify via Sparkle's native update
    /// alert; manual "Check for Updates…" from the public GitHub Releases
    /// appcast stays available. Retained for the process lifetime; service
    /// started on the main actor only after app readiness. Shared with the
    /// status menu + Settings.
    let appUpdater = AppUpdaterController()

    /// Retained for the process lifetime — dropping this kills the menu-bar target.
    private var statusItem: NSStatusItem?
    /// Dedicated Keychain store for the privately imported Google client
    /// secret (Settings → Import Google configuration…). Never logged.
    private let googleClientSecretStore = KeychainGoogleClientSecretStore()
    private let capturePanel = CapturePanelController()
    private var onboardingController: OnboardingWindowController?
    private var settingsController: SettingsWindowController?
    /// Whether the current hold actually started speech (not a blocked pill
    /// or practice preview) — release must only process real recordings.
    private var holdStartedSpeech = false
    private var holdParsingObservation: AnyCancellable?
    private var speechMessageObservation: AnyCancellable?
    /// P0: typed hold-outcome observation (every terminal path resolves the pill).
    private var holdOutcomeObservation: AnyCancellable?
    /// P2: live preview + amplitude forwarding to the expanding pill.
    private var livePreviewObservation: AnyCancellable?
    private var liveAmplitudeObservation: AnyCancellable?
    /// Set before `openOnboarding(force:)` when Settings starts a fresh replay.
    private var pendingOnboardingReplay = false
    private var pendingHoldGuideOnly = false
    /// Set by `openOnboarding(force:launchAuto:)` — true only when LAUNCH
    /// ROUTING (cold start / reopen → incomplete profile) opened the
    /// onboarding window, so it shows the approved entry card first.
    private var pendingLaunchEntryCard = false
    /// Set by `openOnboarding(force:launchAuto:setupGap:)` — the broken
    /// setup step a completed-but-unready launch surfaces (2026-11-07
    /// installed-runtime repair); nil for every other open.
    private var pendingSetupGapPage: OnboardingPage?
#if DEBUG
    /// Cold-launch routing decision recorded for the DEBUG QA launch
    /// probe (read-only facts; never compiled into Release).
    private var lastLaunchReadiness: EssentialSetupReadiness = .ready
    private var lastLaunchSurface: AppLaunchSurface = .menuBarOnly
    private var lastLaunchSetupGap: EssentialSetupGap?
#endif
    /// One official mic request in flight from a hold-intent (never stacked).
    private var micRequestInFlight = false
    /// 0.3.13 cards pass: the compact targeted-repair card window (design
    /// 7:385) — retained for process lifetime; dismissible, never resets.
    private var holdGuideRepairCardController: HoldGuideRepairCardController?
#if DEBUG
    /// DEBUG QA host only: guide phase to open.
    private var pendingInitialHoldPhase: HoldToTalkGuidePhase?
    /// DEBUG QA fixtures only (0.3.6): labelled drag-guide screenshots.
    private var pendingQAaxTrusted = false
    /// DEBUG QA fixture only (2026-11-07 review): force the UNTRUSTED
    /// permission UI for a labelled screenshot when the QA process's real
    /// Accessibility trust is inherited from the owner's TCC grant.
    private var pendingQAaxUntrusted = false
    private var pendingQAAppLocation: String?
    private var pendingQADetailsExpanded = false
    /// DEBUG QA fixtures only (0.3.13 cards pass): labelled screenshots.
    private var pendingQAAppearance: String?
    private var pendingQAEntryCardSuppressed = false
    private var pendingQAGoogleConfigFixture = false
    private var pendingQAPracticeKeyFixture: String?
    /// DEBUG QA fixture only (0.3.13 follow-up): repair-card state
    /// (trustedNoListener) for a labelled screenshot — never set by any
    /// production path.
    private var pendingQARepairCardState: QARepairCardFixture?
    /// DEBUG QA only (2026-11-07 launch-repair routing fix): when set, the
    /// REAL cold-launch routing runs with the ephemeral QA profile and the
    /// probe dump records which surfaces were created (regression proof
    /// that no automatic repair-card presentation exists).
    private var pendingQALaunchProbe: QAHostConfig?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupCapturePanel()
        wireHoldToTalk()
        wireGoogleWriter()
#if DEBUG
        // DEBUG-only QA host: programmatic invocation of the SAME
        // production controllers/actions. Compiled out of Release.
        if let qa = QAHostRouter.parse(arguments: ProcessInfo.processInfo.arguments) {
            if qa.surface == .launchProbe {
                // Launch-probe fixture (2026-11-07 launch-repair routing
                // fix): write the EPHEMERAL QA-domain profile, then fall
                // through so the REAL cold-launch routing below runs
                // exactly as in production — the probe dump then records
                // which surfaces were actually created.
                prepareQALaunchProbe(qa)
            } else {
                runQASurface(qa)
                return
            }
        }
#endif
        // 0.3.6: completed + leftover resume cursor is stale — clear only
        // the cursor (never other prefs/models/accounts); incomplete
        // journeys keep their cursor and resume below.
        prefs.clearStaleResumeIfCompleted()
        // Google destination: refresh the persisted active account's calendar
        // list once at launch, so a restart does not force a manual Settings
        // visit before Add is available. Render-safe wiring (backend repair
        // follow-up): the launch path never performs a synchronous Keychain
        // read — it refreshes the token-presence snapshot off-main and lists
        // calendars only when the snapshot says tokens exist. Fail-closed:
        // any failure leaves the gate closed with its reason.
        if prefs.calendarDestinationKind == .google,
           let account = googleAuth.activeAccount {
            let accountID = account.id
            googleAuth.refreshStoredTokenSnapshot()
            Task { [weak self] in
                // One bounded re-check after the snapshot refresh has had a
                // moment to apply — a single delayed read, never a loop.
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.prefs.calendarDestinationKind == .google else { return }
                guard let active = self.googleAuth.activeAccount, active.id == accountID else { return }
                if self.googleAuth.hasStoredTokensSnapshot(accountID: accountID) {
                    self.googleAuth.loadCalendars()
                }
            }
        }
        // 0.3.11: restore persisted hold-to-talk monitoring at launch —
        // only when the user's enabled intent is persisted AND real
        // Accessibility trust is present (never faked from prefs). Runs the
        // one-time backward-compatible migration of the intent. Kept after
        // the DEBUG QA early-return so QA surfaces never install monitors.
        holdToTalk.restoreMonitoringAtLaunch()
        // 0.3.13: adopt a privately imported Google client secret (dedicated
        // Keychain item) OFF the main thread before the launch surface is
        // chosen — no synchronous Keychain read on main, env dev fallback
        // still wins when present, and adoption has no side effects.
        adoptStoredClientSecretOffMain()
        let launchReadiness = currentLaunchReadiness()
        // 2026-11-07 OWNER CORRECTION (supersedes the installed-runtime
        // repair's surfacing): onboarding runs ONCE, on initial setup. A
        // COMPLETED profile NEVER auto-reopens onboarding on subsequent
        // launches — not even when its optional setup is unready (hold
        // intent + untrusted Accessibility, or a signed-out Google
        // destination). The readiness verdict stays live for the DEBUG
        // QA probe and the explicit status-menu Repair item only; the
        // router ignores it for the surface. Explicit Replay/Resume
        // remains available from the status menu and Settings.
        let launchSurface = AppLaunchRouter.surface(
            trigger: .coldStart,
            onboardingCompleted: prefs.onboardingCompleted,
            readiness: launchReadiness,
            context: .directUserLaunch
        )
        let launchSetupGap = setupGapIfSurfaced(surface: launchSurface, readiness: launchReadiness)
#if DEBUG
        lastLaunchReadiness = launchReadiness
        lastLaunchSurface = launchSurface
        lastLaunchSetupGap = launchSetupGap
#endif
        // 2026-11-07 onboarding auto-launch repair: apply the cold-start
        // surface on the NEXT runloop turn, after LaunchServices' launch
        // activation has settled. Presenting synchronously inside
        // `applicationDidFinishLaunching` raced LaunchServices for this
        // accessory app: the window was created, but `NSApp.activate()`
        // fired before the app could legally become active (macOS 14+),
        // so a cold-launch onboarding could land visible-but-not-key —
        // or be missed entirely behind the app the user launched from.
        // Routing is unchanged; ONLY the presentation timing moves one
        // turn later. Reopen (`applicationShouldHandleReopen`) is a user
        // event that arrives after launch and stays immediate.
        DispatchQueue.main.async { [weak self] in
            self?.applyLaunchSurface(launchSurface, setupGap: launchSetupGap)
        }
        // 2026-11-07 launch-repair routing fix: the targeted repair card is
        // NEVER presented automatically — not on cold start, not on reopen,
        // not on activation (LaunchRepairPresentationPolicy pins false for
        // every trigger). A completed cold launch is exactly the router's
        // menuBarOnly surface and nothing else opens; an incomplete one is
        // the onboarding window (already applied above), never a repair
        // card over it. Permission setup stays reachable through Voice
        // setup, Settings, an explicit voice attempt, or the explicit
        // status-menu "Repair Hold-to-Talk…" item (offered only while the
        // live decision actually says repair).
        // Sparkle updater (0.3.19): start the service AFTER app readiness on
        // the main actor. Automatic periodic CHECKS run by default (daily
        // cadence; after-launch check when due) and notify via Sparkle's
        // native update alert — the Info.plist SUEnableAutomaticChecks
        // default also suppresses Sparkle's second-launch consent prompt,
        // so onboarding is never blocked by an updater dialog. Manual checks
        // stay available from the status menu + Settings; downloads and
        // installs are only ever explicit (SUAllowsAutomaticUpdates false).
        appUpdater.startUpdater()
#if DEBUG
        scheduleQALaunchProbeDump()
#endif
    }

#if DEBUG
    // MARK: - DEBUG-only QA host (compiled out of Release)
    private func runQASurface(_ qa: QAHostConfig) {
        // 2026-11-07 Fn-fix probe: a one-shot LIVE check of THIS QA
        // process's Fn event-tap installability — install, record, uninstall.
        // No events are watched (the handler is never exercised by the
        // probe), no key is posted, no mic, no TCC change: read-only
        // per-process evidence for the Copy-diagnostics trust separation.
        if let probePath = qa.fnTapProbePath {
            writeQAFnTapProbe(to: probePath)
        }
        // Apply fixture before any view appears so refresh() cannot overwrite.
        if let state = qa.modelsState {
            modelDownload.applyQAFixture(state)
        }
        if let probePath = qa.dragProbeFilePath {
            writeQADragProbe(to: probePath)
        }
        if let page = qa.page {
            let session = OnboardingSessionState(page: page, skipped: [], practiceNote: "")
            prefs.saveOnboardingResume(session)
        }
        if let pct = qa.glassPercent {
            prefs.glassIntensity = pct / 100.0
        }
        pendingQAaxTrusted = qa.axTrustedFixture
        pendingQAaxUntrusted = qa.axUntrustedFixture
        pendingQAAppLocation = qa.appLocationFixture
        pendingQADetailsExpanded = qa.detailsExpandedFixture
        pendingQAAppearance = qa.appearance
        pendingQAEntryCardSuppressed = qa.entryCardSuppressed
        pendingQAGoogleConfigFixture = qa.googleConfigFixture
        pendingQAPracticeKeyFixture = qa.practiceKeyState
        pendingQARepairCardState = qa.repairCardState.flatMap(QARepairCardFixture.init(rawValue:))
        if let destination = qa.destination, !destination.isEmpty {
            // Deterministic fixture destination (2026-11-07 review fix):
            // a custom UserDefaults suite FALLS BACK to the app's standard
            // domain for READS, so without this the capture fixtures read
            // the OWNER's real persisted destination (e.g. Google) and the
            // confirm screenshots showed the owner's Google block message
            // with a disabled Yes — never the intended fixture state. The
            // write lands in the EPHEMERAL QA suite only (never the
            // owner's domain); production is untouched.
            prefs.calendarDestinationKind = CalendarDestinationKind(rawValue: destination) ?? .eventKit
        }
        switch qa.surface {
        case .launchProbe:
            // Unreachable: the launch probe is handled in
            // applicationDidFinishLaunching BEFORE runQASurface (it must
            // fall through into the REAL cold-launch routing) — kept here
            // only for switch exhaustiveness.
            return
        case .settings:
            openSettings()
            // 2026-11-07 review pass: force the QA Settings window's
            // AppKit appearance so the Appearance-section screenshot is
            // deterministic (light|dark fixture only — production follows
            // the Mac's appearance).
            if let appearance = qa.appearance {
                settingsController?.window?.appearance = NSAppearance(
                    named: appearance == "dark" ? .darkAqua : .aqua
                )
            }
            writeQAWindowID(qa, window: settingsController?.window)
        case .capture:
            // Display-only delete-review fixture (if requested): pure
            // published state, no lookup/sink/coordinator — screenshots
            // only, and the confirm action fails closed in this process.
            // The fixture renders from a dedicated OFFSCREEN shot window
            // at the confirmation size (the real panel's pre-present
            // animated resize is not exercised by this fixture path; the
            // production visible-panel resize is unchanged).
            if let deleteState = qa.deleteState {
                applyQADeleteFixture(deleteState)
            } else if let confirmState = qa.confirmState {
                applyQAConfirmFixture(confirmState)
            } else if let noteState = qa.noteState {
                applyQANoteFixture(noteState)
            } else {
                toggleCapturePanel()
            }
            writeQAWindowID(qa, window: capturePanel.panel)
        case .voiceBar:
            // Labelled voice-pill fixture: the PRODUCTION pill view in a
            // fixture state, hosted offscreen — no real hold, no mic, no
            // capture; the preview text is the SYNTHETIC fixture transcript.
            presentQAVoiceBarFixture(qa)
            writeQAWindowID(qa, window: qaVoiceBarWindow)
        case .coachmark:
            // SAME production finish path: real status-item button frame.
            // Deferred briefly so the status-item button's window/screen
            // exist at presentation time (still the same production call).
            prefs.onboardingCompleted = true
            prefs.clearOnboardingResume()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.presentMenuBarCoachmark()
                self?.writeQAWindowID(qa, window: MenuBarCoachmarkPresenter.shared.qaDebugWindow)
            }
        case .coachmarkFallback:
            prefs.onboardingCompleted = true
            presentMenuBarCoachmarkFallback()
            writeQAWindowID(qa, window: MenuBarCoachmarkPresenter.shared.qaDebugWindow)
        case .guide:
            // Actual production hold-guide page, phase openSettings —
            // no AX/mic/calendar authorization is performed.
            pendingInitialHoldPhase = .openSettings
            var guide = HoldToTalkGuideState(shortcut: prefs.holdToTalkShortcut, settingsReopen: true)
            guide.phase = .openSettings
            prefs.saveOnboardingResume(OnboardingSessionState(page: .voiceSetup, holdGuide: guide))
            prefs.onboardingCompleted = true
            openHoldToTalkGuideFromSettings()
            writeQAWindowID(qa, window: onboardingController?.window)
        case .repairCard:
            // SAME production policy + presenter as the launch repair
            // (LaunchReadinessRepairPolicy → presentHoldGuideRepairCard).
            // The QA process's REAL Accessibility probe (not trusted)
            // drives the truthful chip — no faked grant. The explicit
            // hold-to-talk intent is written to the EPHEMERAL QA defaults
            // domain only (raw key; the computed reader stays get-only).
            prefs.onboardingCompleted = true
            prefs.defaults.set(true, forKey: AppPreferenceKey.holdToTalkEnabled)
            presentHoldGuideRepairCard()
            writeQAWindowID(qa, window: holdGuideRepairCardController?.window)
        case .onboarding, nil:
            // Models fixture steps route through the same onboarding window.
            // Mirrors launch routing (cold start → onboarding window), so
            // the approved launch entry card (7:330/7:349) renders when a
            // step cursor is present and the card is not suppressed.
            openOnboarding(force: false, launchAuto: true)
            writeQAWindowID(qa, window: onboardingController?.window)
        }
        // Allow the window to settle, then re-write the final window number.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            switch qa.surface {
            case .launchProbe: break // handled before runQASurface; never reached
            case .settings: self.writeQAWindowID(qa, window: self.settingsController?.window)
            case .capture: self.writeQAWindowID(qa, window: self.capturePanel.panel)
            case .coachmark, .coachmarkFallback: self.writeQAWindowID(qa, window: MenuBarCoachmarkPresenter.shared.qaDebugWindow)
            case .guide, .onboarding, nil: self.writeQAWindowID(qa, window: self.onboardingController?.window)
            case .repairCard: self.writeQAWindowID(qa, window: self.holdGuideRepairCardController?.window)
            case .voiceBar: self.writeQAWindowID(qa, window: self.qaVoiceBarWindow)
            }
        }
        // In-process PNG dump (if requested): the app renders its OWN
        // settled window content layer — no screencapture, no TCC.
        scheduleQAShotDump(qa)
    }

    /// DEBUG-only QA launch probe (2026-11-07 launch-repair routing fix):
    /// writes the EPHEMERAL QA-domain profile (never the owner's domain),
    /// then returns so the REAL cold-launch routing below runs unmodified.
    /// Profiles: `completed` = completed + explicit hold intent (the exact
    /// owner-observed completed-but-unready state when combined with the
    /// untrusted fixture); `finished` = completed + hold intent explicitly
    /// OFF (the intentional-skip control — must never be nagged);
    /// `completed-google-signedout` = completed + Google destination with
    /// no linked account; `incomplete` = fresh journey (router → onboarding).
    private func prepareQALaunchProbe(_ qa: QAHostConfig) {
        pendingQALaunchProbe = qa
        pendingQAaxUntrusted = qa.axUntrustedFixture
        // The QA suite persists between QA-host runs on the same machine —
        // set the desired profile EXPLICITLY so each probe is self-contained
        // (never the owner's domain).
        switch qa.launchProfile {
        case "incomplete":
            prefs.onboardingCompleted = false
            prefs.clearOnboardingResume()
            prefs.defaults.set(false, forKey: AppPreferenceKey.holdToTalkEnabled)
            prefs.calendarDestinationKind = .eventKit
            prefs.googleActiveAccountID = nil
        case "finished":
            // Intentional optional skip: hold-to-talk explicitly OFF.
            prefs.onboardingCompleted = true
            prefs.clearOnboardingResume()
            prefs.defaults.set(false, forKey: AppPreferenceKey.holdToTalkEnabled)
            prefs.calendarDestinationKind = .eventKit
            prefs.googleActiveAccountID = nil
        case "completed-google-signedout":
            // Google destination (explicit selection) with no linked account.
            prefs.onboardingCompleted = true
            prefs.clearOnboardingResume()
            prefs.defaults.set(false, forKey: AppPreferenceKey.holdToTalkEnabled)
            prefs.calendarDestinationKind = .google
            prefs.googleActiveAccountID = nil
        default:
            // completed + explicit hold intent: the exact state in which
            // the retired automatic repair took over cold launches — and the
            // owner-observed completed-but-unready case for the 2026-11-07
            // installed-runtime repair.
            prefs.onboardingCompleted = true
            prefs.clearOnboardingResume()
            prefs.defaults.set(true, forKey: AppPreferenceKey.holdToTalkEnabled)
            prefs.calendarDestinationKind = .eventKit
            prefs.googleActiveAccountID = nil
        }
    }

    /// DEBUG-only QA launch probe dump: after the launch surfaces settle,
    /// record which surfaces the REAL cold-launch routing created — the
    /// regression proof that no automatic repair-card presentation exists
    /// on the launch path (even in the would-be-repair state). Exits the
    /// QA host after the dump. Ephemeral QA domain only; no mic, no
    /// calendar, no TCC, no network, no owner prefs.
    private func scheduleQALaunchProbeDump() {
        guard let qa = pendingQALaunchProbe else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { exit(0) }
            self.holdToTalk.refreshPermissionFlags()
            let decision = self.currentRepairDecision()
            let holdIntent = self.prefs.holdToTalkEnabledExplicit
            let launchReadinessDump: String
            switch self.lastLaunchReadiness {
            case .ready: launchReadinessDump = "ready"
            case .unready(let gap): launchReadinessDump = "unready:\(gap.rawValue)"
            }
            let lines = [
                "QuikCal QA launch probe (DEBUG, ephemeral QA domain, read-only)",
                "launch_profile: \(qa.launchProfile ?? "completed")",
                "onboarding_completed_pref: \(self.prefs.onboardingCompleted ? "yes" : "no")",
                "hold_intent_pref: \(holdIntent == nil ? "nil" : (holdIntent! ? "yes" : "no"))",
                "ax_trust_process: \(self.holdToTalk.accessibilityTrusted ? "yes" : "no")",
                "ax_fixture_untrusted: \(qa.axUntrustedFixture ? "yes" : "no")",
                "policy_decision_now: \(decision == .repairHoldToTalkGuide ? "repairHoldToTalkGuide" : "none")",
                "automatic_presentation_allowed: \(LaunchRepairPresentationPolicy.presentsAutomaticallyOnLaunch(trigger: .coldStart) ? "yes" : "no")",
                "explicit_menu_repair_would_be_offered: \(LaunchRepairPresentationPolicy.offersExplicitRepairAction(decision: decision) ? "yes" : "no")",
                // 2026-11-07 installed-runtime repair: the recorded cold-launch
                // routing decision (read-only facts).
                "launch_readiness: \(launchReadinessDump)",
                "launch_surface: \(lastLaunchSurface.rawValue)",
                "setup_gap: \(lastLaunchSetupGap?.rawValue ?? "none")",
                "setup_gap_resume_page: \(lastLaunchSetupGap.map { String(AppLaunchRouter.setupResumePage(gap: $0).rawValue) } ?? "none")",
                "repair_card_created: \(self.holdGuideRepairCardController != nil ? "yes" : "no")",
                "onboarding_window_created: \(self.onboardingController != nil ? "yes" : "no")",
                "settings_window_created: \(self.settingsController != nil ? "yes" : "no")",
                // 2026-11-07 onboarding auto-launch repair: runtime
                // visibility evidence for the launch-created onboarding
                // window — actually visible on a screen (occlusion state,
                // not the removed `isOnScreen`), at the floating level,
                // with the app's live activation state. Read-only facts.
                "onboarding_window_visible: \(self.onboardingController?.window?.occlusionState.contains(.visible) == true ? "yes" : "no")",
                "onboarding_window_level: \(self.onboardingController?.window.map { "\($0.level.rawValue)" } ?? "nil")",
                "onboarding_window_key: \(self.onboardingController?.window?.isKeyWindow == true ? "yes" : "no")",
                "app_is_active: \(NSApp.isActive ? "yes" : "no")"
            ]
            if let path = qa.launchProbePath {
                try? (lines.joined(separator: "\n") + "\n")
                    .write(toFile: path, atomically: true, encoding: .utf8)
            }
            exit(0)
        }
    }

    /// DEBUG-only 0.3.13 QA fixture: injects a DISPLAY-ONLY delete-review
    /// state into the capture panel for screenshots (design 24:99/24:111).
    /// Pure published display state — no lookup, no sink, no coordinator;
    /// the fixture is labelled in-frame, and the red confirm button fails
    /// CLOSED in the QA process (no writer is configured, so even a click
    /// can only produce the honest not-ready failure, never a mutation).
    private func applyQADeleteFixture(_ state: QADeleteFixtureState) {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
            ?? cal.startOfDay(for: Date())
        let start = cal.date(bySettingHour: 14, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        viewModel.inputText = "delete my dentist appointment tomorrow at 2pm"
        func fixtureCandidate(_ id: String, _ startDate: Date) -> EventCandidate {
            EventCandidate(
                id: id,
                provider: .eventKit,
                calendarID: "qa-fixture-calendar",
                calendarTitle: "Home",
                title: "Dentist appointment",
                start: startDate,
                end: cal.date(byAdding: .hour, value: 1, to: startDate) ?? startDate,
                isRecurring: false
            )
        }
        switch state {
        case .confirm:
            let candidate = fixtureCandidate("qa-fixture-1", start)
            viewModel.deleteFlow = .confirmOne(DeleteTarget(candidate: candidate))
        case .chooser:
            let second = cal.date(byAdding: .hour, value: 1, to: start) ?? start
            viewModel.deleteFlow = .choose(
                [fixtureCandidate("qa-fixture-1", start), fixtureCandidate("qa-fixture-2", second)],
                selectedID: nil
            )
        }
        viewModel.screen = .deleteReview
        viewModel.qaDeleteFixtureActive = true
    }

    /// DEBUG-only 2026-11-07 Yes/No pass: display-only CONFIRM fixture for
    /// capture-panel screenshots — pure published state (drafts + screen),
    /// no sink configured in the QA process, so the Yes/Add action fails
    /// closed; nothing is ever written. Labelled in-frame.
    ///
    /// Variants (2026-11-07 review pass): `single` / `multi` render the
    /// honest NOT-READY state (no calendar access in this process — the
    /// disabled button + its reason are the truth). `singleReady` /
    /// `multiReady` ADDITIONALLY set the pure display readiness state
    /// (accessPhase + selection, and the production draft-gate arming the
    /// real parse path performs) so the screenshot proves the HAPPY-PATH
    /// enabled "Yes, add it" button — still display-only: a real click
    /// writes nothing (the QA process has no real EventKit access; the
    /// write fails closed) and no TCC/login is touched.
    private func applyQAConfirmFixture(_ state: String) {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
            ?? cal.startOfDay(for: Date())
        let start = cal.date(bySettingHour: 14, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        let end = cal.date(byAdding: .hour, value: 1, to: start) ?? start
        let provenance = DraftProvenance(
            source: .builtInParser,
            transcript: "Team sync tomorrow at 2pm in Sturm 320",
            referenceNowISO: ISO8601DateFormatter().string(from: Date()),
            timeZoneID: TimeZone.current.identifier
        )
        let draft = ConfirmationDraft(
            title: "Team sync",
            start: start,
            end: end,
            location: "Sturm 320",
            source: .builtInParser,
            provenance: provenance
        )
        let drafts: [ConfirmationDraft]
        if state.hasPrefix("multi") {
            let secondStart = cal.date(byAdding: .hour, value: 2, to: start) ?? start
            let second = ConfirmationDraft(
                title: "Coffee with Ana",
                start: secondStart,
                end: cal.date(byAdding: .hour, value: 1, to: secondStart) ?? secondStart,
                location: "",
                source: .builtInParser,
                provenance: provenance
            )
            drafts = [draft, second]
        } else {
            // Single variants exercise the PRODUCTION single-event confirm
            // path (legacy draft fields, `confirmationDrafts` empty) — the
            // readable review card, exactly as the built-in parser presents
            // one event.
            drafts = []
        }
        viewModel.inputText = "Team sync tomorrow at 2pm in Sturm 320"
        viewModel.confirmationTranscript = "Team sync tomorrow at 2pm in Sturm 320"
        viewModel.confirmationDrafts = drafts
        viewModel.draftTitle = draft.title
        viewModel.draftStart = draft.start
        viewModel.draftEnd = draft.end
        viewModel.draftLocation = draft.location ?? ""
        if state.hasSuffix("Ready") {
            // Pure display readiness for the happy-path screenshot: the
            // SAME production gate transition the real parse path performs
            // (never a faked canCommit), plus the display selection state.
            // No real permission, no sink, no write — labelled in-frame.
            viewModel.qaArmSingleDraftFixtureGate()
            viewModel.accessPhase = .granted
            viewModel.selectionState = .valid(CalendarChoice(
                id: "qa-fixture-calendar", title: "Home", sourceTitle: ""
            ))
        }
        viewModel.qaDeleteFixtureActive = true
        viewModel.screen = .confirm
    }

    /// DEBUG-only 2026-11-07 Yes/No pass: display-only NOTE fixture — the
    /// honest state AFTER an explicit No: the recognized transcript stays
    /// in the editable field with the re-speak hint. Nothing was written.
    private func applyQANoteFixture(_ state: String) {
        guard state == "noCorrection" else { return }
        let outcome = ConfirmationRejectionPolicy.reject(
            transcript: "Team sync tomorrow at 2pm in Sturm 320",
            shortcutName: prefs.holdToTalkShortcut.shortName
        )
        viewModel.inputText = outcome.restoredTranscript
        viewModel.statusMessage = outcome.hint
        viewModel.qaDeleteFixtureActive = true
        viewModel.screen = .note
    }

    /// DEBUG-only 2026-11-07 working-bar pass: the PRODUCTION voice pill
    /// in a labelled fixture state, hosted in an offscreen window for the
    /// in-process PNG dump. No real hold, no mic, no capture — the preview
    /// text is the SYNTHETIC fixture transcript, and the chip says so.
    private var qaVoiceBarWindow: NSWindow?
    private func presentQAVoiceBarFixture(_ qa: QAHostConfig) {
        let state: VoiceOverlayController.State
        switch qa.voiceBarState {
        case "transcribing":
            state = .processing(phase: .transcribing)
        case "understanding":
            state = .processing(phase: .understanding)
        default:  // listeningPartial
            state = .listening(
                preview: LiveVoicePreview(text: "Meeting at noon for something in Sturm 320"),
                amplitude: 0.55
            )
        }
        let width = VoiceBarWidthPolicy.width(
            previewCharacterCount: 47,
            visibleFrameWidth: 1440
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width + 240, height: 140),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = qa.appearance == "dark"
            ? NSAppearance(named: .darkAqua)
            : (qa.appearance == "light" ? NSAppearance(named: .aqua) : nil)
        let host = NSHostingView(
            rootView: VStack(spacing: 10) {
                Text("QA fixture — synthetic preview, no real capture")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange)
                VoiceOverlayPillView(state: state, glassIntensity: prefs.glassIntensity)
                    .frame(width: width)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        )
        host.sizingOptions = []
        host.setFrameSize(NSSize(width: width + 240, height: 140))
        window.contentView = host
        window.displayIfNeeded()
        qaVoiceBarWindow = window
    }

    private func presentMenuBarCoachmarkFallback() {        let screen = NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        let fullFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        MenuBarCoachmarkPresenter.shared.present(
            anchoredTo: nil,
            visibleFrame: visibleFrame,
            fullFrame: fullFrame,
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        prefs.showMenuBarHint = false
    }

    private func writeQAWindowID(_ qa: QAHostConfig, window: NSWindow?) {
        guard let path = qa.windowIDFilePath, let window else { return }
        var lines = ["\(window.windowNumber)",
                     "\(window.frame.origin.x),\(window.frame.origin.y),\(window.frame.width),\(window.frame.height)"]
        // Coachmark evidence: record the REAL target/layout actually used
        // (no screenshot matching) so qa-035 metadata proves anchored vs fallback.
        if qa.surface == .coachmark || qa.surface == .coachmarkFallback {
            let p = MenuBarCoachmarkPresenter.shared
            if let overlay = p.qaDebugOverlayWindow {
                lines.append("OVERLAY_WINID: \(overlay.windowNumber)")
                lines.append("OVERLAY_GEOM: \(overlay.frame.origin.x),\(overlay.frame.origin.y),\(overlay.frame.width),\(overlay.frame.height)")
            }
            if let layout = p.qaDebugLayout {
                lines.append("ANCHORED: \(layout.isAnchored)")
                if let ring = layout.ringRect {
                    lines.append("RING: \(ring.x),\(ring.y),\(ring.width),\(ring.height)")
                } else {
                    lines.append("RING: nil")
                }
                if let tip = layout.arrowTip {
                    lines.append("ARROW_TIP: \(tip.x),\(tip.y)")
                }
                if let center = layout.targetCenter {
                    lines.append("TARGET_CENTER: \(center.x),\(center.y)")
                }
                lines.append("CARD_ORIGIN: \(layout.cardOrigin.x),\(layout.cardOrigin.y)")
                lines.append("CARD_SIZE: \(layout.cardSize.width),\(layout.cardSize.height)")
            }
            if let target = p.qaDebugTargetFrame {
                lines.append("TARGET_FRAME: \(target.origin.x),\(target.origin.y),\(target.size.width),\(target.size.height)")
            } else {
                lines.append("TARGET_FRAME: nil")
            }
            if let sw = statusItem?.button?.window {
                lines.append("STATUS_WINID: \(sw.windowNumber)")
                lines.append("STATUS_GEOM: \(sw.frame.origin.x),\(sw.frame.origin.y),\(sw.frame.width),\(sw.frame.height)")
            } else {
                lines.append("STATUS_WINID: nil")
            }
            lines.append("FULL_FRAME: \(p.qaDebugFullFrame.origin.x),\(p.qaDebugFullFrame.origin.y),\(p.qaDebugFullFrame.size.width),\(p.qaDebugFullFrame.size.height)")
            lines.append("VISIBLE_FRAME: \(p.qaDebugVisibleFrame.origin.x),\(p.qaDebugVisibleFrame.origin.y),\(p.qaDebugVisibleFrame.size.width),\(p.qaDebugVisibleFrame.size.height)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// DEBUG-only 0.3.7: prove the real drag payload registers a file URL for
    /// the running `.app` — no System Settings drop, no permission change.
    private func writeQADragProbe(to path: String) {
        let payload = AccessibilityDragGuideInfo.current()
        let provider = AccessibilityDragGuideInfo.itemProvider(for: payload)
        let hasFileURL = provider.hasItemConformingToTypeIdentifier(
            AccessibilityDragGuidePolicy.pasteboardTypeFileURL)
        let lines = [
            "bundlePath=\(payload.bundlePath)",
            "fileURL=\(payload.fileURL.absoluteString)",
            "bundleID=\(payload.bundleID)",
            "displayName=\(payload.displayName)",
            "pathExtension=\(payload.fileURL.pathExtension)",
            "location=\(payload.location.rawValue)",
            "isValidExport=\(payload.isValidExport)",
            "offersDragTile=\(payload.offersDragTile)",
            "registeredTypeIdentifiers=\(provider.registeredTypeIdentifiers.joined(separator: ","))",
            "hasPublicFileURL=\(hasFileURL)"
        ]
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// DEBUG-only 2026-11-07 Fn-fix pass: one-shot LIVE probe of THIS QA
    /// process's Fn event-tap installability. Installs the production
    /// `HoldToTalkEventTap`, records the honest install result plus the
    /// per-process trust facts, and uninstalls immediately. The handler is
    /// never exercised (no key is posted, no events are read beyond the
    /// install itself); read-only, no TCC change, no mic, no prompts.
    private func writeQAFnTapProbe(to path: String) {
        holdToTalk.refreshPermissionFlags()
        let tap = HoldToTalkEventTap()
        let installed = tap.install { _ in }
        tap.uninstall()
        let process = ProcessInfo.processInfo
        let lines = [
            "QuikCal Fn event-tap probe (DEBUG QA, own process)",
            "running_path: \(Bundle.main.bundlePath)",
            "app_version: \((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown")",
            "macOS: \(process.operatingSystemVersionString)",
            "ax_trust_process: \(holdToTalk.accessibilityTrusted ? "yes" : "no")",
            "input_monitoring_preflight: \(holdToTalk.inputMonitoringAllowed ? "yes" : "no")",
            "fn_event_tap_installed: \(installed ? "yes" : "no")",
            "tap_uninstalled_after_probe: yes"
        ]
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// DEBUG-only 0.3.13 cards pass: in-process PNG dump of the QA window's
    /// OWN content layer (CALayer render into a 2x bitmap context). No
    /// `screencapture`, no Screen-Recording TCC, no screen involvement —
    /// the app writes the settled window content itself, then exits.
    private func scheduleQAShotDump(_ qa: QAHostConfig) {
        guard let shotPath = qa.shotPath else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { exit(0) }
            let window: NSWindow?
            if qa.surface == .capture,
               qa.deleteState != nil || qa.confirmState != nil || qa.noteState != nil {
                // Display-only fixtures render the PRODUCTION
                // CaptureContentView (same root as the real panel) from a
                // dedicated offscreen window at the confirmation size —
                // deterministic, no panel presentation, no outside-click
                // monitors. The fixture appearance (light|dark) is applied
                // to THIS window so the captured material actually follows
                // the requested macOS appearance (2026-11-07 review fix:
                // both light and dark shots previously rendered with the
                // system's current appearance — pixel-identical PNGs).
                window = self.makeQACaptureShotWindow(appearance: qa.appearance)
            } else {
                switch qa.surface {
                case .launchProbe: window = nil // handled before runQASurface; never reached
                case .settings: window = self.settingsController?.window
                case .capture: window = self.capturePanel.panel
                case .coachmark, .coachmarkFallback: window = MenuBarCoachmarkPresenter.shared.qaDebugWindow
                case .guide, .onboarding, nil: window = self.onboardingController?.window
                case .repairCard: window = self.holdGuideRepairCardController?.window
                case .voiceBar: window = self.qaVoiceBarWindow
                }
            }
            self.writeQAShot(window: window, to: shotPath)
            self.writeQAAccessibilityProbe(window: window, to: shotPath + ".probe.txt")
            // DEBUG-only layout-geometry dump: the CALayer tree with
            // frames, so offscreen QA shots can be verified geometrically
            // (the AX probe reports 0 text elements for offscreen windows).
            if let window, let content = window.contentView, let layer = content.layer {
                var lines = ["QA layer geometry (own process, DEBUG only)"]
                func dump(_ l: CALayer, depth: Int) {
                    let f = l.frame
                    let name = l.name ?? String(describing: type(of: l))
                    if f.width > 1 || f.height > 1 {
                        lines.append(String(repeating: "  ", count: min(depth, 8))
                            + "\(name) frame=\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))"
                            + (l.backgroundColor.map { " bg=\(CIColor(cgColor: $0).stringRepresentation.prefix(24))" } ?? ""))
                    }
                    for sub in l.sublayers ?? [] { dump(sub, depth: depth + 1) }
                }
                dump(layer, depth: 0)
                try? (lines.joined(separator: "\n") + "\n")
                    .write(toFile: shotPath + ".layers.txt", atomically: true, encoding: .utf8)
            }
            // DEBUG-only state dump for the display-only capture fixtures:
            // the exact button-gate inputs the production view read at shot
            // time (diagnosis evidence only — no secrets, no user data).
            if qa.surface == .capture {
                let vm = self.viewModel
                let lines = [
                    "fixture=confirm:\(qa.confirmState ?? qa.noteState ?? qa.deleteState?.rawValue ?? "panel")",
                    "screen=\(String(describing: vm.screen))",
                    "destination=\(vm.prefs.calendarDestinationKind.rawValue)",
                    "drafts=\(vm.confirmationDrafts.count)",
                    "isSaving=\(vm.isSaving)",
                    "addable=\(vm.confirmationDrafts.filter { $0.canAdd || $0.duplicateAddArmed }.count)",
                    "canAddDraft=\(vm.canAddDraft)",
                    "googleBlock=\(vm.googleAddBlockMessage ?? "nil")",
                    "status=\(vm.statusMessage ?? "nil")",
                    "accessPhase=\(vm.accessPhase)",
                    "selection=\(vm.selectionState)"
                ]
                try? (lines.joined(separator: "\n") + "\n")
                    .write(toFile: shotPath + ".state.txt", atomically: true, encoding: .utf8)
            }
            exit(0)
        }
    }

    /// DEBUG-only: offscreen 640×320 window hosting the SAME production
    /// capture root the real panel shows (display-only fixture state
    /// applied). The hosting view is explicitly framed with sizing options
    /// OFF (no self-resizing to the content's ideal size) so the shot is
    /// exactly the confirmation size. The QA appearance fixture (light |
    /// dark) is applied to THIS window — production always follows the
    /// Mac's appearance.
    private func makeQACaptureShotWindow(appearance: String? = nil) -> NSWindow? {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        if appearance == "dark" {
            window.appearance = NSAppearance(named: .darkAqua)
        } else if appearance == "light" {
            window.appearance = NSAppearance(named: .aqua)
        }
        let host = NSHostingView(rootView: captureRoot)
        host.sizingOptions = []
        host.setFrameSize(NSSize(width: 640, height: 320))
        window.contentView = host
        window.displayIfNeeded()
        return window
    }

    private func writeQAShot(window: NSWindow?, to path: String) {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true
        content.layoutSubtreeIfNeeded()
        content.display()
        guard let layer = content.layer else { return }
        let scale: CGFloat = 2.0
        let w = Int(content.bounds.width * scale)
        let h = Int(content.bounds.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return }
        // Neutral backing fill (the real panel composites over the desktop;
        // in the isolated render material backdrops composite over this).
        // 0.3.13 final pass: the fill follows the window's EFFECTIVE
        // appearance (light → #FFFFFF, dark → #1E1E1E — the same solid root
        // the onboarding window paints) so the transparent window corners
        // read correctly per appearance instead of always-white.
        let effectiveDark: Bool = {
            window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }()
        if effectiveDark {
            ctx.setFillColor(CGColor(
                srgbRed: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0, alpha: 1))
        } else {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        }
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CA layers are top-left origin; flip for the bottom-left CGContext.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// DEBUG-only programmatic layout verification: walks the QA window's
    /// own accessibility tree and records every text/button element with
    /// its frame in WINDOW coordinates, checking it lies inside the content
    /// bounds. Written next to the PNG as evidence (text lines + bounds).
    private func writeQAAccessibilityProbe(window: NSWindow?, to path: String) {
        guard let window, let content = window.contentView else { return }
        var lines: [String] = [
            "QA accessibility probe (own process, read-only)",
            "window content bounds: \(content.bounds.width)x\(content.bounds.height)"
        ]
        var inBoundsCount = 0
        var outOfBoundsCount = 0
        func describe(_ element: Any, depth: Int) {
            guard depth < 12 else { return }
            guard let ax = element as? NSAccessibilityProtocol else { return }
            let role = ax.accessibilityRole()?.rawValue ?? "?"
            let label = ax.accessibilityLabel()
            let value = ax.accessibilityValue()
            let help = ax.accessibilityHelp()
            let screenFrame = ax.accessibilityFrame()
            let frameInWindow: NSRect
            if screenFrame != .zero {
                frameInWindow = window.convertFromScreen(screenFrame)
            } else {
                frameInWindow = .zero
            }
            let text: String?
            if let label, !label.isEmpty {
                text = label
            } else if let value = value as? String, !value.isEmpty {
                text = value
            } else if let help, !help.isEmpty {
                text = help
            } else {
                text = nil
            }
            if let text, !text.isEmpty, role != "AXGroup" {
                let inside = content.bounds.insetBy(dx: -2, dy: -2).contains(frameInWindow)
                if inside { inBoundsCount += 1 } else { outOfBoundsCount += 1 }
                lines.append(
                    "role=\(role) frame=\(Int(frameInWindow.origin.x)),\(Int(frameInWindow.origin.y)),\(Int(frameInWindow.width)),\(Int(frameInWindow.height)) inBounds=\(inside) text=\"\(text)\""
                )
            }
            if let children = ax.accessibilityChildren() as? [Any] {
                for child in children {
                    describe(child, depth: depth + 1)
                }
            }
        }
        describe(content, depth: 0)
        lines.append("inBounds=\(inBoundsCount) outOfBounds=\(outOfBoundsCount)")
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
#endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // FAIL-SAFE (2026-11-07): a hold still active at quit must be
        // terminated explicitly — the pipeline is cancelled (no
        // transcription/submit from an untrusted end) and the recording is
        // stopped through the same cancel path as every other listener
        // loss. No pill is shown for `.appTerminating`.
        holdToTalk.stopMonitoring(cancelReason: .appTerminating)
        MenuBarCoachmarkPresenter.shared.dismiss()
    }

    /// Finder / Spotlight / Dock “open again” for an LSUIElement agent.
    /// Incomplete → onboarding (resume preserved). Completed → configuration.
    /// 2026-11-07 OWNER CORRECTION: readiness never re-opens onboarding
    /// for a completed profile on reopen either — onboarding is
    /// once-only (initial setup); explicit Replay/Resume stays in the
    /// status menu and Settings. Never capture.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let readiness = currentLaunchReadiness()
        let surface = AppLaunchRouter.surface(
            trigger: .applicationReopen,
            onboardingCompleted: prefs.onboardingCompleted,
            readiness: readiness,
            context: .directUserLaunch
        )
        applyLaunchSurface(surface, setupGap: setupGapIfSurfaced(surface: surface, readiness: readiness))
        return true
    }

    private func applyLaunchSurface(_ surface: AppLaunchSurface, setupGap: EssentialSetupGap? = nil) {
        switch surface {
        case .onboarding:
            // Launch routing (cold start AND reopen, INCOMPLETE profile
            // only — 2026-11-07 owner correction): the SAME onboarding
            // window opens as before — showing the approved launch entry
            // card (design 7:330/7:349) first. No routing change, no
            // reset; the session cursor is untouched. A completed profile
            // never lands here anymore (the router ignores readiness for
            // the surface), so `setupGap` is diagnostic-only and nil on
            // every production launch path.
            openOnboarding(force: false, launchAuto: true, setupGap: setupGap)
        case .configuration:
            openSettings()
        case .menuBarOnly:
            break
        }
    }

    /// Live essential-setup readiness for launch routing (2026-11-07
    /// installed-runtime repair). Inputs are prefs + the live process
    /// Accessibility probe — NO Keychain read, NO network; the Google
    /// verdict is bounded to the prefs-decidable signed-out case.
    private func currentLaunchReadiness() -> EssentialSetupReadiness {
        EssentialSetupReadinessPolicy.readiness(
            destinationKind: prefs.calendarDestinationKind,
            googleActiveAccountID: prefs.googleActiveAccountID,
            holdToTalkEnabledIntent: prefs.holdToTalkEnabledExplicit,
            accessibilityTrustedNow: currentAccessibilityTrusted
        )
    }

    /// The gap whose step a launch surface should resume at — only when
    /// routing actually surfaced setup for a COMPLETED profile (an
    /// incomplete profile keeps its own persisted cursor instead).
    private func setupGapIfSurfaced(
        surface: AppLaunchSurface,
        readiness: EssentialSetupReadiness
    ) -> EssentialSetupGap? {
        guard prefs.onboardingCompleted,
              surface == .onboarding,
              case .unready(let gap) = readiness else { return nil }
        return gap
    }

    // MARK: - Local Google client secret adoption (0.3.13)

    /// Loads the privately imported client secret from the dedicated
    /// Keychain item OFF the main thread (a synchronous Keychain read must
    /// never run on the main thread during app init — same rule as the
    /// token-presence snapshot) and adopts it into the auth config. An
    /// explicitly exported `QUIET_CALENDAR_GOOGLE_CLIENT_SECRET` (dev
    /// fallback) is respected first and skips the store entirely.
    /// Adoption is silent: no sign-in, no revoke, no token/calendar writes —
    /// the NEXT user-initiated sign-in uses the secret at the exchange and
    /// every refresh call site (all read `config.clientSecret` at call time).
    private func adoptStoredClientSecretOffMain() {
#if DEBUG
        // The DEBUG QA launch probe runs the real cold-launch path but
        // must never touch the owner's real Keychain item — the adoption
        // is irrelevant to launch-surface routing, so skip it there.
        guard pendingQALaunchProbe == nil else { return }
#endif
        let envPresent = ProcessInfo.processInfo
            .environment["QUIET_CALENDAR_GOOGLE_CLIENT_SECRET"]?
            .isEmpty == false
        guard !envPresent else { return }
        let store = googleClientSecretStore
        Task.detached(priority: .utility) { [weak self] in
            // A Keychain read failure fails closed (the config keeps no
            // secret; Settings import remains reachable) rather than
            // surfacing an error at launch for an optional import.
            let secret = (try? store.load()) ?? nil
            guard let secret, !secret.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.googleAuth.adoptClientSecret(secret)
            }
        }
    }

    /// Explicit-entry readiness repair (2026-11-07 launch-repair routing
    /// fix). Re-validates the live `LaunchReadinessRepairPolicy` decision
    /// (completed profile + explicit hold-to-talk intent + Accessibility
    /// not trusted right now — 2026-11-07 live evidence: toggle ON in
    /// System Settings, "Not yet" in the app — stale TCC identity /
    /// re-signed copy) and presents the approved COMPACT repair card
    /// (design 7:385) — dismissible (Skip for now / window close),
    /// truthful live Accessibility chip, NO pref reset, never a forced
    /// grant.
    ///
    /// NEVER called from launch routing — cold start, reopen, and
    /// activation present no repair modal
    /// (`LaunchRepairPresentationPolicy.presentsAutomaticallyOnLaunch`
    /// is false for every trigger). The only production caller is the
    /// explicit status-menu "Repair Hold-to-Talk…" item; the full
    /// hold-to-talk guide remains reachable from Settings
    /// (`openHoldToTalkGuideFromSettings` — unchanged).
    private func presentReadinessRepairIfBroken() {
        if case .repairHoldToTalkGuide = currentRepairDecision() {
            presentHoldGuideRepairCard()
        }
    }

    /// Live repair decision for the explicit-entry visibility/action.
    /// Inputs are the same pure policy as before the routing fix — only
    /// the trigger changed (automatic → explicit user action).
    private func currentRepairDecision() -> LaunchReadinessRepair {
        LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: prefs.onboardingCompleted,
            holdToTalkEnabledIntent: prefs.holdToTalkEnabledExplicit,
            accessibilityTrustedNow: currentAccessibilityTrusted
        )
    }

    /// The live Accessibility trust used by explicit-repair decisions.
    /// DEBUG-only QA fixture may force the UNTRUSTED input for labelled
    /// probes/screenshots (never a TCC change); production always reads
    /// the real probe.
    private var currentAccessibilityTrusted: Bool {
#if DEBUG
        if pendingQAaxUntrusted { return false }
#endif
        return holdToTalk.accessibilityTrusted
    }

    /// Presents the compact targeted-repair card window (design 7:385).
    /// EXPLICIT-ONLY presenter (2026-11-07 launch-repair routing fix):
    /// reached from the status-menu "Repair Hold-to-Talk…" item (through
    /// `presentReadinessRepairIfBroken`, which re-validates the live
    /// policy) or the DEBUG QA host — never from launch routing. Skip
    /// and window close only dismiss — nothing resets.
    func presentHoldGuideRepairCard() {
        if holdGuideRepairCardController == nil {
#if DEBUG
            // Labelled QA screenshot fixture only (never set in production).
            holdGuideRepairCardController = HoldGuideRepairCardController(
                holdToTalk: holdToTalk,
                prefs: prefs,
                qaAppearance: pendingQAAppearance,
                qaRepairState: pendingQARepairCardState
            )
#else
            holdGuideRepairCardController = HoldGuideRepairCardController(
                holdToTalk: holdToTalk,
                prefs: prefs
            )
#endif
        }
        holdGuideRepairCardController?.showAndFront()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Never assign `item.menu` permanently — that turns left-click into menu-only
        // and was a primary cause of “click does nothing / doesn’t open typing.”
        item.menu = nil
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "calendar.badge.plus",
                accessibilityDescription: "QuikCal"
            )
            button.toolTip = "QuikCal — click to capture, right-click for Settings"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isSecondary {
            _ = AppLaunchRouter.statusItemSecondaryAction()
            showStatusMenu()
        } else {
            _ = AppLaunchRouter.statusItemPrimaryAction()
            toggleCapturePanel()
        }
    }

    private func showStatusMenu() {
        // Fresh, honest, read-only probe before the menu is built so the
        // explicit Repair item (below) reflects CURRENT trust — the same
        // refresh the app-activation observer performs. Its honest
        // fail-safe (stop monitoring when trust was revoked) is the
        // designed behavior, unchanged.
        holdToTalk.refreshPermissionFlags()
        let menu = NSMenu()
        // Explicit setup path: a double-click on an already-running menu-bar
        // app delivers reopen (incomplete → onboarding, completed → Settings),
        // but the user must also be able to reach Setup from the menu itself.
        // Name reflects state: Start (incomplete) vs Replay (completed).
        // Never resets prefs on its own — Replay goes through the same
        // explicit beginOnboardingReplay() the Settings button uses.
        // (2026-11-07 repair: action + title come from the pinned, tested
        // AppLaunchRouter policy — not inline AppKit glue.)
        let menuSetupAction = AppLaunchRouter.statusMenuSetupAction(
            onboardingCompleted: prefs.onboardingCompleted
        )
        menu.addItem(withTitle: AppLaunchRouter.statusMenuSetupTitle(for: menuSetupAction),
                     action: #selector(setupAction),
                     keyEquivalent: "")
        // 2026-11-07 launch-repair routing fix: the targeted repair card is
        // EXPLICIT-only. The menu item is offered solely while the LIVE
        // decision says repair (truthful, intent-based, recomputed each
        // time the menu opens — no persisted latch), and the action
        // re-validates before presenting. When hold-to-talk works, no
        // repair item appears at all.
        if LaunchRepairPresentationPolicy.offersExplicitRepairAction(decision: currentRepairDecision()) {
            menu.addItem(withTitle: "Repair Hold-to-Talk…",
                         action: #selector(repairHoldToTalkAction),
                         keyEquivalent: "")
        }
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        // 0.3.19 Sparkle updates: manual check entry (automatic checks run
        // in the background and notify via Sparkle's native alert). Enabled
        // state comes from the live `canCheckForUpdates` (service
        // unavailable → the item is honestly disabled, never a dead action).
        let updateItem = menu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(AppUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = appUpdater
        updateItem.isEnabled = appUpdater.canCheckForUpdates
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit QuikCal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Pop up without assigning `statusItem.menu` (avoids sticky menu-only left-click).
        guard let button = statusItem?.button else { return }
        let point = NSPoint(x: 0, y: button.bounds.height + 2)
        menu.popUp(positioning: nil, at: point, in: button)
    }

    @objc private func openSettingsAction() { openSettings() }

    @objc private func setupAction() {
        // Manual reopen (2026-11-07 repair): the pinned routing policy
        // decides — incomplete resumes the journey exactly where the
        // cursor left off; completed goes through the explicit replay
        // (which resets ONLY completion + cursor, never user data).
        switch AppLaunchRouter.statusMenuSetupAction(onboardingCompleted: prefs.onboardingCompleted) {
        case .resumeIncompleteJourney:
            openOnboarding(force: true)
        case .replayCompletedSetup:
            beginOnboardingReplay()
        }
    }

    /// Explicit status-menu repair action (2026-11-07 launch-repair
    /// routing fix): the ONLY production path that can present the
    /// targeted repair card. Re-validates the live policy — if trust
    /// arrived between menu-open and click, nothing presents (honest).
    @objc private func repairHoldToTalkAction() {
        presentReadinessRepairIfBroken()
    }

    func toggleCapturePanel() {
        // Opening capture dismisses the menu-bar hint (brief §1).
        MenuBarCoachmarkPresenter.shared.dismiss()
        viewModel.prepareForPopoverOpen()
        capturePanel.updateRootView(captureRoot)
        if capturePanel.isVisible {
            // 0.3.21 review fix (F1): toggle goes through the SAME
            // draft-preserving dismiss path as every other dismissal —
            // in-bar dictation cancelled, status cleared — never a bare
            // panel.dismiss that orphans the mic.
            dismissCaptureBar(reason: .toggleClosed)
        } else {
            // Spotlight-style: order above the frontmost app (not only when we are focused).
            viewModel.barAvailableHeight = captureTargetVisibleFrame().height
            capturePanel.present()
            viewModel.requestCaptureFieldFocus()
        }
    }

    // MARK: - Capture panel

    /// Visible frame of the display the capture panel targets (mouse
    /// screen, else primary) — bounds the capsule's downward growth.
    private func captureTargetVisibleFrame() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let screen = screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? screens.first
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
    }

    private func setupCapturePanel() {
        capturePanel.attach(rootView: captureRoot)
        // 0.3.21 review fix (F1): ONE shared draft-preserving dismiss path
        // for every dismissal — Escape, outside-click, toggle, and settings
        // handoff all route through `dismissCaptureBar(reason:)`.
        capturePanel.onEscape = { [weak self] in
            self?.dismissCaptureBar(reason: .escape)
        }
        capturePanel.onOutsideClick = { [weak self] in
            self?.dismissCaptureBar(reason: .outsideClick)
        }
        capturePanel.onDidPresent = { [weak self] in
            self?.viewModel.requestCaptureFieldFocus()
        }
        viewModel.onAfterSuccessfulAdd = { [weak self] in
            self?.resizePanelForSchedule()
        }
        viewModel.onRequestPanelResize = { [weak self] phase in
            self?.applyPanelSize(for: phase)
        }
        viewModel.onRequestBarHeight = { [weak self] height in
            self?.applyBarHeight(height)
        }
    }

    /// The ONE draft-preserving capture-bar dismissal (0.3.21 review fix
    /// F1): policy precondition, cancel any in-bar dictation (engine torn
    /// down, temp audio deleted, no transcription, no submit — never an
    /// orphan mic; `finishing` is intentionally left alone because the mic
    /// is already released and the transcript lands in the draft field),
    /// clear the transient status, then hide the panel. Draft stays on the
    /// ViewModel; never a calendar write.
    private func dismissCaptureBar(reason: CapturePanelDismissReason) {
        precondition(CapturePanelPresentationPolicy.preservesDraft(on: reason))
        precondition(!CapturePanelPresentationPolicy.writesCalendar(on: reason))
        stopInBarRecordingIfActive()
        viewModel.statusMessage = nil
        capturePanel.dismiss(reason: reason)
    }

    /// 0.3.21: dismissing the bar must never leave an orphan mic. An
    /// in-bar dictation (mic button) is CANCELLED — engine torn down, temp
    /// audio deleted, no transcription, no submit. An in-flight
    /// transcription (`finishing`, mic already released) is left to
    /// complete into the draft field harmlessly.
    private func stopInBarRecordingIfActive() {
        if viewModel.speech.state == .requesting || viewModel.speech.state == .recording {
            viewModel.speech.cancel()
        }
    }

    private var captureRoot: some View {
        CaptureContentView(
            vm: viewModel,
            googleAuth: googleAuth,
            glassIntensity: Binding(
                get: { self.prefs.glassIntensity },
                set: { self.prefs.glassIntensity = $0 }
            ),
            onOpenSettings: { [weak self] in self?.openSettings() },
            onOpenOnboarding: { [weak self] in self?.openOnboarding(force: true) }
        )
    }

    /// 0.3.21 Spotlight capsule: current bar height (single-line default),
    /// updated by the view's measured requests via `applyBarHeight`.
    private var barHeight: CGFloat = CaptureBarSizingPolicy.capsuleHeight

    private func applyPanelSize(for phase: CapturePresentationPhase) {
        guard let panel = capturePanel.panel else { return }
        let visibleWidth = panel.screen?.visibleFrame.width ?? 1440
        let width = CaptureBarSizingPolicy.barWidth(visibleFrameWidth: visibleWidth)
        let height: CGFloat
        switch phase {
        case .note, .listening, .parsing:
            // Single compact capsule; wrapped input grows it downward.
            height = barHeight
        case .confirmation:
            // 0.3.17: the full event review (wrapping title + description,
            // edit disclosure) gets a taller panel; the review content
            // itself scrolls when it exceeds this, with Yes/No pinned.
            height = 420
        case .daySchedule:
            height = 420
        }
        var frame = panel.frame
        let deltaH = height - frame.size.height
        frame.origin.y -= deltaH
        frame.size = NSSize(width: width, height: height)
        panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Applies a measured capsule-height request from the capture view.
    /// Only the bar phases follow it — the expanded confirmation / day
    /// review surfaces keep their own properly sized panels — and the
    /// panel is only resized while actually visible (no hidden-window
    /// churn from model/timer updates).
    private func applyBarHeight(_ requested: CGFloat) {
        let clamped = requested.rounded()
        guard clamped != barHeight else { return }
        barHeight = clamped
        guard let panel = capturePanel.panel, panel.isVisible else { return }
        switch viewModel.presentationPhase {
        case .note, .listening, .parsing:
            applyPanelSize(for: viewModel.presentationPhase)
        case .confirmation, .daySchedule:
            break
        }
    }

    private func resizePanelForSchedule() {
        applyPanelSize(for: .daySchedule)
    }

    // MARK: - Hold to talk

    /// Wires the confirmed-Add Google write path: the ViewModel asks this
    /// provider at write time. It returns a sink bound to the ACTIVE linked
    /// account and that account's chosen target calendar, or nil (→ clear
    /// "not ready" message). No destination is ever guessed or defaulted.
    /// The UI Add gate reads the LIVE readiness verdict from the same service
    /// (googleReadinessProvider) — ready requires a signed-in account with
    /// usable tokens and a selected calendar in that account's current
    /// writable list; every other state fails closed with a reason.
    private func wireGoogleWriter() {
        viewModel.googleWriterProvider = { [weak self] in
            guard let self, let account = self.googleAuth.activeAccount,
                  let calendarID = account.targetCalendarID, !calendarID.isEmpty else {
                return nil
            }
            let sink = GoogleCalendarWriteSink(
                accountID: account.id,
                clientID: self.googleAuth.config.clientID,
                clientSecret: self.googleAuth.config.clientSecret,
                vault: self.googleAuth.tokenVault,
                calendarSummary: account.targetCalendarSummary ?? calendarID,
                onReauthRequired: { [weak self] in
                    // invalid_grant observed on a real write: flip the gate
                    // closed so the next Add requires re-consent.
                    self?.googleAuth.markReauthRequired(accountID: account.id)
                }
            )
            return .init(
                sink: sink,
                calendarID: calendarID,
                calendarSummary: account.targetCalendarSummary ?? calendarID
            )
        }
        viewModel.googleReadinessProvider = { [weak self] in
            self?.googleAuth.destinationReadiness
        }
    }

    private func wireHoldToTalk() {
        // The Glass slider drives the REAL voice pill's background too
        // (2026-11-07): read the live persisted preference at show time.
        voiceOverlay.glassIntensityProvider = { [weak self] in
            self?.prefs.glassIntensity ?? 0.65
        }
        // P0 processing backstop (95 s MAX, never a default wait): fires
        // only when the whole release→transcribe→parse chain produced no
        // observable signal. It CANCELS the underlying generation/tasks so
        // a late completion can never overwrite the resolved UI, then
        // surfaces an honest Retry/Type message in the panel.
        voiceOverlay.onProcessingBackstop = { [weak self] in
            guard let self else { return }
            self.viewModel.cancelHoldToTalk()
            self.viewModel.cancelParse()
            self.viewModel.holdOutcome = .needsAttention(HoldOutcomeCopy.backstopCopy)
            self.viewModel.statusMessage = HoldOutcomeCopy.backstopCopy
            self.voiceOverlay.hide()
            self.presentCapturePanelForConfirmation()
        }
        // Fn / shortcut hold shows the compact top-center listening pill —
        // never the full capture panel, never focus theft. Release shows a
        // brief "Working…" pill while parsing, then the EXISTING explicit
        // confirmation panel appears (parse → confirm, never auto-write).
        holdToTalk.onBeginHold = { [weak self] in
            guard let self else { return }
            precondition(!AppLaunchRouter.holdToTalkOpensConfiguration())
            self.beginHoldToTalkWithPill()
        }
        holdToTalk.onEndHold = { [weak self] in
            self?.endHoldToTalkWithPill()
        }
        // FAIL-SAFE cancel path (2026-11-07): a hold that ends WITHOUT a
        // trusted release — listener paths died mid-hold, Accessibility
        // was lost, hold-to-talk was turned off, the watchdog confirmed a
        // lost release, the recording cap elapsed, or the app is quitting.
        // The recording is TERMINATED with no transcription, no parse, no
        // submit — nothing from an untrusted termination can reach the
        // calendar.
        holdToTalk.onCancelHold = { [weak self] reason in
            self?.cancelHoldToTalkWithPill(reason: reason)
        }
        observeHoldOutcome()
    }

    /// Gate + pill presentation on hold. Blocked reasons (model / mic) are
    /// concise and visible — a hold can never silently do nothing.
    ///
    /// 0.3.11 first-time mic flow: a hold on the user's selected shortcut IS
    /// explicit intent, so a never-asked microphone may be requested through
    /// the official `AVCaptureDevice.requestAccess` from that hold (never on
    /// launch / permission pages / downloads). The prompting hold never
    /// records; recording starts on the next hold — or on the SAME hold only
    /// if the key is still physically held and state is safe when the grant
    /// returns (never an auto recording after release or a delayed grant).
    private func beginHoldToTalkWithPill() {
        if holdToTalk.practicePreviewOnly {
            // Onboarding practice preview: pill only, no mic, no capture.
            voiceOverlay.show(.listening(preview: nil, amplitude: 0))
            return
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        // Distinguish never-asked (nil) from denied (false) so the pill's
        // guidance is honest in both states (see VoiceOverlayPolicy.gate).
        let micGranted: Bool? = micStatus == .authorized ? true : (micStatus == .notDetermined ? nil : false)
        let modelReady = viewModel.speech.modelReadiness == .ready
        if micGranted == nil, modelReady {
            // First hold, mic never asked: the hold itself is the reachable
            // request action. Show the concise pill, fire the official
            // prompt, and require the next hold (or a still-active hold) to
            // record — no silent blocked loop.
            requestMicFromHoldIntent()
            return
        }
        // P0 SYMMETRIC BEGIN: decide the outcome from the typed policy —
        // the pill claims Listening ONLY when capture actually started.
        let started = viewModel.beginHoldToTalk()
        let outcome = HoldBeginPolicy.outcome(
            screenIsConfirm: viewModel.screen == .confirm,
            modelReady: modelReady,
            micPermissionGranted: micGranted,
            captureStarted: started
        )
        switch outcome {
        case .started:
            holdStartedSpeech = true
            voiceOverlay.show(.listening(preview: nil, amplitude: 0))
        case .blockedConfirmOpen:
            // The confirm screen is open: show the honest blocked reason
            // (auto-dismisses) — never a fake Listening pill, never a mic.
            holdStartedSpeech = false
            voiceOverlay.show(.blocked(reason: HoldOutcomeCopy.confirmOpenBlockedCopy))
        case .blocked(let reason):
            holdStartedSpeech = false
            voiceOverlay.show(.blocked(reason: reason))
        case .micPromptPending:
            holdStartedSpeech = false
            voiceOverlay.show(.blocked(reason: VoiceOverlayPolicy.micNotDeterminedCopy))
        }
    }

    /// Fires the official system mic prompt from the user's hold intent and
    /// shows a concise pill. One request in flight at a time; repeated hold
    /// presses while the system alert is up never stack prompts.
    private func requestMicFromHoldIntent() {
        holdStartedSpeech = false
        voiceOverlay.show(.blocked(reason: VoiceOverlayPolicy.micNotDeterminedCopy))
        guard !micRequestInFlight else { return }
        micRequestInFlight = true
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.micRequestInFlight = false
                self.finishHoldMicRequest(granted: granted)
            }
        }
    }

    @MainActor
    private func finishHoldMicRequest(granted: Bool) {
        if granted {
            // Continue the CURRENT hold only if the key is still physically
            // held and the capture state is safe; otherwise require the
            // next hold — never an auto recording after release.
            let holdStillActive = holdToTalk.machine.phase == .holding
            // Fail-safe cross-check: the phase above is monitor-event
            // derived and could be stale if the release event was swallowed
            // while the system mic prompt had key focus. The live HID
            // modifier state is the authority — a key that is not physically
            // down right now can never continue into recording.
            let keyPhysicallyDown = holdToTalk.shortcutKeyPhysicallyDown
            let screenSafe = viewModel.screen == .note
            let speechIdle = viewModel.speech.state == .idle
            if HoldToTalkLaunchPolicy.shouldContinueHoldAfterMicGrant(
                holdStillActive: holdStillActive,
                keyPhysicallyDown: keyPhysicallyDown,
                screenSafeForCapture: screenSafe,
                speechIdle: speechIdle
            ) {
                // P0 symmetric begin: only claim Listening when capture
                // actually started.
                let started = viewModel.beginHoldToTalk()
                holdStartedSpeech = started
                voiceOverlay.show(
                    started
                        ? .listening(preview: nil, amplitude: 0)
                        : .blocked(reason: HoldOutcomeCopy.confirmOpenBlockedCopy)
                )
            } else {
                holdStartedSpeech = false
                voiceOverlay.show(.blocked(reason: VoiceOverlayPolicy.micGrantedNextHoldCopy))
            }
        } else {
            holdStartedSpeech = false
            voiceOverlay.show(.blocked(reason: VoiceOverlayPolicy.micDeniedCopy))
        }
    }

    private func endHoldToTalkWithPill() {
        guard holdStartedSpeech else {
            // Blocked pill or practice preview — just dismiss.
            voiceOverlay.hide()
            return
        }
        holdStartedSpeech = false
        // P0 (preflight P1/P2): release with NOTHING actually recording
        // (the begin was gated, or capture already failed / cancelled in
        // the requesting race) — resolve IMMEDIATELY with the honest typed
        // outcome. Never enter a terminal "Working…" state.
        if HoldEndPolicy.outcome(
            speechStateIsIdle: viewModel.speech.state == .idle,
            speechMessagePending: viewModel.speech.message != nil
        ).isImmediateResolution {
            voiceOverlay.hide()
            viewModel.endHoldToTalk()
            presentCapturePanelForConfirmation()
            return
        }
        // Normal release: phase-specific processing pill (Transcribing →
        // Understanding), bounded by the 95 s backstop.
        voiceOverlay.show(.processing(phase: .transcribing))
        viewModel.endHoldToTalk()
    }

    /// FAIL-SAFE cancel (privacy/correctness fix 2026-11-07): the hold
    /// ended WITHOUT a trusted release (listener paths died mid-hold,
    /// Accessibility was lost, hold-to-talk was turned off, the watchdog
    /// confirmed a lost release / hit the recording cap, or the app is
    /// quitting). The recording is TERMINATED — `viewModel.cancelHoldToTalk`
    /// cancels the speech capture (engine torn down, inference cancelled,
    /// temp audio deleted) WITHOUT the release→transcribe→parse→submit
    /// path — and the pill states the honest reason. `.appTerminating`
    /// shows no pill (the app is quitting). `holdStartedSpeech` is
    /// cleared so no later release event can double-process.
    private func cancelHoldToTalkWithPill(reason: HoldToTalkCancelReason) {
        holdStartedSpeech = false
        viewModel.cancelHoldToTalk()
        guard reason != .appTerminating else { return }
        voiceOverlay.show(.blocked(reason: VoiceOverlayPolicy.holdCancelCopy(for: reason)))
    }

    /// Hands off from the pill to the existing capture panel once the parse
    /// outcome is ready (confirmation / clarification / error). Watching
    /// `isParsing` covers every outcome without touching the ViewModel's
    /// pipeline; typed submissions never show the pill (state-gated).
    private func observeHoldOutcome() {
        holdParsingObservation = viewModel.$isParsing
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] parsing in
                guard let self else { return }
                if parsing {
                    if case .processing = self.voiceOverlay.state {
                        // Phase-specific honest status (P0): parse in flight.
                        self.voiceOverlay.show(.processing(phase: .understanding))
                    }
                } else if case .processing = self.voiceOverlay.state {
                    self.voiceOverlay.hide()
                    self.presentCapturePanelForConfirmation()
                }
            }
        // Speech failed during/after a hold (no parse ran): surface the
        // reason in the existing panel instead of leaving a stuck pill.
        speechMessageObservation = viewModel.speech.$message
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self, message != nil, self.voiceOverlay.isProcessingState else { return }
                self.voiceOverlay.hide()
                self.presentCapturePanelForConfirmation()
            }
        // P0 typed-outcome observation: EVERY terminal path of a
        // hold-originated flow resolves the pill (submitted outcomes are
        // owned by the isParsing observation above).
        holdOutcomeObservation = viewModel.$holdOutcome
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outcome in
                guard let self, let outcome else { return }
                guard self.voiceOverlay.isProcessingState else { return }
                if case .submitted = outcome { return }
                self.voiceOverlay.hide()
                self.presentCapturePanelForConfirmation()
            }
        // P2 live feedback: forward the genuine rolling preview + real
        // amplitude to the expanding pill WHILE CAPTURING (state-gated to
        // the listening pill — typed/mic-button flows never show it).
        livePreviewObservation = viewModel.speech.$partialTranscript
            .combineLatest(viewModel.speech.$amplitude)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] partial, amplitude in
                guard let self else { return }
                guard case .listening = self.voiceOverlay.state else { return }
                self.voiceOverlay.updateLive(
                    preview: partial.isEmpty ? nil : LiveVoicePreview(text: partial),
                    amplitude: amplitude
                )
            }
        // P2 amplitude-only updates at ~20 Hz even when the preview text
        // has not changed (the waveform must keep moving with real sound).
        liveAmplitudeObservation = viewModel.speech.$amplitude
            .receive(on: DispatchQueue.main)
            .sink { [weak self] amplitude in
                guard let self else { return }
                guard case .listening = self.voiceOverlay.state else { return }
                self.voiceOverlay.updateLive(preview: nil, amplitude: amplitude)
            }
    }

    /// Presents the existing full capture panel for the confirmation step
    /// (same presentation path as a manual open — same policy preconditions).
    private func presentCapturePanelForConfirmation() {
        guard !capturePanel.isVisible else { return }
        capturePanel.updateRootView(captureRoot)
        viewModel.barAvailableHeight = captureTargetVisibleFrame().height
        capturePanel.present()
        viewModel.requestCaptureFieldFocus()
    }

    // MARK: - Onboarding / settings

    /// 0.3.21 gear handoff: hide the floating capture bar before another
    /// QuikCal window (Settings / onboarding) comes up in front of the
    /// user. Draft preserved, in-bar dictation cancelled, no re-present —
    /// the bar returns only on the user's next hotkey/menu toggle.
    private func dismissCaptureBarForHandoff() {
        guard capturePanel.isVisible else { return }
        dismissCaptureBar(reason: .settingsHandoff)
    }

    func openOnboarding(force: Bool, launchAuto: Bool = false, setupGap: EssentialSetupGap? = nil) {
#if DEBUG
        if let qa = QAHostRouter.parse(arguments: ProcessInfo.processInfo.arguments) {
            if let page = qa.page {
                var guide = HoldToTalkGuideState()
                if let phaseRaw = qa.holdGuidePhase,
                   let phase = HoldToTalkGuidePhase(rawValue: phaseRaw) {
                    guide.phase = phase
                }
                let session = OnboardingSessionState(
                    page: page,
                    skipped: [],
                    practiceNote: "",
                    holdGuide: guide
                )
                prefs.saveOnboardingResume(session)
            }
            if let pct = qa.glassPercent {
                prefs.glassIntensity = pct / 100.0
            }
            if let destination = qa.destination, !destination.isEmpty {
                // Ephemeral QA-domain fixture pref only — labelled, never
                // the owner's real defaults.
                prefs.calendarDestinationKind = CalendarDestinationKind(rawValue: destination) ?? .eventKit
            }
            if let state = qa.modelsState, !modelDownload.isQAFixtureActive {
                modelDownload.applyQAFixture(state)
            }
        }
#endif
        // 0.3.21 gear-handoff parity: opening onboarding from the capture
        // bar's inline fallback hides the floating bar first — same
        // settingsHandoff draft-preserving path as the gear button.
        dismissCaptureBarForHandoff()
        // Recreate so resume/replay state is loaded into a fresh hosting controller.
        pendingLaunchEntryCard = launchAuto
        // Completed-but-unready launch (2026-11-07 installed-runtime repair):
        // map the gap to its step here; the window opens directly on it.
        pendingSetupGapPage = setupGap.map { AppLaunchRouter.setupResumePage(gap: $0) }
        if force, onboardingController != nil {
            onboardingController?.close()
            onboardingController = nil
        }
        if onboardingController == nil {
            let forReplay = pendingOnboardingReplay
            let guideOnly = pendingHoldGuideOnly
            let setupGapPage = pendingSetupGapPage
            pendingOnboardingReplay = false
            pendingHoldGuideOnly = false
            pendingSetupGapPage = nil
#if DEBUG
            let initialPhase = pendingInitialHoldPhase
            pendingInitialHoldPhase = nil
            let qaAX = pendingQAaxTrusted
            let qaLoc = pendingQAAppLocation
            let qaDetails = pendingQADetailsExpanded
            let qaAXUntrusted = pendingQAaxUntrusted
            pendingQAaxTrusted = false
            pendingQAaxUntrusted = false
            pendingQAAppLocation = nil
            pendingQADetailsExpanded = false
            let qaAppearance = pendingQAAppearance
            let qaEntryCardOff = pendingQAEntryCardSuppressed
            let qaGoogleConfig = pendingQAGoogleConfigFixture
            let qaPracticeKey = pendingQAPracticeKeyFixture
            pendingQAAppearance = nil
            pendingQAEntryCardSuppressed = false
            pendingQAGoogleConfigFixture = false
            pendingQAPracticeKeyFixture = nil
            onboardingController = OnboardingWindowController(
                viewModel: viewModel,
                googleAuth: googleAuth,
                holdToTalk: holdToTalk,
                prefs: prefs,
                modelDownload: modelDownload,
                forReplay: forReplay,
                holdGuideOnly: guideOnly,
                initialHoldGuidePhase: initialPhase,
                qaAXTrusted: qaAX,
                qaAXUntrusted: qaAXUntrusted,
                qaAppLocation: qaLoc,
                qaDetailsExpanded: qaDetails,
                qaAppearance: qaAppearance,
                qaEntryCardSuppressed: qaEntryCardOff,
                qaGoogleConfigFixture: qaGoogleConfig,
                qaPracticeKeyFixture: qaPracticeKey.flatMap(OnboardingVoiceVisualPolicy.PracticeKeyState.init(rawValue:)),
                setupGapPage: setupGapPage,
                launchEntryCard: pendingLaunchEntryCard,
                onOpenSettings: { [weak self] in self?.openSettings() }
            )
#else
            onboardingController = OnboardingWindowController(
                viewModel: viewModel,
                googleAuth: googleAuth,
                holdToTalk: holdToTalk,
                prefs: prefs,
                modelDownload: modelDownload,
                forReplay: forReplay,
                holdGuideOnly: guideOnly,
                setupGapPage: setupGapPage,
                launchEntryCard: pendingLaunchEntryCard,
                onOpenSettings: { [weak self] in self?.openSettings() }
            )
#endif
            onboardingController?.onFinished = { [weak self] in
                guard let self else { return }
                let wasGuideOnly = guideOnly
                self.onboardingController?.close()
                self.onboardingController = nil
                if wasGuideOnly {
                    // Do not reset completion / prefs — Settings reopen only.
                    // A completed user must not keep a stale resume cursor.
                    if self.prefs.onboardingCompleted {
                        self.prefs.clearOnboardingResume()
                    }
                    return
                }
                self.prefs.onboardingCompleted = true
                self.prefs.clearOnboardingResume()
                // 0.3.2: finish shows the real menu-bar coachmark (anchored to
                // the live NSStatusItem.button frame) instead of auto-opening
                // capture. Dismissing the hint never re-runs onboarding.
                self.presentMenuBarCoachmark()
            }
        }
        onboardingController?.showWindow(nil)
        bringWindowToFront(onboardingController?.window)
    }

    /// LSUIElement accessory apps are not activated by Finder double-click the
    /// way regular apps are: `showWindow` alone can leave the window ordered
    /// behind the frontmost app, which read as "double-click does nothing".
    /// Force the window to the front of its level regardless of activation,
    /// make it key, then activate the app — all three, because on macOS 14 an
    /// accessory app's activation can lose the race with LaunchServices.
    private func bringWindowToFront(_ window: NSWindow?) {
        guard let window else { return }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func beginOnboardingReplay() {
        pendingOnboardingReplay = true
        pendingHoldGuideOnly = false
        prefs.resetOnboardingCompletion()
        openOnboarding(force: true)
    }

    func openHoldToTalkGuideFromSettings() {
        // Reopen guide without wiping calendar / glass / shortcut / completion.
        pendingHoldGuideOnly = true
        pendingOnboardingReplay = false
        openOnboarding(force: true)
    }

    func openSettings() {
        // 0.3.21 gear focus-trap fix: the capture bar lives at the floating
        // window level — if it stays visible when Settings (a normal-level
        // window) comes up, it floats ABOVE Settings and the user cannot
        // get out (outside-click is deliberately ignored for our own key
        // windows, and Escape goes to the key window, i.e. Settings). So
        // the bar is hidden FIRST, preserving the draft and cancelling any
        // in-bar dictation safely. Settings closing never revives the bar;
        // the user reopens it with the hotkey/menu as usual.
        if capturePanel.isVisible {
            dismissCaptureBarForHandoff()
        }
        if settingsController == nil {
            settingsController = SettingsWindowController(
                viewModel: viewModel,
                googleAuth: googleAuth,
                holdToTalk: holdToTalk,
                prefs: prefs,
                modelDownload: modelDownload,
                appUpdater: appUpdater,
                onReplayOnboarding: { [weak self] in
                    self?.beginOnboardingReplay()
                },
                onOpenHoldGuide: { [weak self] in
                    self?.openHoldToTalkGuideFromSettings()
                },
                onShowMenuBarHint: { [weak self] in
                    self?.presentMenuBarCoachmark()
                }
            )
        }
        settingsController?.showWindow(nil)
        bringWindowToFront(settingsController?.window)
    }

    func replayOnboardingFromSettings() {
        beginOnboardingReplay()
    }

    /// Present the menu-bar coachmark anchored to the real status-item button.
    /// Used on onboarding finish and from Settings “Show menu bar hint”.
    /// Falls back to written instructions + Open Settings when the frame is
    /// unavailable (hidden menu bar, notch, offscreen) — never a fake pointer.
    func presentMenuBarCoachmark() {
        let button = statusItem?.button
        let screen = button.flatMap { btn in btn.window?.screen } ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        let fullFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        MenuBarCoachmarkPresenter.shared.present(
            anchoredTo: button,
            visibleFrame: visibleFrame,
            fullFrame: fullFrame,
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        prefs.showMenuBarHint = false
    }
}
