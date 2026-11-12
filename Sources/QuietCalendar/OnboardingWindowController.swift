import AppKit
import SwiftUI
import QuietCalendarCore

@MainActor
final class OnboardingWindowController: NSWindowController {
    var onFinished: (() -> Void)?

    init(
        viewModel: AppViewModel,
        googleAuth: GoogleOAuthService,
        holdToTalk: HoldToTalkMonitor,
        prefs: AppPreferencesStore,
        modelDownload: ParakeetModelDownloadController = .shared,
        forReplay: Bool = false,
        holdGuideOnly: Bool = false,
        /// DEBUG QA host only: open the guide directly on this phase via the
        /// SAME production phase machine. Production callers pass nil and get
        /// the normal pick-shortcut entry.
        initialHoldGuidePhase: HoldToTalkGuidePhase? = nil,
        /// DEBUG QA fixtures only (0.3.6): labelled screenshots, never a
        /// real permission grant. Production callers leave defaults.
        qaAXTrusted: Bool = false,
        /// DEBUG QA fixture only (2026-11-07 review): render the UNTRUSTED
        /// permission UI even when the QA process's REAL Accessibility
        /// trust is inherited from the owner's TCC grant (same signed app
        /// identity). Labelled in-frame; display only, never a TCC change.
        qaAXUntrusted: Bool = false,
        qaAppLocation: String? = nil,
        /// DEBUG QA fixture only (0.3.7): open the Details disclosure.
        qaDetailsExpanded: Bool = false,
        /// DEBUG QA fixture only (0.3.13 cards pass): force the window's
        /// AppKit appearance (light|dark) for labelled screenshots.
        qaAppearance: String? = nil,
        /// DEBUG QA fixture only (0.3.13 cards pass): suppress the launch
        /// entry card so individual step scenes capture directly.
        qaEntryCardSuppressed: Bool = false,
        /// DEBUG QA fixture only (0.3.13 cards pass): the Google client
        /// config is a placeholder env fixture — label it in-frame.
        qaGoogleConfigFixture: Bool = false,
        /// DEBUG QA fixture only (0.3.13 cards pass): force the practice
        /// key cap state for labelled screenshots (never a real hold).
        qaPracticeKeyFixture: OnboardingVoiceVisualPolicy.PracticeKeyState? = nil,
        /// Completed-but-unready launch surfacing (2026-11-07
        /// installed-runtime repair): open DIRECTLY on this broken setup
        /// step (never the entry card, never a pref reset). nil for every
        /// other open.
        setupGapPage: OnboardingPage? = nil,
        /// True when LAUNCH ROUTING opened this window for an incomplete
        /// profile (cold start / reopen) — shows the approved launch
        /// setup/resume card (design 7:330/7:349) as the opening content.
        /// Explicit user actions (menu Start Setup…, replay, capture) pass
        /// false and enter the flow directly, as before.
        launchEntryCard: Bool = false,
        /// "Open Settings" action for the launch entry card.
        onOpenSettings: @escaping () -> Void = {}
    ) {
        let baseRoot = OnboardingView(
            vm: viewModel,
            googleAuth: googleAuth,
            holdToTalk: holdToTalk,
            modelDownload: modelDownload,
            prefs: prefs,
            forReplay: forReplay,
            holdGuideOnly: holdGuideOnly,
            initialHoldGuidePhase: initialHoldGuidePhase,
            qaAXTrusted: qaAXTrusted,
            qaAXUntrusted: qaAXUntrusted,
            qaAppLocation: qaAppLocation,
            qaDetailsExpanded: qaDetailsExpanded,
            qaAppearance: qaAppearance,
            qaEntryCardSuppressed: qaEntryCardSuppressed,
            qaGoogleConfigFixture: qaGoogleConfigFixture,
            qaPracticeKeyFixture: qaPracticeKeyFixture,
            setupGapPage: setupGapPage,
            launchEntryCard: launchEntryCard,
            onOpenSettings: onOpenSettings,
            onFinished: {}
        )
#if DEBUG
        // DEBUG-only larger-text QA fixture (0.3.5): same production view,
        // larger Dynamic Type injected — compiled out of Release.
        let root: AnyView = {
            if let qa = QAHostRouter.parse(arguments: ProcessInfo.processInfo.arguments),
               let ts = qa.textSize {
                switch ts {
                case "xxxlarge": return AnyView(baseRoot.dynamicTypeSize(.accessibility1))
                case "large": return AnyView(baseRoot.dynamicTypeSize(.large))
                default: return AnyView(baseRoot)
                }
            }
            return AnyView(baseRoot)
        }()
        let host = NSHostingController(rootView: root)
#else
        let host = NSHostingController(rootView: baseRoot)
#endif
        // 0.3.13 follow-up (owner request): Spotlight-like presentation —
        // borderless floating window (never hidden behind other apps'
        // windows, no red X close control, no accidental Cmd-W; the
        // accessory app has no main menu). Explicit Skip/Back/Continue
        // actions and Quit (status menu) remain the genuine escapes.
        // Yields to normal level on an Open Settings / Sign-in handoff so
        // System Settings, the OAuth browser, and security prompts are
        // never covered; restores floating when the app is activated.
        let window = FloatingCardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "QuikCal"
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentViewController = host
        window.center()
        window.isReleasedWhenClosed = false
        window.installFloatingLifecycle()
        // DEBUG QA fixture only: labelled light/dark screenshots. The
        // production window always follows the Mac's appearance.
        if qaAppearance == "dark" {
            window.appearance = NSAppearance(named: .darkAqua)
        } else if qaAppearance == "light" {
            window.appearance = NSAppearance(named: .aqua)
        }
        super.init(window: window)

        let finalRoot = OnboardingView(
            vm: viewModel,
            googleAuth: googleAuth,
            holdToTalk: holdToTalk,
            modelDownload: modelDownload,
            prefs: prefs,
            forReplay: forReplay,
            holdGuideOnly: holdGuideOnly,
            initialHoldGuidePhase: initialHoldGuidePhase,
            qaAXTrusted: qaAXTrusted,
            qaAXUntrusted: qaAXUntrusted,
            qaAppLocation: qaAppLocation,
            qaDetailsExpanded: qaDetailsExpanded,
            qaAppearance: qaAppearance,
            qaEntryCardSuppressed: qaEntryCardSuppressed,
            qaGoogleConfigFixture: qaGoogleConfigFixture,
            qaPracticeKeyFixture: qaPracticeKeyFixture,
            setupGapPage: setupGapPage,
            launchEntryCard: launchEntryCard,
            onOpenSettings: onOpenSettings,
            onCloseRequest: { [weak self] in
                // Close orders the window out WITHOUT completing onboarding;
                // the status-menu Start/Replay Setup path stays available.
                self?.close()
            },
            onMinimizeRequest: { [weak self] in
                self?.window?.miniaturize(nil)
            },
            onZoomRequest: { [weak self] in
                self?.window?.zoom(nil)
            },
            onFinished: { [weak self] in
                self?.onFinished?()
            }
        )
#if DEBUG
        host.rootView = {
            if let qa = QAHostRouter.parse(arguments: ProcessInfo.processInfo.arguments),
               let ts = qa.textSize {
                switch ts {
                case "xxxlarge": return AnyView(finalRoot.dynamicTypeSize(.accessibility1))
                case "large": return AnyView(finalRoot.dynamicTypeSize(.large))
                default: return AnyView(finalRoot)
                }
            }
            return AnyView(finalRoot)
        }()
#else
        host.rootView = finalRoot
#endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Palette / type

private enum OnboardTone {
    /// 2026-11-12 redesign: SF Pro system type via the shared tokens.
    static let brand = QuietDesign.Typography.display
    static let display = QuietDesign.Typography.title
    static let body = QuietDesign.Typography.body
    static let caption = QuietDesign.Typography.caption
    static let subtitle = QuietDesign.Typography.subtitle
    /// Soft sage — quiet, not purple / terracotta. Accent/rings ONLY
    /// (step dots, icons, checkmarks, slider tint, sample-tile waveform).
    static let accent = QuietDesign.Color.accent
    /// Deep sage #4e7a62 — the primary-button FILL.
    static let primaryFill = QuietDesign.Color.primaryFill
}

struct OnboardingView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var googleAuth: GoogleOAuthService
    @ObservedObject var holdToTalk: HoldToTalkMonitor
    @ObservedObject var modelDownload: ParakeetModelDownloadController
    var prefs: AppPreferencesStore
    var forReplay: Bool = false
    /// Settings reopen of hold-to-talk guide without resetting user data.
    var holdGuideOnly: Bool = false
    /// DEBUG QA host only (nil in production).
    var initialHoldGuidePhase: HoldToTalkGuidePhase? = nil
    /// DEBUG QA fixtures only (0.3.6): labelled, never a real grant.
    var qaAXTrusted: Bool = false
    /// DEBUG QA fixture only (2026-11-07 review): labelled UNTRUSTED view.
    var qaAXUntrusted: Bool = false
    var qaAppLocation: String? = nil
    /// DEBUG QA fixtures only (0.3.7): open the Details disclosure.
    var qaDetailsExpanded: Bool = false
    /// DEBUG QA fixtures only (0.3.13 cards pass): labelled screenshots.
    var qaAppearance: String? = nil
    var qaEntryCardSuppressed: Bool = false
    var qaGoogleConfigFixture: Bool = false
    var qaPracticeKeyFixture: OnboardingVoiceVisualPolicy.PracticeKeyState? = nil
    /// Completed-but-unready launch surfacing (2026-11-07
    /// installed-runtime repair): restore the session DIRECTLY on this
    /// broken setup step. Never resets the completion flag; never writes
    /// a resume cursor for a completed profile.
    var setupGapPage: OnboardingPage? = nil
    /// Launch-routing auto-open (cold start / reopen, incomplete profile):
    /// show the approved setup/resume entry card (design 7:330/7:349)
    /// before the flow. Explicit user opens keep the direct flow.
    var launchEntryCard: Bool = false
    /// "Open Settings" action for the entry card.
    var onOpenSettings: () -> Void = {}
    /// Title-bar window controls (2026-11-12 redesign). Close orders the
    /// window out WITHOUT completing onboarding; Minimize/Zoom forward to
    /// the window. The controller wires these to its own NSWindow.
    var onCloseRequest: () -> Void = {}
    var onMinimizeRequest: () -> Void = {}
    var onZoomRequest: () -> Void = {}
    var onFinished: () -> Void

    @State private var session = OnboardingSessionState()
    @State private var glassPreview: Double = 0.72
    @State private var appeared = false
    /// 0.3.13 launch entry card: dismissed by Start/Resume Setup — pure
    /// local state; no pref is read or written when it flips.
    @State private var launchCardDismissed = false
    /// 0.3.6 root pop: fires once per window presentation (this view's
    /// identity). Downloads / focus returns / step changes never reset it.
    @State private var poppedIn = false
    @State private var presentation = OnboardingPresentationTracker()
    @State private var detailsExpanded = false
    @State private var didRestoreSession = false
    @State private var shortcutSelection: HoldToTalkShortcutKind = .fn
    /// 0.3.13: Google config import from onboarding (mirrors Settings flow).
    @State private var isImportingGoogleConfig = false
    @State private var googleImportStatus: String?
    /// Instant destination selection: `AppPreferencesStore` is a plain
    /// UserDefaults struct (not observable), so binding the checkmark to
    /// `prefs` alone re-rendered only when some other publisher fired —
    /// which read as a multi-second lag when switching Mac ↔ Google.
    /// Mirror the choice locally and write through to prefs immediately.
    @State private var destinationKind: CalendarDestinationKind = .eventKit
    @Namespace private var destinationNS

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // 2026-11-12 redesign: solid neutral root from the shared tokens
            // (sampled from the approved Figma screens), following the Mac
            // appearance automatically.
            QuietDesign.Color.background(colorScheme)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                titleBar

                if launchCardVisible {
                    // 0.3.13 launch entry card (design 7:330/7:349): the
                    // OPENING CONTENT of a launch-routing open for an
                    // incomplete profile — same window, same routing, no
                    // new blocking surface. Bullets/progress rows are
                    // computed from live state; Start/Resume Setup only
                    // flips local state and reveals the restored session.
                    LaunchSetupCardView(
                        kind: launchCardKind,
                        onPrimary: {
                            // Local dismissal only — the restored session
                            // and its persisted cursor are untouched; no
                            // pref is read or written here.
                            animateStep { launchCardDismissed = true }
                        },
                        onOpenSettings: { onOpenSettings() }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 36)
                    .transition(stepTransition)

                    downloadBanner
                } else {
                    stepHeader
                    stepScene
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, QuietDesign.Metric.contentPadding)
                        .id(session.page)
                        .transition(stepTransition)

                    downloadBanner
                    bottomBar
                }
            }
        }
        .frame(width: 640, height: 600)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // 0.3.8: banner insertion/removal animates with the same Reduce
        // Motion contract as the pop (fade-only, no movement).
        .animation(
            reduceMotion
                ? .easeOut(duration: bannerMotion.durationSeconds)
                : .easeInOut(duration: bannerMotion.durationSeconds),
            value: downloadBannerVisible
        )
        // 0.3.6 root pop (content only — window frame/position untouched,
        // so no jump, shadow clipping, or black rectangle). Keyed to the
        // presentation identity, not the step: step changes keep it settled.
        .id(presentation.presentationID)
        .scaleEffect(poppedIn ? popSpec.finalScale : popSpec.initialScale)
        .opacity(poppedIn ? 1 : 0)
        .onAppear {
            if !didRestoreSession {
                if holdGuideOnly {
                    var guide = HoldToTalkGuideState(
                        shortcut: prefs.holdToTalkShortcut,
                        settingsReopen: true
                    )
                    if let phase = initialHoldGuidePhase { guide.phase = phase }
                    session = OnboardingSessionState(page: .voiceSetup, holdGuide: guide)
                } else if let setupGapPage {
                    // Completed-but-unready launch (2026-11-07
                    // installed-runtime repair): start directly on the
                    // broken step. The completion flag is NOT reset; the
                    // entry card stays hidden for completed profiles.
                    session = OnboardingSessionState(page: setupGapPage)
                } else {
                    session = prefs.makeOnboardingSession(forReplay: forReplay)
                }
                didRestoreSession = true
            }
            glassPreview = prefs.glassIntensity
            shortcutSelection = prefs.holdToTalkShortcut
            destinationKind = prefs.calendarDestinationKind
            session.holdGuide.shortcut = prefs.holdToTalkShortcut
            detailsExpanded = qaDetailsExpanded
            holdToTalk.refreshPermissionFlags()
            modelDownload.refresh()
            persistSession()
#if DEBUG
            QAPopLog.write("onAppear page=\(session.page.rawValue) phase=\(session.holdGuide.phase.rawValue) presentation=\(presentation.presentationID.uuidString) reduceMotion=\(reduceMotion) fadeOnly=\(popSpec.fadeOnly) duration=\(popSpec.durationSeconds)")
#endif
            if reduceMotion {
                appeared = true
                // Reduce Motion: short fade only, no scale pop.
                withAnimation(.easeOut(duration: popSpec.durationSeconds)) { poppedIn = true }
            } else {
                withAnimation(.easeOut(duration: 0.45)) { appeared = true }
                // One short spring pop per presentation (~0.28 s, 0.94 → 1).
                withAnimation(.spring(response: popSpec.durationSeconds, dampingFraction: 0.72)) { poppedIn = true }
            }
#if DEBUG
            QAPopLog.write("pop-start scale=\(popSpec.initialScale)->\(popSpec.finalScale) duration=\(popSpec.durationSeconds)s fadeOnly=\(popSpec.fadeOnly) presentation=\(presentation.presentationID.uuidString)")
            DispatchQueue.main.asyncAfter(deadline: .now() + popSpec.durationSeconds) {
                QAPopLog.write("pop-complete scheduledAt=+\(popSpec.durationSeconds)s poppedIn=\(poppedIn) presentation=\(presentation.presentationID.uuidString)")
            }
#endif
        }
        .onChange(of: poppedIn) { _, newValue in
#if DEBUG
            QAPopLog.write("poppedIn=\(newValue)")
#endif
        }
        .onChange(of: session.page) { _, newValue in
#if DEBUG
            // Step changes must keep the same presentation identity and must
            // never restart the pop.
            QAPopLog.write("page-change page=\(newValue.rawValue) presentation=\(presentation.presentationID.uuidString) poppedIn=\(poppedIn)")
#endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Recheck live permission state on reactivation — read-only
            // probes only; never auto-advance solely from focus, never a
            // prompt or request (0.3.8 policy picks the permission pages).
            guard OnboardingActivationRecheckPolicy.shouldRecheck(page: session.page) else { return }
#if DEBUG
            QAPopLog.write("reactivation page=\(session.page.rawValue) presentation=\(presentation.presentationID.uuidString) poppedIn=\(poppedIn)")
#endif
            if session.page == .calendar {
                // Returning from System Settings → honest EventKit status
                // refresh (granted / denied / not-determined + choices).
                // No requestAccess call happens here.
                vm.refreshSelection()
            }
            if session.page == .axPermission {
                // Dedicated Accessibility step (2026-11-07): returning from
                // System Settings runs one CHECK — never auto-success; the
                // real probe result lands through the $accessibilityTrusted
                // receiver below.
                holdToTalk.refreshPermissionFlags()
                axStepPhase = AXPermissionStepPolicy.phase(afterAppReturned: axStepPhase)
            }
            if session.page == .voiceSetup {
                holdToTalk.refreshPermissionFlags()
                if session.holdGuide.phase == .recheckPermission
                    || session.holdGuide.phase == .openSettings {
                    session.holdGuide.applyAccessibilityTrusted(holdToTalk.accessibilityTrusted)
                    persistSession()
                }
            }
        }
    }

    private func persistSession() {
        // A Settings hold-guide reopen — or a completed-but-unready launch
        // surface (2026-11-07 installed-runtime repair) — must never
        // (re)create a first-run resume cursor for an already-completed
        // user; that stale cursor is exactly what 0.3.6 clears. Incomplete
        // first-run still resumes.
        if (holdGuideOnly || setupGapPage != nil), prefs.onboardingCompleted {
            prefs.clearOnboardingResume()
            return
        }
        prefs.saveOnboardingResume(session)
    }

    // MARK: Launch entry card (design 7:330 / 7:349)

    /// The approved card shows only for a LAUNCH-ROUTING auto-open of an
    /// incomplete profile (cold start / reopen → onboarding window).
    /// Explicit user opens (menu Start Setup…, replay, capture button)
    /// keep the direct flow; completed users never see it.
    private var launchCardVisible: Bool {
        if launchCardDismissed { return false }
        if !launchEntryCard || forReplay || holdGuideOnly { return false }
        if prefs.onboardingCompleted { return false }
        if qaEntryCardSuppressed { return false }
        return true
    }

    /// The calendar's live stage — derived from the destination selection
    /// and the REAL EventKit / Google state, never hardcoded. Drives both
    /// the calendar scene and the primary-action label.
    private enum CalendarStage: Equatable {
        /// Mac calendars selected; EventKit not determined yet.
        case choosing
        /// EventKit granted or write-only — a real connection.
        case macConnected
        /// Google selected; account not signed in (or browser flow pending).
        case googleConnect
        /// Google selected; account signed in (destination picker shown).
        case googleConnected
        /// The last connection attempt failed or access was denied.
        case error
    }

    private var calendarStage: CalendarStage {
        if destinationKind == .google {
            switch googleAuth.phase {
            case .signedIn:
                return .googleConnected
            case .error:
                return .error
            case .unconfigured, .signedOut, .authorizing:
                return .googleConnect
            }
        }
        switch vm.accessPhase {
        case .granted, .writeOnly:
            return .macConnected
        case .denied:
            return .error
        default:
            return .choosing
        }
    }

    /// Real calendar-connection state for the card's honest bullets.
    /// 2026-11-07 owner correction: a WRITE-ONLY EventKit grant is still a
    /// real connection (events can be added to the default calendar) —
    /// the checkmark must reflect it, not demand full access for the UI.
    private var calendarConnectedNow: Bool {
        if destinationKind == .google {
            return googleAuth.phase == .signedIn
        }
        return vm.accessPhase == .granted || vm.accessPhase == .writeOnly
    }

    /// Card content is computed from LIVE state only — never hardcoded
    /// success, never the design's example values.
    private var launchCardKind: LaunchSetupCardKind {
        LaunchSetupCardPolicy.cardKind(
            cursorPage: session.page,
            skipped: session.skipped,
            calendarConnected: calendarConnectedNow,
            modelsReady: modelDownload.isSpeechReady,
            googleDestination: destinationKind == .google,
            googleConfigured: googleAuth.config.isConfigured,
            holdToTalkIntentExplicit: prefs.holdToTalkEnabledExplicit == true,
            accessibilityTrusted: holdToTalk.accessibilityTrusted
        )
    }

    private var popSpec: OnboardingPopAnimationSpec {
        OnboardingPopAnimationSpec.spec(reduceMotion: reduceMotion)
    }

    /// DEBUG fixture may simulate trust for labelled screenshots; production
    /// always reads the live `AXIsProcessTrusted()` flag from the monitor.
    private var effectiveAccessibilityTrusted: Bool {
        // DEBUG untrusted fixture (labelled, display only) overrides even
        // the QA process's REAL inherited trust; production (no fixture)
        // always reads the live `AXIsProcessTrusted()` flag.
        if qaAXUntrusted { return false }
        return holdToTalk.accessibilityTrusted || qaAXTrusted
    }

    /// DEBUG fixture may simulate the practice key state for labelled
    /// screenshots; production always derives it from the live monitor —
    /// never a timer, never a button press.
    private var effectivePracticeKeyState: OnboardingVoiceVisualPolicy.PracticeKeyState {
        if let fixture = qaPracticeKeyFixture {
            return fixture
        }
        return OnboardingVoiceVisualPolicy.practiceKeyState(
            phase: holdToTalk.practicePhase,
            listenerInstalled: holdToTalk.monitorsInstalled
        )
    }

    /// The capability the CURRENT shortcut's global capture is gated on
    /// (2026-11-07 privacy repair): Fn → Input Monitoring (the only path
    /// that sees Fn globally is the listen-only key tap); other modifiers
    /// → Accessibility. Never an arbitrary AX requirement for Fn.
    private var stepRequiredCapability: HoldToTalkCapability {
        HoldToTalkPermissionPolicy.requiredCapability(for: holdToTalk.machine.shortcut)
    }

    /// The step's granted state comes ONLY from the real per-app probes:
    /// Fn → the live `CGPreflightListenEventAccess()` flag; other keys →
    /// the AX probe (QA fixture respected) OR the Input Monitoring flag
    /// (the key tap sees modifiers too). A drag, intent, or pref never
    /// grants. Tap creation is never treated as delivery proof.
    private var effectiveStepPermissionGranted: Bool {
        switch stepRequiredCapability {
        case .inputMonitoring:
            return holdToTalk.inputMonitoringAllowed
        case .accessibility:
            return effectiveAccessibilityTrusted || axStepPhase == .granted || holdToTalk.inputMonitoringAllowed
        }
    }

    private var dragPayload: AccessibilityDragPayload {
        if let raw = qaAppLocation {
            return AccessibilityDragGuideInfo.fixture(location: raw, realBundleURL: Bundle.main.bundleURL)
        }
        return AccessibilityDragGuideInfo.current()
    }

    private var isQAFixtureActive: Bool {
        qaAXTrusted || qaAXUntrusted || qaAppLocation != nil
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: .opacity.combined(with: .offset(y: -6))
        )
    }

    // MARK: Chrome (2026-11-12 redesign)

    /// Native-look title bar: traffic lights, centered product title, and a
    /// quiet "Setup" action. The window stays borderless/floating (the
    /// documented no-accidental-close contract), so the controls are drawn
    /// to match the system chrome and wired to safe window actions — Close
    /// orders the window out WITHOUT marking onboarding complete; Minimize
    /// and Zoom forward to the window.
    private var titleBar: some View {
        ZStack {
            QuietDesign.Color.titleBar(colorScheme)
            HStack(spacing: 0) {
                trafficLights
                Spacer(minLength: 12)
                Button("Setup") { onOpenSettings() }
                    .buttonStyle(QuietTextButtonStyle())
            }
            .padding(.horizontal, 20)
            Text("QuikCal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme).opacity(0.85))
        }
        .frame(height: QuietDesign.Metric.titleBarHeight)
        .opacity(appeared ? 1 : 0)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(QuietDesign.Color.separator(colorScheme))
                .frame(height: 1)
        }
    }

    private var trafficLights: some View {
        HStack(spacing: 8) {
            trafficLight(color: Color(red: 1.0, green: 0.373, blue: 0.341),
                         label: "Close window", action: onCloseRequest)
            trafficLight(color: Color(red: 0.992, green: 0.737, blue: 0.18),
                         label: "Minimize window", action: onMinimizeRequest)
            trafficLight(color: Color(red: 0.157, green: 0.784, blue: 0.251),
                         label: "Zoom window", action: onZoomRequest)
        }
    }

    private func trafficLight(color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The approved three-step indicator (Calendar · Voice access · Try it),
    /// shown on the capability steps only. Welcome and Ready are the flow's
    /// anchors and show no indicator.
    @ViewBuilder
    private var stepHeader: some View {
        if let index = currentStepIndex {
            QuietStepIndicator(
                steps: ["Calendar", "Voice access", "Try it"],
                currentIndex: index
            )
            .frame(maxWidth: .infinity)
            .padding(.top, QuietDesign.Metric.stepTopPadding)
            .padding(.bottom, 4)
        }
    }

    /// Maps the frozen flow pages onto the approved three-step indicator:
    /// calendar → 1, axPermission (Voice access) → 2, voiceSetup (Try it) → 3.
    /// Welcome and Ready show no indicator.
    private var currentStepIndex: Int? {
        switch session.page {
        case .calendar: return 0
        case .axPermission: return 1
        case .voiceSetup: return 2
        case .welcome, .ready: return nil
        }
    }

    /// Compact global progress that persists across pages while the shared
    /// speech-model service transfers. “View” returns to Voice setup.
    @ViewBuilder
    private var downloadBanner: some View {
        // Only during an actual transfer (or its failed/cancelled aftermath) —
        // never just because weights already sit on disk from a previous setup.
        if session.page != .voiceSetup, downloadBannerVisible {
            HStack(spacing: 10) {
                ProgressView(value: modelDownload.snapshot.progress.fraction ?? 0)
                    .controlSize(.small)
                    .frame(width: 90)
                Text(modelDownload.isTransferring
                     ? "Downloading speech model… \(VoiceOverlayPolicy.progressLabel(received: modelDownload.snapshot.bytesReceived, total: modelDownload.snapshot.bytesExpected ?? 0))"
                     : "Speech-model download \(modelDownload.snapshot.phase == .cancelled ? "cancelled" : "failed") — tap View to resume or restart.")
                    .font(OnboardTone.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button("View") {
                    animateStep { session.page = .voiceSetup; persistSession() }
                }
                .buttonStyle(QuietTextButtonStyle())
                .accessibilityLabel("View model download progress")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .transition(bannerTransition)
        }
    }

    private var downloadBannerVisible: Bool {
        // 0.3.8: extracted pure policy — the shared download keeps running on
        // every page (calendar / hold-to-talk / System Settings work), and the
        // banner is the cross-page progress + honest failed/cancelled surface.
        OnboardingDownloadBannerPolicy.isVisible(
            currentPage: session.page,
            isTransferring: modelDownload.isTransferring,
            speechPhase: modelDownload.snapshot.phase
        )
    }

    private var bannerMotion: OnboardingBannerMotionSpec {
        OnboardingBannerMotionSpec.spec(reduceMotion: reduceMotion)
    }

    private var bannerTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: bannerMotion.insertionOffsetPoints)),
            removal: .opacity
        )
    }

    private var bottomBar: some View {
        ZStack {
            HStack(spacing: 16) {
                if session.page != .welcome || holdGuideOnly {
                    Button("Back") {
                        animateStep { goBack() }
                    }
                    .buttonStyle(QuietTextButtonStyle())
                }
                Spacer()
                Button(primaryLabel) {
                    animateStep { goPrimary() }
                }
                .buttonStyle(QuietPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(session.page == .calendar && calendarStage == .googleConnect && googleAuth.phase == .authorizing)
            }
            if let index = currentStepIndex {
                Text("\(index + 1) of 3")
                    .font(QuietDesign.Typography.caption)
                    .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Step \(index + 1) of 3")
            }
        }
        .padding(.horizontal, QuietDesign.Metric.chromePadding)
        .frame(height: QuietDesign.Metric.bottomBarHeight)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(QuietDesign.Color.separator(colorScheme))
                .frame(height: 1)
        }
    }

    /// The approved per-screen primary action. The label is derived from the
    /// live scene state (never hardcoded success): the calendar stage, the
    /// permission stage, and the practice stage each name their own action.
    private var primaryLabel: String {
        if holdGuideOnly && session.holdGuide.phase == .done {
            return "Done"
        }
        switch session.page {
        case .welcome:
            return "Get started"
        case .calendar:
            switch calendarStage {
            case .choosing: return "Connect calendar"
            case .macConnected, .googleConnected: return "Continue"
            case .googleConnect: return "Continue with Google"
            case .error: return "Try again"
            }
        case .axPermission:
            return effectiveStepPermissionGranted ? "Try my voice" : "Open System Settings"
        case .voiceSetup:
            if holdGuideOnly {
                if session.holdGuide.phase == .done || session.holdGuide.phase == .practiceHold { return "Continue" }
                return "Setup shortcut"
            }
            if !modelDownload.isSpeechReady { return "Finish setup" }
            switch effectivePracticeKeyState {
            case .holding: return "Cancel practice"
            case .released: return "Finish setup"
            default: return "Skip practice"
            }
        case .ready:
            return "Open QuikCal"
        }
    }

    private func goBack() {
        if holdGuideOnly, session.page == .voiceSetup, session.holdGuide.phase != .pickShortcut {
            session.holdGuide.goBack()
            persistSession()
            return
        }
        if holdGuideOnly, session.holdGuide.phase == .pickShortcut {
            holdToTalk.practicePreviewOnly = false
            holdToTalk.stopMonitoring()
            onFinished()
            return
        }
        session.goBack()
        persistSession()
    }

    private func goPrimary() {
        if holdGuideOnly, session.holdGuide.phase == .done {
            holdToTalk.practicePreviewOnly = false
            holdToTalk.stopMonitoring()
            onFinished()
            return
        }
        if session.page == .ready {
            prefs.glassIntensity = glassPreview
            session.finish()
            prefs.onboardingCompleted = true
            prefs.clearOnboardingResume()
            holdToTalk.practicePreviewOnly = false
            onFinished()
            return
        }
        if holdGuideOnly, session.page == .voiceSetup {
            advanceHoldGuide()
            return
        }
        if session.page == .calendar {
            switch calendarStage {
            case .choosing:
                // Explicit user action — the ONLY path that asks EventKit.
                vm.requestCalendarAccess()
            case .macConnected, .googleConnected:
                session.goNext()
                persistSession()
            case .googleConnect:
                // Explicit user action — opens the browser only on this tap.
                if googleAuth.phase != .authorizing { googleAuth.beginSignIn() }
            case .error:
                if destinationKind == .google {
                    googleAuth.beginSignIn()
                } else {
                    vm.requestCalendarAccess()
                    vm.refreshSelection()
                }
            }
            return
        }
        session.goNext()
        persistSession()
    }

    private func advanceHoldGuide() {
        // Sync shortcut into prefs before leaving pick / conflict steps.
        holdToTalk.setShortcut(shortcutSelection)
        session.holdGuide.shortcut = shortcutSelection

        switch session.holdGuide.phase {
        case .pickShortcut:
            session.holdGuide.goNext()
        case .explainConflict:
            session.holdGuide.goNext()
        case .accessibilityExplain:
            session.holdGuide.goNext()
        case .openSettings:
            session.holdGuide.goNext()
            holdToTalk.refreshPermissionFlags()
            session.holdGuide.applyAccessibilityTrusted(holdToTalk.accessibilityTrusted)
        case .recheckPermission:
            // May continue even if denied — typing still works.
            session.holdGuide.goNext()
        case .enableMonitoring:
            session.holdGuide.goNext()
        case .practiceHold:
            // Advancing from practice records the confirmation (persisted
            // flag preserved) — the big in-page affirmation button is gone.
            session.holdGuide.confirmPractice()
            session.holdGuide.goNext()
            holdToTalk.practicePreviewOnly = false
            // Practice preview is over — clear the wired release callback
            // so the monitor holds no reference into the practice view.
            holdToTalk.onPracticeRelease = nil
            if !holdGuideOnly {
                session.goNext()
            }
        case .done:
            if !holdGuideOnly {
                session.goNext()
            }
        }
        persistSession()
    }

    private func animateStep(_ update: () -> Void) {
        if reduceMotion {
            update()
        } else {
            withAnimation(.easeInOut(duration: 0.28), update)
        }
    }

    // MARK: Scenes

    @ViewBuilder
    private var stepScene: some View {
        if holdGuideOnly {
            // Settings reopen of the dedicated hold-to-talk guide: the
            // existing phase machine (a deliberate step-by-step guide,
            // not the 4-page first-run flow).
            holdScene
        } else {
            switch session.page {
            case .welcome:
                welcomeScene
            case .calendar:
                calendarScene
            case .axPermission:
                axPermissionScene
            case .voiceSetup:
                voiceSetupScene
            case .ready:
                completionScene
            }
        }
    }

    /// P3 compact 4-page flow — the merged Voice setup page (2026-11-07
    /// review pass, parent visual findings): ONE compact voice-model row
    /// (skip-if-ready: "Voice ready", no model-name stack, no forced
    /// 2.74 GB download), ONE concise Accessibility permission row (the
    /// 3-step instructions + drag tile live under an optional "More
    /// help" disclosure — never the default view; granted state shows
    /// Granted + practice, not permission microsteps), and the REAL Fn
    /// practice. Everything essential fits 640×600 with the footer
    /// visible; the ScrollView exists for accessibility text sizes only.
    /// Mic is requested ONLY from an explicit hold (never here).
    private var voiceSetupScene: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sceneTitle(
                    "Try a quick hold.",
                    subtitle: "Hold \(shortcutSelection.shortName) to speak. Release to review."
                )
                // 1. ONE compact voice-model row / download card
                // (skip-if-ready): the 2026-11-12 design keeps the download
                // INSIDE the Try-it step — progress is live from the shared
                // ParakeetModelDownload service, never a fixed percentage.
                voiceModelRow
                if modelDownload.isTransferring {
                    Label("Typing is available right away.", systemImage: "lock")
                        .font(QuietDesign.Typography.caption)
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                        .frame(maxWidth: 480, alignment: .leading)
                }
                HStack(spacing: 6) {
                    voiceModelDetailsDisclosure
                    #if DEBUG
                    if modelDownload.isQAFixtureActive {
                        qaFixtureChip("QA fixture — not a real download")
                    }
                    #endif
                }
                .frame(maxWidth: 480, alignment: .leading)
                foundationModelsReadinessRow
                if let message = vm.speech.message {
                    Text(message)
                        .font(OnboardTone.caption)
                        .foregroundStyle(.orange)
                }
                // 2. ONE concise accessibility permission row. Untrusted:
                // one line + Open Settings + Check again, grant steps and
                // the drag tile under the optional disclosure. Trusted:
                // the Granted row only — never 3 permission microsteps.
                voiceAccessibilityRow
                // 3. REAL hold-to-talk practice (live monitor only).
                // 2026-11-12 approved layout: keycap, consent-armed "Try
                // it" (installing the global listener ALWAYS needs this
                // explicit tap — never implicit at page show), a status
                // pill whose text comes from PracticeDetectionPolicy, and
                // the instructional "Try saying" card — never a fake
                // transcript. Practice mode parses nothing and saves
                // nothing (PracticeDraftPolicy).
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hold-to-talk shortcut")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                        .frame(maxWidth: 480, alignment: .leading)
                    HoldShortcutGradientPicker(selection: $shortcutSelection) { kind in
                        holdToTalk.setShortcut(kind)
                        session.holdGuide.shortcut = kind
                        persistSession()
                    }
                    .frame(maxWidth: 480)
                }
                HStack(alignment: .center, spacing: 16) {
                    FnKeyCapView(
                        keyLabel: shortcutSelection.shortName,
                        state: effectivePracticeKeyState,
                        reduceMotion: reduceMotion
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Try it") {
                            holdToTalk.practicePreviewOnly = true
                            holdToTalk.startMonitoringIfPermitted()
                            holdToTalk.onPracticeRelease = {
                                session.holdGuide.markPracticeHoldSeen()
                                persistSession()
                            }
                            persistSession()
                        }
                        .buttonStyle(QuietPrimaryButtonStyle())
                        practicePill
                        #if DEBUG
                        if qaPracticeKeyFixture != nil {
                            qaFixtureChip("QA fixture — simulated key state")
                        }
                        #endif
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 480, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        QuietSectionLabel(text: "Try saying")
                        Spacer(minLength: 8)
                        Label("Practice only. Nothing is saved.", systemImage: "lock")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                            .labelStyle(.titleAndIcon)
                    }
                    Text("“Lunch with Alex tomorrow at noon.”")
                        .font(.system(size: 13.5))
                        .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(maxWidth: 480, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: QuietDesign.Metric.cardCorner, style: .continuous)
                        .fill(QuietDesign.Color.card(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: QuietDesign.Metric.cardCorner, style: .continuous)
                        .strokeBorder(QuietDesign.Color.cardStroke(colorScheme), lineWidth: 1)
                )
                // Quiet footnote rail: the practice notice is merged into
                // the Try-saying card header (lock + “Practice only…”), so
                // the whole practice fits 640×600 without clipping.
                // Compact local gutter (2026-11-07 review): the shared
                // ModelsLayoutPolicy.bottomGutter (20 pt) was sized for the
                // retired tall page; the compact page uses a small local
                // gutter so the practice + note fit above the footer.
                Color.clear
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 4)
        }
    }

    /// Live status pill for practice — mirrors the approved design's
    /// full-width pill (mic / red dot + waveform while held). The text is
    /// ALWAYS the PracticeDetectionPolicy sentence (never a timer, never a
    /// simulated state); the accessibility value is the same string.
    private var practicePill: some View {
        let holding = effectivePracticeKeyState == .holding
        return HStack(spacing: 8) {
            if holding {
                Circle()
                    .fill(Color(red: 0.843, green: 0.0, blue: 0.082))
                    .frame(width: 8, height: 8)
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
            } else {
                Image(systemName: "mic")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuietDesign.Color.primaryFill)
            }
            Text(practiceHoldStatus)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 340, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(QuietDesign.Color.pillIdle(colorScheme))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(practiceHoldStatus)
    }

    /// Small labelled QA-fixture chip (DEBUG only) — compact so fixture
    /// labels never push the page past the default fold.
    #if DEBUG
    private func qaFixtureChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.12)))
    }
    #endif

    // MARK: Dedicated Accessibility verification step (2026-11-07 owner correction)
    //
    // Its own onboarding page BEFORE voice practice. The step: a clear
    // drag / Open Settings action; Waiting, then checking when the app
    // returns or a drag is under way; success ONLY when the real
    // `AXIsProcessTrusted()` probe says trusted (never from a drop
    // callback — the drag is not observable to the grant); bounded
    // polling active ONLY while this step is visible; an honest timeout
    // with the restart explanation; Reduce Motion–friendly transitions.

    @State private var axStepPhase: AXPermissionStepPhase = .idle
    /// When the current bounded wait began (drives the honest timeout).
    @State private var axWaitStartedAt: Date?

    private var axPermissionScene: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sceneTitle(
                    effectiveStepPermissionGranted ? "Your shortcut is ready." : "Speak from anywhere.",
                    subtitle: effectiveStepPermissionGranted
                        ? "QuikCal can now detect when you hold \(holdToTalk.machine.shortcut.displayName).\nLet's give it a try."
                        : "Let QuikCal detect when you hold \(holdToTalk.machine.shortcut.displayName),\nso you can add an event from any app.",
                    alignment: .leading
                )
                // The approved two-row card (Shortcut access · Microphone)
                // is the SAME surface in every untrusted/granted state —
                // only its chip flips. Install-first copies keep it too:
                // the required capability genuinely is not enabled.
                axPermissionRowsCard(
                    chip: effectiveStepPermissionGranted ? "Allowed" : "Not enabled",
                    chipTone: effectiveStepPermissionGranted ? .success : .neutral
                )
                if effectiveStepPermissionGranted {
                    Label("QuikCal listens only while you hold the shortcut.", systemImage: "lock")
                        .font(QuietDesign.Typography.caption)
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                        .frame(maxWidth: 480, alignment: .leading)
                    #if DEBUG
                    if qaAXTrusted {
                        qaFixtureChip("QA fixture — simulated trust, not a real grant")
                    }
                    #endif
                } else if dragPayload.location.requiresInstallFirst {
                    // A transient copy can never be granted — install-first
                    // honesty, no drag tile, no poll.
                    InstallFirstWarning(
                        payload: dragPayload,
                        isQAFixture: isQAFixtureActive
                    )
                    HStack(spacing: 10) {
                        Button(AccessibilityDragGuideCopy.revealApp) {
                            AccessibilityDragGuideInfo.revealInFinder(dragPayload)
                        }
                        .buttonStyle(QuietPrimaryButtonStyle())
                        Spacer()
                        accessibilityStatusChip
                    }
                    .frame(maxWidth: 480)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Turn on QuikCal in \(stepRequiredCapability.displayName).")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                        Text("System Settings → Privacy & Security → \(stepRequiredCapability.displayName)")
                            .font(QuietDesign.Typography.caption)
                            .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    }
                    .frame(maxWidth: 480, alignment: .leading)
                    Button("Set up voice later") {
                        animateStep { setupVoiceLater() }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                    .buttonStyle(.plain)
                    .frame(maxWidth: 480)
                    .accessibilityHint("Skips the voice steps. You can enable voice anytime in Settings.")
                    // Capability rows (2026-11-07 privacy repair): the
                    // REQUIRED capability for the current shortcut comes
                    // FIRST, with its own pane-open button — clicking
                    // opens that specific pane only; no automatic parade
                    // of panels. Fn needs Input Monitoring (the
                    // listen-only key tap is the only path that sees Fn
                    // globally); other keys need Accessibility, with
                    // Input Monitoring as an alternative.
                    if stepRequiredCapability == .inputMonitoring {
                        permissionCapabilityRow(
                            symbol: "directcurrent",
                            title: PrivacyPaneKind.inputMonitoring.paneDisplayName,
                            chip: "Required",
                            granted: holdToTalk.inputMonitoringAllowed,
                            open: holdToTalk.openInputMonitoringSettings
                        )
                        Text(HoldToTalkPermissionCopy.inputMonitoringRestartNote)
                            .font(OnboardTone.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 480, alignment: .leading)
                    }
                    AccessibilityStepsList(steps: AccessibilityDragGuideCopy.steps)
                    if stepRequiredCapability == .inputMonitoring {
                        Text("Accessibility is optional for Fn — it matters only if you later switch to Option, Command, or Control.")
                            .font(OnboardTone.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 480, alignment: .leading)
                    }
                    if dragPayload.offersDragTile {
                        DraggableAppIconTile(
                            payload: dragPayload,
                            icon: AccessibilityDragGuideInfo.appIcon(for: dragPayload, realBundleURL: Bundle.main.bundleURL),
                            isQAFixture: isQAFixtureActive,
                            onDragStarted: { axDragStarted() }
                        )
                    }
                    Text(AXPermissionStepCopy.dragDoesNotGrantNote)
                        .font(OnboardTone.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480, alignment: .leading)
                    HStack(spacing: 10) {
                        Button(AccessibilityDragGuideCopy.openSettings) {
                            // Opens the pane only — no prompt, no grant.
                            axOpenSettingsAction()
                        }
                        .buttonStyle(QuietPrimaryButtonStyle())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 120, alignment: .center)
                        Button(AccessibilityDragGuideCopy.checkAgain) {
                            axCheckAgainAction()
                        }
                        .buttonStyle(QuietSecondaryButtonStyle())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(maxWidth: 480, alignment: .leading)
                    axStepStatusCard
                    if let mismatchHint = holdToTalk.accessibilityMismatchHint {
                        // Honest, non-assertive troubleshooting for the
                        // re-signed-copy case (Settings ON, probe untrusted).
                        Text(mismatchHint)
                            .font(OnboardTone.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 480, alignment: .leading)
                    }
                    if stepRequiredCapability == .accessibility {
                        // Non-Fn shortcut: Input Monitoring is a genuine
                        // ALTERNATIVE (the key tap sees modifiers too) —
                        // offered as a row, never demanded.
                        permissionCapabilityRow(
                            symbol: "directcurrent",
                            title: PrivacyPaneKind.inputMonitoring.paneDisplayName,
                            chip: "Alternative",
                            granted: holdToTalk.inputMonitoringAllowed,
                            open: holdToTalk.openInputMonitoringSettings
                        )
                    }
                    // Mic honesty (2026-11-07 privacy repair): the
                    // microphone is NEVER requested from this page —
                    // only from the user's first hold/capture action.
                    Text(HoldToTalkPermissionCopy.micRequestedOnHoldNote)
                        .font(OnboardTone.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480, alignment: .leading)
                    copyShortcutDiagnosticsButton
                    #if DEBUG
                    if qaAXUntrusted {
                        qaFixtureChip("QA fixture — simulated untrusted view")
                    }
                    #endif
                }
                Color.clear
                    .frame(height: 6)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 4)
        }
        .onAppear { axStepAppeared() }
        // Bounded polling is active ONLY while this step is visible.
        .onDisappear { holdToTalk.stopBoundedTrustPoll() }
        // The monitor's bounded poll re-probes the REAL trust value; every
        // refresh flows through the published flag — this is the single
        // place the step's phase reacts to a probe result.
        .onReceive(holdToTalk.$accessibilityTrusted) { trusted in
            axTrustFlagRefreshed(trusted: trusted)
        }
    }

    /// The approved permission card (both live states): Shortcut access
    /// — gate chip derives from the REAL capability probe, plus
    /// Microphone, which is never requested from this page.
    private func axPermissionRowsCard(
        chip: String,
        chipTone: QuietStatusChip.QuietStatusTone
    ) -> some View {
        QuietCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    QuietIconTile(systemImage: "key.fill", side: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shortcut access")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                        Text("\(stepRequiredCapability.displayName) · needed for \(holdToTalk.machine.shortcut.displayName)")
                            .font(QuietDesign.Typography.caption)
                            .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    }
                    Spacer(minLength: 8)
                    QuietStatusChip(text: chip, tone: chipTone)
                }
                .padding(14)
                Rectangle()
                    .fill(QuietDesign.Color.separator(colorScheme))
                    .frame(height: 1)
                HStack(spacing: 12) {
                    QuietIconTile(systemImage: "mic.fill", side: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                        Text("Asked when you first speak")
                            .font(QuietDesign.Typography.caption)
                            .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    }
                    Spacer(minLength: 8)
                }
                .padding(14)
            }
        }
        .frame(maxWidth: 480)
    }

    /// "Set up voice later" (approved permission screen): marks BOTH
    /// voice pages skipped through the SAME persisted resume path the
    /// flow writes itself, then lands on Ready. Typing works; voice can
    /// be enabled anytime in Settings. Never claims voice readiness.
    private func setupVoiceLater() {
        session.skipped.insert(.axPermission)
        session.skipped.insert(.voiceSetup)
        session.page = .ready
        persistSession()
    }

    /// Live status line for the verification step — truthful per phase,
    /// never a simulated state.
    private var axStepStatusText: String {
        switch axStepPhase {
        case .idle: return AXPermissionStepCopy.idleCopy
        case .waiting: return AXPermissionStepCopy.waitingCopy
        case .checking: return AXPermissionStepCopy.checkingCopy
        case .granted: return AXPermissionStepCopy.grantedCopy
        case .notDetected: return AXPermissionStepCopy.notDetectedCopy
        case .timedOut: return AXPermissionStepCopy.timedOutCopy
        }
    }

    private var axStepStatusCard: some View {
        let isGranted = axStepPhase == .granted
        let needsAttention = axStepPhase == .notDetected || axStepPhase == .timedOut
        return Text(axStepStatusText)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(
                isGranted
                ? OnboardTone.primaryFill
                : (needsAttention
                   ? Color(red: 0.843, green: 0.204, blue: 0.0) // #c93400
                   : Color.secondary)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: axStepPhase)
            .accessibilityLabel(axStepStatusText)
    }

    /// One capability row for the permission step (2026-11-07 privacy
    /// repair): REAL per-app probe status chip + its OWN pane-open
    /// button. Opening a pane grants nothing; the mic is never requested
    /// from this page; no row claims a grant from a drag or a pref.
    private func permissionCapabilityRow(
        symbol: String,
        title: String,
        chip: String,
        granted: Bool,
        open: @escaping () -> Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(granted ? OnboardTone.accent : Color.secondary)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Text(granted ? "Granted" : chip)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            Button("Open…") { _ = open() }
                .buttonStyle(QuietSecondaryButtonStyle())
                .controlSize(.small)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: 480)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(QuietDesign.Color.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(QuietDesign.Color.cardStroke(colorScheme), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    /// Step became visible: probe once, then arm the BOUNDED poll only
    /// when not already granted. The poll self-stops on trust or on the
    /// bound; `onDisappear` stops it when the step is no longer visible.
    private func axStepAppeared() {
        holdToTalk.refreshPermissionFlags()
        if effectiveAccessibilityTrusted {
            axStepPhase = .granted
            axWaitStartedAt = nil
        } else if axStepPhase == .granted {
            // Trust was lost since this step last showed — honest reset.
            axStepPhase = .notDetected
            axWaitStartedAt = Date()
        } else if axWaitStartedAt == nil {
            axWaitStartedAt = Date()
        }
        if axStepPhase != .granted {
            holdToTalk.startBoundedTrustPoll()
        }
    }

    /// One real probe result arrived (monitor poll / activation / explicit
    /// Check again). Granted comes ONLY from a trusted probe; untrusted
    /// results keep the live window honest and apply the bounded timeout.
    private func axTrustFlagRefreshed(trusted: Bool) {
        guard session.page == .axPermission else { return }
#if DEBUG
        // Labelled QA fixture only: when the screenshot host forces the
        // UNTRUSTED view, keep it — even if this QA process really
        // inherits the owner's Accessibility trust (display-only; the
        // fixture never changes TCC and never affects production).
        if qaAXUntrusted { return }
#endif
        if trusted {
            axStepPhase = .granted
            axWaitStartedAt = nil
            return
        }
        // Idle stays idle until the user acts (or the app returns); a
        // granted/timed-out phase is terminal until an explicit action.
        switch axStepPhase {
        case .idle, .granted, .timedOut:
            return
        case .waiting, .checking, .notDetected:
            if axWaitStartedAt == nil { axWaitStartedAt = Date() }
            let elapsed = Date().timeIntervalSince(axWaitStartedAt ?? Date())
            axStepPhase = AXPermissionStepPolicy.timeoutIfNeeded(
                phase: AXPermissionStepPolicy.probeResult(trusted: false),
                elapsedWait: elapsed
            )
        }
    }

    /// Open Settings: enters the bounded waiting window; the pane open is
    /// UI coordination only — nothing is granted here. 0.3.16: the action
    /// opens the pane for the capability that ACTUALLY gates the current
    /// shortcut (Fn → Input Monitoring; other keys → Accessibility) and
    /// shows the compact drag-assist panel alongside System Settings —
    /// never a mislabeled pane, never a grant.
    private func axOpenSettingsAction() {
        axWaitStartedAt = Date()
        axStepPhase = AXPermissionStepPolicy.phase(afterOpenSettingsTapped: axStepPhase)
        if stepRequiredCapability == .inputMonitoring {
            holdToTalk.openInputMonitoringSettings()
        } else {
            holdToTalk.openAccessibilitySettings()
        }
        PrivacyDragPanelPresenter.shared.present(for: stepRequiredCapability, monitor: holdToTalk)
        holdToTalk.startBoundedTrustPoll()
    }

    /// A drag START enters the bounded waiting window too — the poll
    /// keeps checking while the drag is under way and after it ends. No
    /// drop callback is ever interpreted as success.
    private func axDragStarted() {
        axWaitStartedAt = Date()
        axStepPhase = .waiting
        holdToTalk.startBoundedTrustPoll()
    }

    /// Explicit Check again: fresh probe + guarded listener rebind, then
    /// the honest result (granted only from a real trusted probe).
    private func axCheckAgainAction() {
        axWaitStartedAt = Date()
        axStepPhase = .checking
        holdToTalk.checkAgainAndReattach()
        if effectiveAccessibilityTrusted {
            axStepPhase = .granted
            axWaitStartedAt = nil
        } else {
            axStepPhase = AXPermissionStepPolicy.probeResult(trusted: false)
        }
    }

    /// ONE compact speech-model row. Ready → "Voice model ready" (weights
    /// verified — never an inference-ready claim, never model names).
    /// Missing → a single Download action for the ~731 MB speech model.
    /// Apple Foundation Models are managed by macOS and are never downloaded
    /// by QuikCal.
    /// Transferring → inline progress + Cancel. Honest failures inline.
    ///
    /// The 2026-11-12 design renders it as the Try-it step's "Getting voice
    /// ready." download card while a transfer is live (progress always from
    /// the shared ParakeetModelDownload service; skip-if-ready shows one
    /// calm ready row; failed/cancelled stay honest with retry).
    @ViewBuilder
    private var voiceModelRow: some View {
        let snap = modelDownload.snapshot
        return Group {
            if modelDownload.isSpeechReady {
                // Skip-if-ready: weights on disk → one compact ready row.
                HStack(spacing: 12) {
                    QuietIconTile(systemImage: "waveform", side: 26)
                    Label("Voice model ready", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(QuietDesign.Color.accent)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 480, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else if modelDownload.isTransferring {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        QuietIconTile(systemImage: "waveform", side: 34)
                        Text("Downloading voice support")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                        Spacer(minLength: 8)
                        if let fraction = speechProgressFraction {
                            Text("\(Int((fraction * 100).rounded()))%")
                                .font(.system(size: 15, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                        }
                    }
                    ProgressView(value: speechProgressFraction ?? 0)
                        .tint(QuietDesign.Color.primaryFill)
                    Text("You can finish setup while this downloads.")
                        .font(QuietDesign.Typography.caption)
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    Button("Cancel download") { modelDownload.cancel() }
                        .buttonStyle(QuietTextButtonStyle())
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityLabel("Cancel voice model download")
                }
                .padding(14)
                .frame(maxWidth: 480)
                .background(
                    RoundedRectangle(cornerRadius: QuietDesign.Metric.cardCorner, style: .continuous)
                        .fill(QuietDesign.Color.card(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: QuietDesign.Metric.cardCorner, style: .continuous)
                        .strokeBorder(QuietDesign.Color.cardStroke(colorScheme), lineWidth: 1)
                )
                .accessibilityElement(children: .combine)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    QuietIconTile(systemImage: "waveform", side: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice model")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                        Text("Needed for hold-to-talk (731 MB)")
                            .font(QuietDesign.Typography.caption)
                            .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                        if snap.phase == .failed {
                            Text("Download failed — try again.")
                                .font(QuietDesign.Typography.caption)
                                .foregroundStyle(QuietDesign.Color.warning)
                        } else if snap.phase == .cancelled {
                            Text("Download cancelled — resume anytime.")
                                .font(QuietDesign.Typography.caption)
                                .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Download") { modelDownload.startSpeechInstall() }
                        .buttonStyle(QuietPrimaryButtonStyle())
                }
                .padding(14)
                .frame(maxWidth: 480)
                .background(
                    RoundedRectangle(cornerRadius: QuietDesign.Metric.cardCorner, style: .continuous)
                        .fill(QuietDesign.Color.card(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: QuietDesign.Metric.cardCorner, style: .continuous)
                        .strokeBorder(QuietDesign.Color.cardStroke(colorScheme), lineWidth: 1)
                )
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear { modelDownload.refresh() }
    }

    private var speechProgressFraction: Double? {
        let snap = modelDownload.snapshot
        guard let expected = snap.bytesExpected, expected > 0 else { return nil }
        return min(1, Double(snap.bytesReceived) / Double(expected))
    }

    private var voiceModelAccessibilityLabel: String {
        if modelDownload.isSpeechReady { return "Voice model ready" }
        if modelDownload.isTransferring { return "Downloading voice model" }
        return "Voice model not installed"
    }

    /// Optional speech-model file selection and recovery actions.
    @State private var modelDetailsExpanded = false

    @ViewBuilder
    private var voiceModelDetailsDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $modelDetailsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Button("Use existing speech model…") { useExistingModelFromOnboarding() }
                            .buttonStyle(QuietSecondaryButtonStyle())
                        if modelDownload.snapshot.phase == .failed || modelDownload.snapshot.phase == .cancelled {
                            Button("Retry") { modelDownload.retry() }
                                .buttonStyle(QuietSecondaryButtonStyle())
                        }
                    }
                    if let err = modelDownload.snapshot.lastError {
                        Text(err)
                            .font(OnboardTone.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("More speech options")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var foundationModelsReadinessRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(OnboardTone.accent)
                Text("Event extraction · Apple Intelligence")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text(vm.foundationModelsReadiness.shortLabel)
                    .font(OnboardTone.caption)
                    .foregroundStyle(.secondary)
            }
            Text(vm.foundationModelsReadiness.onboardingSummary)
                .font(OnboardTone.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 480, alignment: .leading)
        .onAppear { vm.refreshFoundationModelsReadiness() }
    }

    /// ONE concise Accessibility permission row. Untrusted default: a
    /// single line + Open Settings + Check again (all above the footer).
    /// The 3-step instructions, drag tile, and hints sit under the
    /// optional "More help" disclosure. Trusted: the Granted row only.
    @State private var permissionHelpExpanded = false

    @ViewBuilder
    private var voiceAccessibilityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dragPayload.location.requiresInstallFirst {
                // Essential honesty (not filler): a translocated/running
                // bundle can never be granted — the warning + Reveal stay
                // visible outside the disclosure.
                InstallFirstWarning(
                    payload: dragPayload,
                    isQAFixture: isQAFixtureActive
                )
                HStack(spacing: 10) {
                    Button(AccessibilityDragGuideCopy.revealApp) {
                        AccessibilityDragGuideInfo.revealInFinder(dragPayload)
                    }
                    .buttonStyle(QuietPrimaryButtonStyle())
                    Spacer()
                    accessibilityStatusChip
                }
                .frame(maxWidth: 480)
            } else if effectiveAccessibilityTrusted {
                // GRANTED: hide the grant instructions entirely — one
                // honest Granted row (live probe or labelled QA fixture).
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(OnboardTone.accent)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(OnboardTone.accent.opacity(0.10)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility granted")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Hold-to-talk is permitted on this Mac.")
                            .font(OnboardTone.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(AccessibilityDragGuideCopy.checkAgain) {
                        holdToTalk.checkAgainAndReattach()
                        session.holdGuide.applyAccessibilityTrusted(effectiveAccessibilityTrusted)
                        persistSession()
                    }
                    .buttonStyle(QuietSecondaryButtonStyle())
                }
                .frame(maxWidth: 480, alignment: .leading)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(QuietDesign.Color.card(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(QuietDesign.Color.cardStroke(colorScheme), lineWidth: 1)
                )
                #if DEBUG
                if qaAXTrusted {
                    qaFixtureChip("QA fixture — simulated trust, not a real grant")
                }
                #endif
            } else {
                // UNTRUSTED default: ONE concise permission row + the two
                // actions, visible above the footer. The 3-step guide and
                // drag tile are under the optional disclosure.
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                            .font(.system(size: 14, weight: .semibold))
                        Text("One permission in System Settings.")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            // One line, never wrapped, never ellipsized:
                            // at 640×600 the two action buttons take
                            // precedence and the copy scales within
                            // itself rather than clipping
                            // ("System Settings…") or pushing the practice
                            // card below the fold.
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    Spacer(minLength: 6)
                    Button(AccessibilityDragGuideCopy.openSettings) {
                        // Opens the pane only — no prompt, no grant.
                        holdToTalk.openAccessibilitySettings()
                    }
                    .buttonStyle(QuietPrimaryButtonStyle())
                    // 2026-11-07 parent fix: ONE line, never wrapped to
                    // "Open\nSettings" at 640×600 — the label resists
                    // compression (≥120 pt usable width) and the
                    // descriptive caption wraps instead. Check again stays
                    // visible beside it.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 120, alignment: .center)
                    Button(AccessibilityDragGuideCopy.checkAgain) {
                        holdToTalk.checkAgainAndReattach()
                        session.holdGuide.applyAccessibilityTrusted(effectiveAccessibilityTrusted)
                        persistSession()
                    }
                    .buttonStyle(QuietSecondaryButtonStyle())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .frame(maxWidth: 480, alignment: .leading)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(QuietDesign.Color.card(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(QuietDesign.Color.cardStroke(colorScheme), lineWidth: 1)
                )
                // 2026-11-07 Accessibility mismatch evidence (owner
                // screenshot): the System Settings switch was ON while
                // this row honestly said "enable" — with NO explanation in
                // the compact row (the mismatch hint previously lived
                // only in the hold-guide recheck phase and the repair
                // card). Surface the SAME honest, non-assertive hint here,
                // quietly, whenever the live probe says untrusted and the
                // running copy is an installed /Applications build (the
                // policy returns nil for every other location). Never a
                // fake "Enabled", never an orange alarm.
                if let mismatchHint = holdToTalk.accessibilityMismatchHint,
                   !effectiveAccessibilityTrusted {
                    Text(mismatchHint)
                        .font(OnboardTone.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480, alignment: .leading)
                }
                HStack(spacing: 8) {
                    DisclosureGroup(isExpanded: $permissionHelpExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            AccessibilityStepsList(steps: AccessibilityDragGuideCopy.steps)
                            if dragPayload.offersDragTile {
                                DraggableAppIconTile(
                                    payload: dragPayload,
                                    icon: AccessibilityDragGuideInfo.appIcon(for: dragPayload, realBundleURL: Bundle.main.bundleURL),
                                    isQAFixture: isQAFixtureActive
                                )
                            }
                            Text(AccessibilityDragGuideCopy.alreadyListedHint)
                                .font(OnboardTone.caption)
                                .foregroundStyle(.secondary)
                            Text(AccessibilityDragGuideCopy.dragDoesNotGrantShort)
                                .font(OnboardTone.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Button(AccessibilityDragGuideCopy.revealApp) {
                                    AccessibilityDragGuideInfo.revealInFinder(dragPayload)
                                }
                                .buttonStyle(QuietSecondaryButtonStyle())
                                Spacer()
                                accessibilityStatusChip
                            }
                            .frame(maxWidth: 480)
                            copyShortcutDiagnosticsButton
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("More help")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    #if DEBUG
                    if qaAXUntrusted {
                        // Labelled QA fixture: the untrusted view is simulated
                        // for a screenshot (this QA process may really hold
                        // the owner's inherited trust) — never a TCC change.
                        qaFixtureChip("QA fixture — simulated untrusted view")
                    }
                    #endif
                }
                .frame(maxWidth: 480, alignment: .leading)
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
    }

    /// Live trust status chip (or labelled QA fixture): `AXIsProcessTrusted`
    /// is the only authority; the QA fixture is explicitly labelled and
    /// never changes the system TCC state.
    private var accessibilityStatusChip: some View {
        HStack(spacing: 6) {
            Text("Accessibility")
                .font(.system(size: 13, weight: .medium))
            if effectiveAccessibilityTrusted {
                Label(AccessibilityDragGuideCopy.enabledCheck, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnboardTone.accent)
            } else {
                Text(AccessibilityDragGuideCopy.notYetCheck)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 2026-11-12 approved design (welcome-light/dark.png): app mark,
    /// two-line SF Pro display, short supporting line, the real
    /// hold → speak → review affordance row naming the ACTUAL selected
    /// shortcut, and the quiet menu-bar footnote.
    private var welcomeScene: some View {
        VStack(spacing: 20) {
            QuietAppMark(side: 72)
            VStack(spacing: 12) {
                Text("Your calendar.\nA little more effortless.")
                    .font(QuietDesign.Typography.display)
                    .fontWeight(.bold)
                    .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                Text("Speak naturally. Review the details.\nAdd an event without breaking your flow.")
                    .font(QuietDesign.Typography.subtitle)
                    .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            HStack(spacing: 14) {
                QuietKeyCap(
                    keyLabel: shortcutSelection.shortName,
                    state: .neutral,
                    reduceMotion: reduceMotion,
                    size: .small
                )
                Text("Hold")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                Image(systemName: "arrow.right")
                    .font(.system(size: 11))
                    .foregroundStyle(QuietDesign.Color.labelTertiary(colorScheme))
                Image(systemName: "mic")
                    .font(.system(size: 13))
                    .foregroundStyle(QuietDesign.Color.primaryFill)
                Text("Speak")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                Image(systemName: "arrow.right")
                    .font(.system(size: 11))
                    .foregroundStyle(QuietDesign.Color.labelTertiary(colorScheme))
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuietDesign.Color.primaryFill)
                Text("Review")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
            }
            Label("Quietly at home in your menu bar.", systemImage: "menubar.rectangle")
                .font(QuietDesign.Typography.caption)
                .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                .labelStyle(.titleAndIcon)
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 32)
    }

    /// 2026-11-12 approved design: ONE state-driven calendar surface.
    /// The stage is the LIVE destination selection plus the real
    /// EventKit / Google state — choosing → connected → connected-with-
    /// picker, or the honest failure card. EventKit/Google permission
    /// requests happen ONLY from explicit actions here (the primary
    /// button or the in-scene sign-in button), never at launch.
    private var calendarScene: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch calendarStage {
            case .choosing:
                sceneTitle(
                    "Choose your calendar",
                    subtitle: "Pick where QuikCal should add your events.\nYou can change this anytime in Settings.",
                    alignment: .leading
                )
                VStack(spacing: 10) {
                    calendarOptionRow(
                        symbol: "calendar",
                        title: "Mac calendars",
                        subtitle: "Use the accounts already on this Mac.",
                        selected: destinationKind == .eventKit
                    ) { selectDestination(.eventKit) }
                    calendarOptionRow(
                        symbol: "globe",
                        title: "Google Calendar",
                        subtitle: "Connect your Google account.",
                        selected: destinationKind == .google
                    ) { selectDestination(.google) }
                }
                .frame(maxWidth: 480)
                shieldNote("You review every event before it is added.")
            case .macConnected:
                sceneTitle(
                    "Your calendar is connected.",
                    subtitle: "New events will be added to the default\ncalendar on your Mac after you confirm.",
                    alignment: .leading
                )
                QuietCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            QuietIconTile(systemImage: "calendar", side: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Mac calendars")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                                Text("Uses the accounts on this Mac")
                                    .font(QuietDesign.Typography.caption)
                                    .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                            }
                            Spacer(minLength: 8)
                            QuietStatusChip(text: "Connected", tone: .success)
                        }
                        Rectangle()
                            .fill(QuietDesign.Color.separator(colorScheme))
                            .frame(height: 1)
                        HStack(spacing: 12) {
                            Text("Default calendar")
                                .font(.system(size: 13))
                                .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                            Spacer(minLength: 8)
                            Text(selectedEventKitCalendarName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: 480)
                shieldNote("You stay in control of every event.")
                eventKitChooser
            case .googleConnect:
                sceneTitle(
                    "Connect Google Calendar",
                    subtitle: "Sign in securely in your browser.\nQuikCal will bring you back here when you're done.",
                    alignment: .leading
                )
                QuietCard(padding: 26) {
                    VStack(spacing: 10) {
                        QuietIconTile(systemImage: "globe", side: 56)
                        Text("Google Calendar")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                        Text("Keep your calendar in sync across devices.")
                            .font(QuietDesign.Typography.subtitle)
                            .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 480)
                HStack(spacing: 6) {
                    Image(systemName: "lock")
                        .font(.system(size: 11))
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    Text("Your Google password is never shared with QuikCal.")
                        .font(QuietDesign.Typography.caption)
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                }
                .frame(maxWidth: 480, alignment: .leading)
                googleChooser
            case .googleConnected:
                sceneTitle(
                    "Choose a Google calendar",
                    subtitle: "Choose which calendar should receive new events.",
                    alignment: .leading
                )
                QuietCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            QuietIconTile(systemImage: "globe", side: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Google Calendar")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                                Text(googleAuth.activeAccount?.email ?? "Account connected")
                                    .font(QuietDesign.Typography.caption)
                                    .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            QuietStatusChip(text: "Connected", tone: .success)
                        }
                        Rectangle()
                            .fill(QuietDesign.Color.separator(colorScheme))
                            .frame(height: 1)
                        GoogleDestinationPicker(googleAuth: googleAuth)
                        if let account = googleAuth.activeAccount {
                            Button("Disconnect…") {
                                googleAuth.disconnect(accountID: account.id)
                            }
                            .buttonStyle(QuietTextButtonStyle())
                            .accessibilityLabel("Disconnect Google account \(account.email)")
                        }
                    }
                }
                .frame(maxWidth: 480)
                Label("You can change this in Settings.", systemImage: "gearshape")
                    .font(QuietDesign.Typography.caption)
                    .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
            case .error:
                sceneTitle(
                    "Let's try that again.",
                    subtitle: "Your calendar connection wasn't completed.\nTry again, or choose a different calendar.",
                    alignment: .leading
                )
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(QuietDesign.Color.warning)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Calendar isn't connected yet")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                            Text("No events have been added. You can safely reconnect.")
                                .font(QuietDesign.Typography.caption)
                                .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                            if destinationKind != .google, vm.accessPhase == .denied {
                                Text("Enable Calendar access in System Settings → Privacy & Security → Calendars.")
                                    .font(QuietDesign.Typography.caption)
                                    .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if destinationKind == .google, let status = googleAuth.statusMessage {
                                Text(status)
                                    .font(QuietDesign.Typography.caption)
                                    .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: 480, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: QuietDesign.Metric.cardCorner, style: .continuous)
                        .fill(QuietDesign.Color.warningFill(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: QuietDesign.Metric.cardCorner, style: .continuous)
                        .strokeBorder(QuietDesign.Color.warningStroke(colorScheme), lineWidth: 1)
                )
                Button("Choose another calendar") {
                    selectDestination(destinationKind == .google ? .eventKit : .google)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                .buttonStyle(.plain)
                .frame(maxWidth: 480)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 4)
    }

    /// One destination choice card (icon tile, copy, selection state).
    private func calendarOptionRow(
        symbol: String,
        title: String,
        subtitle: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            QuietCard(selected: selected, padding: 12) {
                HStack(spacing: 12) {
                    QuietIconTile(systemImage: symbol, side: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                        Text(subtitle)
                            .font(QuietDesign.Typography.caption)
                            .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    }
                    Spacer(minLength: 8)
                    if selected {
                        QuietSelectionMark()
                    } else {
                        Circle()
                            .strokeBorder(QuietDesign.Color.labelTertiary(colorScheme), lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(title), \(subtitle)\(selected ? ", selected" : "")")
    }

    /// "Default calendar" value for the connected card — the REAL selected
    /// writable calendar when EventKit granted one, else the honest
    /// "System default" fallback.
    private var selectedEventKitCalendarName: String {
        vm.selectionState.choice?.displayName ?? "System default"
    }

    /// Shield-check reassurance line (Every review-before-add screen).
    private func shieldNote(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.shield")
            .font(QuietDesign.Typography.caption)
            .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: 480, alignment: .leading)
    }

    /// Destination switch (2026-11-07): the preference and the local
    /// selection update IMMEDIATELY and synchronously — no auth, network,
    /// permission or model call, no Timer-delayed logic. When motion is
    /// allowed, the SAME state change is wrapped in the approved
    /// ~220 ms crossfade so the row indicator and details animate
    /// together; Reduce Motion applies it instantly.
    private func selectDestination(_ kind: CalendarDestinationKind) {
        let apply = {
            destinationKind = kind
            prefs.calendarDestinationKind = kind
        }
        if let duration = ProviderSwitchMotionPolicy.duration(reduceMotion: reduceMotion) {
            withAnimation(.easeInOut(duration: duration)) { apply() }
        } else {
            apply()
        }
    }

    private func useExistingModelFromOnboarding() {
        let source = ParakeetModelStore.hexDevModelURL
        let validation = ParakeetModelValidator.validate(fileURL: source, requireChecksum: true)
        guard validation.readiness == .ready else {
            // Surface via download snapshot message path
            modelDownload.refresh()
            return
        }
        do {
            let installed = try ParakeetModelInstaller.copyExistingModel(from: source, requireChecksum: true)
            prefs.parakeetModelPath = installed.path
            vm.speech.refreshModelReadiness()
            modelDownload.refresh()
        } catch {
            modelDownload.refresh()
        }
    }

    private var holdScene: some View {
        ScrollView {
            VStack(spacing: session.holdGuide.phase == .openSettings ? 10 : 16) {
                // The drag-guide phase is tall; keep its actions above the
                // fold. practiceHold is also compacted (0.3.13 final pass):
                // the whole practice content must fit 640×600 with the
                // footer visible — no clipping behind the footer chrome.
                Spacer(minLength: session.holdGuide.phase == .openSettings
                        || session.holdGuide.phase == .practiceHold ? 8 : 60)
                sceneTitle(
                    holdSceneTitle,
                    subtitle: holdGuideSubtitle
                )
                switch session.holdGuide.phase {
                case .pickShortcut:
                    HoldShortcutGradientPicker(selection: $shortcutSelection) { kind in
                        holdToTalk.setShortcut(kind)
                        session.holdGuide.shortcut = kind
                        persistSession()
                    }
                    .frame(maxWidth: 480)
                    // Compact keyboard/gesture preview
                    VStack(spacing: 8) {
                        HStack(spacing: 16) {
                            Label("Hold", systemImage: "mic.fill")
                                .font(.system(size: 12, weight: .medium))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Label("Listening", systemImage: "waveform")
                                .font(.system(size: 12, weight: .medium))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Label("Release", systemImage: "hand.raised")
                                .font(.system(size: 12, weight: .medium))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Label("Confirm", systemImage: "checkmark.circle")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                        Text("Selected: \(shortcutSelection.displayName)")
                    }

                case .explainConflict:
                    Text(HoldToTalkGuideCopy.conflictExplanation(for: shortcutSelection))
                        .font(OnboardTone.body)
                        .foregroundStyle(.primary.opacity(0.85))
                        .frame(maxWidth: 480, alignment: .leading)

                case .accessibilityExplain:
                    Text(HoldToTalkGuideCopy.accessibilityWhy)
                        .font(OnboardTone.body)
                        .foregroundStyle(.primary.opacity(0.85))
                        .frame(maxWidth: 480, alignment: .leading)

                case .openSettings:
                    // 0.3.12 compact product page: shared setup card (steps,
                    // drag tile, Open Settings / Reveal App, live status,
                    // Check again). The tile exports only Bundle.main; it
                    // never moves the app, grants permission, or edits TCC.
                    accessibilitySetupCard
                    Text(AccessibilityDragGuideCopy.approveNote)
                        .font(OnboardTone.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 480, alignment: .leading)
                    Text(AccessibilityDragGuideCopy.manualNextNote)
                        .font(OnboardTone.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 480, alignment: .leading)

                    AccessibilityGuideDetails(
                        payload: dragPayload,
                        isExpanded: $detailsExpanded
                    )

                case .recheckPermission:
                    HStack {
                        Text("Accessibility")
                        Spacer()
                        // Live flag (or DEBUG fixture) is authoritative;
                        // the guide state mirrors it on explicit Recheck.
                        Text(effectiveAccessibilityTrusted
                             ? AccessibilityDragGuideCopy.enabledCheck
                             : HoldToTalkGuideCopy.recheckLabel(session.holdGuide.accessibilityRecheck))
                            .foregroundStyle(
                                effectiveAccessibilityTrusted || session.holdGuide.accessibilityRecheck == .granted
                                ? OnboardTone.accent
                                : Color.secondary
                            )
                    }
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: 400)
                    Button(AccessibilityDragGuideCopy.checkAgain) {
                        // Fresh probe + guarded listener re-attach (no
                        // restart needed once trust is real; no duplicate
                        // taps — start removes old monitors first).
                        holdToTalk.checkAgainAndReattach()
                        session.holdGuide.applyAccessibilityTrusted(effectiveAccessibilityTrusted)
                        persistSession()
                    }
                    .buttonStyle(QuietSecondaryButtonStyle())
                    Text(AccessibilityDragGuideCopy.statusLine(
                        accessibilityTrusted: effectiveAccessibilityTrusted,
                        location: dragPayload.location
                    ))
                    .font(OnboardTone.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    Text("You can continue anyway — typing still works.")
                        .font(OnboardTone.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    if let mismatchHint = holdToTalk.accessibilityMismatchHint, !effectiveAccessibilityTrusted {
                        // Honest, non-assertive troubleshooting — shown ONCE
                        // (this page), quiet styling, never an orange paragraph,
                        // never a "switched off" claim we cannot observe.
                        Text(mismatchHint)
                            .font(OnboardTone.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: 440, alignment: .leading)
                    }

                case .enableMonitoring:
                    // 0.3.12: Enable is offered ONLY when Accessibility is
                    // actually trusted. Otherwise this page shows the SAME
                    // running-bundle setup card as the Accessibility step
                    // (Open Settings primary + drag/reveal + Check again) —
                    // never a dead-end "open settings" sentence.
                    if effectiveAccessibilityTrusted {
                        Text("Accessibility granted.")
                            .font(OnboardTone.body)
                            .frame(maxWidth: 480, alignment: .leading)
                        Button("Enable hold-to-talk") {
                            holdToTalk.practicePreviewOnly = false
                            holdToTalk.enablePersistedMonitoring()
                        }
                        .buttonStyle(QuietPrimaryButtonStyle())
                        if let status = holdToTalk.lastStatus {
                            Text(status).font(OnboardTone.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        accessibilitySetupCard
                    }

                case .practiceHold:
                    Text(HoldToTalkGuideCopy.practiceHoldHint(for: shortcutSelection))
                        .font(OnboardTone.body)
                        .foregroundStyle(.primary.opacity(0.85))
                        .frame(maxWidth: 460)
                    // 0.3.13 (design 24:46–24:53, 7:69/7:95/7:121/7:154):
                    // the REAL key cap, driven only by the live monitor.
                    // Held → lifts + fills red (recording semantics, nothing
                    // destructive); released → settles neutral; detection
                    // not installed → honest muted cap. Reduce Motion: no
                    // lift — red fill + label carry the state.
                    FnKeyCapView(
                        keyLabel: shortcutSelection.shortName,
                        state: effectivePracticeKeyState,
                        reduceMotion: reduceMotion
                    )
#if DEBUG
                    if qaPracticeKeyFixture != nil {
                        // Labelled QA fixture: the cap state is simulated
                        // for a screenshot — never a real hold.
                        Text("QA fixture — simulated key state")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.orange.opacity(0.12)))
                    }
#endif
                    Button("Try it") {
                        // Starts real monitor-backed detection ONLY — the
                        // button press itself never fakes a hold or a
                        // release (the "Released" status previously lit up
                        // straight from this press; fixed 2026-11-07 per
                        // owner screenshot evidence). The persisted "seen"
                        // is recorded ONLY when the monitor actually
                        // delivers a hold→release cycle.
                        holdToTalk.practicePreviewOnly = true
                        holdToTalk.startMonitoringIfPermitted()
                        holdToTalk.onPracticeRelease = {
                            // Captures a COPY of this view struct (struct,
                            // not a class) — the @State write reaches the
                            // live view storage; the callback is cleared on
                            // advance/dismiss so the monitor never keeps a
                            // dangling reference.
                            session.holdGuide.markPracticeHoldSeen()
                            persistSession()
                        }
                        persistSession()
                    }
                    .buttonStyle(QuietPrimaryButtonStyle())
                    PracticeStatusCard(text: practiceHoldStatus)
                    Text(HoldToTalkGuideCopy.practiceNothingSavedNote)
                        .font(OnboardTone.caption)
                        .foregroundStyle(.secondary)
                    copyShortcutDiagnosticsButton

                case .done:
                    Text("Hold-to-talk guide complete. Reopen it anytime from Settings.")
                        .font(OnboardTone.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
            }
            .padding(.bottom, 8)
        }
    }

    /// Shared Accessibility setup card (0.3.12): steps, drag tile, Open
    /// Settings / Reveal App, and the live status + Check again row. Used by
    /// BOTH the openSettings phase and the enableMonitoring phase (when
    /// untrusted) so the same action never spawns duplicate subpages.
    @ViewBuilder
    private var accessibilitySetupCard: some View {
        if dragPayload.location.requiresInstallFirst {
            InstallFirstWarning(
                payload: dragPayload,
                isQAFixture: isQAFixtureActive
            )
            HStack(spacing: 10) {
                Button(AccessibilityDragGuideCopy.revealApp) {
                    AccessibilityDragGuideInfo.revealInFinder(dragPayload)
                }
                .buttonStyle(QuietPrimaryButtonStyle())
            }
        } else {
            AccessibilityStepsList(steps: AccessibilityDragGuideCopy.steps)
            if dragPayload.offersDragTile {
                DraggableAppIconTile(
                    payload: dragPayload,
                    icon: AccessibilityDragGuideInfo.appIcon(for: dragPayload, realBundleURL: Bundle.main.bundleURL),
                    isQAFixture: isQAFixtureActive
                )
            }
            Text(AccessibilityDragGuideCopy.alreadyListedHint)
                .font(OnboardTone.caption)
                .foregroundStyle(.secondary)
            Text(AccessibilityDragGuideCopy.dragDoesNotGrantShort)
                .font(OnboardTone.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(AccessibilityDragGuideCopy.openSettings) {
                    // Opens the pane only — no prompt, no grant. 0.3.16:
                    // the capability-correct pane + the compact drag-assist
                    // panel alongside System Settings.
                    let capability = HoldToTalkPermissionPolicy.requiredCapability(
                        for: holdToTalk.machine.shortcut)
                    if capability == .inputMonitoring {
                        holdToTalk.openInputMonitoringSettings()
                    } else {
                        holdToTalk.openAccessibilitySettings()
                    }
                    PrivacyDragPanelPresenter.shared.present(for: capability, monitor: holdToTalk)
                }
                .buttonStyle(QuietPrimaryButtonStyle())
                Button(AccessibilityDragGuideCopy.revealApp) {
                    AccessibilityDragGuideInfo.revealInFinder(dragPayload)
                }
                .buttonStyle(QuietSecondaryButtonStyle())
            }
        }
        // Status / check-again row. `AXIsProcessTrusted` is the only
        // authority; Next stays manual.
        HStack(spacing: 8) {
            Text("Accessibility")
                .font(.system(size: 13, weight: .medium))
            if effectiveAccessibilityTrusted {
                Label(AccessibilityDragGuideCopy.enabledCheck, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnboardTone.accent)
            } else {
                Text(AccessibilityDragGuideCopy.notYetCheck)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(AccessibilityDragGuideCopy.checkAgain) {
                // Fresh probe + guarded listener re-attach — a grant made
                // in System Settings takes effect without a restart.
                holdToTalk.checkAgainAndReattach()
                session.holdGuide.applyAccessibilityTrusted(effectiveAccessibilityTrusted)
                persistSession()
            }
            .buttonStyle(QuietSecondaryButtonStyle())
        }
        .frame(maxWidth: 480)
        copyShortcutDiagnosticsButton
    }

    /// Practice page title (owner, 2026-11-06): "Try Fn", not "Practice hold".
    private var holdSceneTitle: String {
        if session.holdGuide.phase == .practiceHold {
            return "Try \(shortcutSelection.shortName)"
        }
        return session.holdGuide.phase.title
    }

    private var holdGuideSubtitle: String {
        switch session.holdGuide.phase {
        case .pickShortcut:
            return "Choose a modifier key for hold-to-talk."
        case .explainConflict:
            return "QuikCal never remaps system keys."
        case .accessibilityExplain:
            return "One permission, requested only when you act."
        case .openSettings:
            return AccessibilityDragGuideCopy.guideSubtitle
        case .recheckPermission:
            return "Check again after changing Settings."
        case .enableMonitoring:
            return "Optional. Skip keeps typing."
        case .practiceHold:
            return "Safe preview — no calendar writes."
        case .done:
            return "You’re set."
        }
    }

    private var practiceHoldStatus: String {
        // Honest per PracticeDetectionPolicy: "Released" appears only after
        // a REAL monitor-detected hold→release cycle. When monitoring could
        // not install (Accessibility not trusted), the copy says detection
        // is not active instead of implying a hold would work.
#if DEBUG
        // QA fixture consistency (labelled in-frame by the orange chip):
        // a simulated held/neutral cap pairs with the matching
        // simulated-trusted-monitor status so the screenshot is not
        // contradictory. `.unavailable` (and no fixture — production)
        // keeps the REAL honest status; detection is never faked there.
        if let override = OnboardingVoiceVisualPolicy.qaPracticeStatusOverride(fixture: qaPracticeKeyFixture) {
            return override
        }
#endif
        return PracticeDetectionPolicy.practiceStatusText(
            phase: holdToTalk.practicePhase,
            releaseDetected: holdToTalk.practiceReleaseCount > 0,
            listenerInstalled: holdToTalk.monitorsInstalled,
            accessibilityTrusted: effectiveAccessibilityTrusted,
            shortcutName: shortcutSelection.displayName
        )
    }

    /// Compact per-process diagnostic (0.3.13): app version/path, code
    /// signature status, Accessibility trust AS THE PROCESS SEES IT, listener
    /// install state, persisted intent, selected shortcut NAME, press/release
    /// COUNTS. No key text, no token/secret values, read-only probes only.
    /// Rendered as a small quiet text link (0.3.13 final pass): diagnostic
    /// detail is a copy-to-clipboard affordance, not a chrome pill — it must
    /// never crowd the practice content or clip behind the footer.
    @ViewBuilder
    private var copyShortcutDiagnosticsButton: some View {
        Button("Copy shortcut diagnostics") {
            copyShortcutDiagnosticsToPasteboard()
        }
        .buttonStyle(QuietTextButtonStyle())
    }

    private func copyShortcutDiagnosticsToPasteboard() {
        let facts = ShortcutDiagnosticCollector.facts(
            monitor: holdToTalk,
            prefs: prefs
        )
        let text = ShortcutDiagnosticsFormatter.render(facts)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Ready-page variants, derived ONLY from live state — the approved
    /// design ships all three (all-set / download-in-background /
    /// typing-only), and each names the real readiness of THIS Mac.
    private enum ReadyVariant {
        /// Voice model on disk and voice not skipped — the full promise.
        case allSet
        /// Voice model still transferring — typing works right now.
        case downloading
        /// Voice deferred/not downloaded — typing is the ready path.
        case typing
    }

    private var readyVariant: ReadyVariant {
        if modelDownload.isSpeechReady && !session.skipped.contains(.voiceSetup) {
            return .allSet
        }
        if modelDownload.isTransferring {
            return .downloading
        }
        return .typing
    }

    private var completionScene: some View {
        VStack(spacing: 22) {
            switch readyVariant {
            case .allSet:
                ZStack {
                    Circle()
                        .fill(QuietDesign.Color.selectedFill(colorScheme))
                        .frame(width: 72, height: 72)
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(QuietDesign.Color.primaryFill)
                }
                VStack(spacing: 10) {
                    Text("You're all set.")
                        .font(QuietDesign.Typography.title)
                        .fontWeight(.bold)
                        .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                    Text("QuikCal lives in your menu bar.\nHold \(shortcutSelection.shortName) whenever you need to add an event.")
                        .font(QuietDesign.Typography.subtitle)
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                readySummaryCard(voiceValue: "Ready on this Mac", voiceSage: true)
            case .downloading:
                QuietIconTile(systemImage: "waveform", side: 64)
                VStack(spacing: 10) {
                    Text("Ready when you are.")
                        .font(QuietDesign.Typography.title)
                        .fontWeight(.bold)
                        .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                    Text("Start with typing while voice support downloads.\nQuikCal will let you know when voice is ready.")
                        .font(QuietDesign.Typography.subtitle)
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                QuietCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            QuietIconTile(systemImage: "waveform", side: 28)
                            Text("Voice support is downloading")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                            Spacer(minLength: 8)
                            if let fraction = speechProgressFraction {
                                Text("\(Int((fraction * 100).rounded()))%")
                                    .font(.system(size: 13, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                            }
                        }
                        ProgressView(value: speechProgressFraction ?? 0)
                            .tint(QuietDesign.Color.primaryFill)
                        Text("No need to keep this window open.")
                            .font(QuietDesign.Typography.caption)
                            .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    }
                }
                .frame(maxWidth: 440)
            case .typing:
                QuietIconTile(systemImage: "menubar.rectangle", side: 64)
                VStack(spacing: 10) {
                    Text("You're ready to type.")
                        .font(QuietDesign.Typography.title)
                        .fontWeight(.bold)
                        .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                    Text("Open QuikCal from your menu bar.\nYou can enable voice anytime in Settings.")
                        .font(QuietDesign.Typography.subtitle)
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                readySummaryCard(voiceValue: "Set up later", voiceSage: false, inputRow: true)
            }
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 32)
    }

    /// The Ready summary card — Calendar / Shortcut (or Input) / Voice
    /// rows, values in the primary label color, voice value sage ONLY
    /// when genuinely ready.
    private func readySummaryCard(
        voiceValue: String,
        voiceSage: Bool,
        inputRow: Bool = false
    ) -> some View {
        QuietCard(padding: 16) {
            VStack(spacing: 12) {
                readySummaryRow(
                    label: "Calendar",
                    value: destinationKind == .google ? "Google Calendar" : "Mac calendars",
                    sage: false
                )
                Rectangle()
                    .fill(QuietDesign.Color.separator(colorScheme))
                    .frame(height: 1)
                readySummaryRow(
                    label: inputRow ? "Input" : "Shortcut",
                    value: inputRow ? "Typing" : "Hold \(shortcutSelection.shortName)",
                    sage: false
                )
                Rectangle()
                    .fill(QuietDesign.Color.separator(colorScheme))
                    .frame(height: 1)
                readySummaryRow(label: "Voice", value: voiceValue, sage: voiceSage)
            }
        }
        .frame(maxWidth: 440)
    }

    private func readySummaryRow(label: String, value: String, sage: Bool) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(sage
                                 ? QuietDesign.Color.accent
                                 : QuietDesign.Color.labelPrimary(colorScheme))
        }
    }

    // MARK: Shared pieces

    private func sceneTitle(
        _ title: String,
        subtitle: String,
        alignment: HorizontalAlignment = .center
    ) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(OnboardTone.display)
                .fontWeight(.bold)
                .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                .multilineTextAlignment(alignment == .leading ? .leading : .center)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
            Text(subtitle)
                .font(OnboardTone.subtitle)
                .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                .multilineTextAlignment(alignment == .leading ? .leading : .center)
                .frame(maxWidth: 440, alignment: alignment == .leading ? .leading : .center)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
        }
    }

    private func featureLine(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnboardTone.accent)
                .frame(width: 22)
            Text(text)
                .font(OnboardTone.body)
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    /// EventKit detail BELOW the connected card (full access only): the
    /// writable-calendar choice. Under write-only, listing is impossible
    /// — the honest line explains where events go instead. The not-
    /// determined path never renders (the choosing stage offers the
    /// primary action instead) and the denied path is rendered by the
    /// error stage, so this view is only reached when connected.
    private var eventKitChooser: some View {
        switch vm.accessPhase {
        case .granted, .writeOnly:
            VStack(alignment: .leading, spacing: 8) {
                if vm.accessPhase == .writeOnly {
                    Text("Connected — events go to your default calendar. Full Access additionally enables browsing calendars and voice delete.")
                        .font(QuietDesign.Typography.caption)
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480, alignment: .leading)
                } else if vm.calendarChoices.isEmpty {
                    Text("No writable calendars found.")
                        .font(QuietDesign.Typography.caption)
                        .foregroundStyle(QuietDesign.Color.warning)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(vm.calendarChoices) { choice in
                                Button {
                                    vm.selectCalendar(choice)
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(choice.displayName)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                                        Spacer(minLength: 8)
                                        if vm.selectionState.choice?.id == choice.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundStyle(QuietDesign.Color.accent)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(QuietDesign.Color.card(colorScheme))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(QuietDesign.Color.cardStroke(colorScheme), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(vm.selectionState.choice?.id == choice.id ? .isSelected : [])
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
        case .denied:
            Text("Calendar access denied. Enable it in System Settings → Privacy & Security → Calendars.")
                .font(QuietDesign.Typography.caption)
                .foregroundStyle(QuietDesign.Color.warning)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        default:
            VStack(spacing: 8) {
                Button("Connect calendar") { vm.requestCalendarAccess() }
                    .buttonStyle(QuietPrimaryButtonStyle())
                Text("Asked only when you click — not at launch.")
                    .font(QuietDesign.Typography.caption)
                    .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
            }
        }
    }

    private var googleChooser: some View {
        // 0.3.13 (design 6:122 / 24:45 / 6:147): signed-out state is airy
        // and direct — primary "Sign in with Google…" and the import as a
        // tiny muted but ENABLED link (44 pt hit target, full accessible
        // name). No card container clutter, no repeated subtitle, no
        // technical import explainer in the regular signed-out UI.
        VStack(alignment: .leading, spacing: 10) {
#if DEBUG
            if qaGoogleConfigFixture {
                // Labelled QA fixture: the client config is a placeholder
                // env value for a screenshot — never a real credential.
                Text("QA fixture — placeholder client config")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
#endif
            switch googleAuth.phase {
            case .unconfigured:
                Text(OnboardingGoogleCopy.unconfiguredNote)
                    .font(OnboardTone.caption)
                    .foregroundStyle(.secondary)
            case .signedOut, .error:
                // 0.3.13 final pass (parent visual review): the destination
                // row above already carries "Sign in to connect your
                // calendar." — do not repeat it here. The main sign-in
                // action speaks for itself.
                Button("Sign in with Google…") { googleAuth.beginSignIn() }
                    .buttonStyle(QuietPrimaryButtonStyle())
            case .authorizing:
                ProgressView("Waiting for browser…")
                Button("Cancel") { googleAuth.cancelSignIn() }
                    .buttonStyle(QuietTextButtonStyle())
            case .signedIn:
                // The signed-in lane renders inside the "Choose a Google
                // calendar" destination card (account row + writable
                // picker) — never a second, duplicate sign-in surface.
                EmptyView()
            }
            // Tiny muted import link (enabled + focusable; ~44 pt hit
            // target via padding) with its full accessible name. The
            // technical "Cloud Console JSON → Keychain" explainer was
            // REMOVED from the regular signed-out UI (0.3.13 final pass,
            // parent visual review): the link stays readable grey and
            // self-describing; detailed import guidance lives in Settings
            // and the file picker's own message.
            if googleAuth.phase != .signedIn && googleAuth.phase != .authorizing {
                Button {
                    pickAndImportGoogleClientJSON()
                } label: {
                    HStack(spacing: 4) {
                        if isImportingGoogleConfig {
                            ProgressView().controlSize(.mini)
                        }
                        Text(OnboardingVoiceVisualPolicy.GoogleSignedOutCopy.importLinkLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .underline()
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isImportingGoogleConfig)
                .accessibilityLabel(OnboardingVoiceVisualPolicy.GoogleSignedOutCopy.importAccessibilityLabel)
                if let importStatus = googleImportStatus {
                    Text(importStatus)
                        .font(OnboardTone.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let status = googleAuth.statusMessage {
                Text(status).font(OnboardTone.caption).foregroundStyle(.secondary)
            }
            // Sanitized diagnostic copy (0.3.12): owner-pasteable fields only —
            // status, error classification, missing-parameter NAME, request
            // field NAMES, version, running path. No values, no URLs, no tokens.
            if googleAuth.lastDiagnostics != nil {
                Button("Copy diagnostics") {
                    if let text = googleAuth.lastDiagnostics {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
                .buttonStyle(QuietSecondaryButtonStyle())
            }
        }
    }

    /// 0.3.13: local import of the Google "Desktop app" client JSON from
    /// onboarding — the OWNER picks the downloaded file (NSOpenPanel; the
    /// app never scans for credentials). Strict validation, atomic
    /// Keychain write, failures change nothing. Mirrors the Settings
    /// flow (SettingsWindowController) — no auto sign-in, no revoke.
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
                    self.googleImportStatus = "Imported Google configuration — press “Sign in with Google…” to connect."
                case .failure(let error):
                    self.googleImportStatus = (error as? GoogleClientSecretImportError)?
                        .errorDescription ?? "The Google configuration file could not be imported (unexpected format)."
                }
            }
        }
    }

}

// MARK: - Buttons
//
// 0.3.20: `QuietPrimaryButtonStyle` and `QuietSecondaryButtonStyle` moved to
// the shared design system in `QuietUI.swift` (identical bodies) so the
// saved/schedule screen uses the SAME onboarding primitives — one
// implementation, no per-file duplicates. `QuietTextButtonStyle` moved
// there too with the 2026-11-12 token foundation.

// MARK: - 0.3.13 onboarding visual components (design REV2.1)

/// The practice key cap (design 24:46–24:53): 72×56 rounded cap whose
/// state derives ONLY from the real Accessibility monitor. Held → lifts
/// and fills red; released → settles neutral; detection unavailable →
/// honest muted cap. Reduce Motion → no lift, red fill + label only.
/// Thin wrapper kept for the shared onboarding page contract: the approved
/// shared keycap lives in QuietUI.swift (`QuietKeyCap`); this preserves the
/// onboarding file's callsites and the hold-guide layout.
private struct FnKeyCapView: View {
    var keyLabel: String
    var state: OnboardingVoiceVisualPolicy.PracticeKeyState
    var reduceMotion: Bool

    var body: some View {
        QuietKeyCap(
            keyLabel: keyLabel,
            subtitle: "Hold to speak",
            state: state,
            reduceMotion: reduceMotion,
            size: .large
        )
    }
}

/// Tinted status card for the practice page (design 7:85/7:111/7:137/7:170):
/// muted gray while waiting, green while holding/released, warm red when
/// detection is not active. Copy comes from PracticeDetectionPolicy —
/// honest, never simulated.
private struct PracticeStatusCard: View {
    var text: String

    private var isUnavailable: Bool {
        text.contains("not active")
    }

    private var isHolding: Bool {
        text.contains("Holding")
    }

    private var isReleased: Bool {
        text.contains("Released")
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(
                isUnavailable
                ? Color(red: 0.843, green: 0.204, blue: 0.0) // #c93400
                : (isHolding
                   ? Color(red: 0.306, green: 0.478, blue: 0.384) // #4e7a62
                   : (isReleased
                      ? Color(red: 0.114, green: 0.557, blue: 0.247) // #1d8e3e
                      : .secondary))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .accessibilityLabel(text)
    }
}

// 2026-11-07: `GlassComparisonTile` and `MiniWaveform` (the removed
// Low/Current/High comparison tiles, design 26:2–26:32) were DELETED per
// the owner's one-preview revision — superseded by `VoiceBarPreviewStage`
// in VoiceBarGlass.swift, which stages the REAL production pill view.
