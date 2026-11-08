import Foundation

#if DEBUG
/// DEBUG-only QA host routing (0.3.4). Pure + unit-testable.
/// Production (Release) builds compile this entire file out — the
/// `#if DEBUG` gate means Release binaries contain no QA strings.
/// The QA suite is a separate ephemeral domain
/// (`com.quietcalendar.qa034`) so the owner's real prefs are never touched.
public enum QAHostRouter: Sendable {
    public static let qaDefaultsSuiteName = "com.quietcalendar.qa034"
    public static let defaultsFlag = "--qc-qa-defaults"
    public static let surfaceFlag = "--qc-qa-surface"
    public static let modelsStateFlag = "--qc-qa-models-state"
    public static let stepFlag = "--qc-qa-step"
    /// DEBUG-only 0.3.14 compact-flow fixture: open onboarding directly on
    /// a 4-page page raw (0=welcome 1=calendar 2=voiceSetup 3=ready).
    public static let pageFlag = "--qc-qa-page"
    public static let glassFlag = "--qc-qa-glass"
    public static let windowIDFileFlag = "--qc-qa-window-id-file"
    public static let practiceFlag = "--qc-qa-practice"
    /// DEBUG-only larger-text fixture (0.3.5): `large` or `xxxlarge`.
    public static let textSizeFlag = "--qc-qa-text-size"
    /// DEBUG-only 0.3.6 fixtures: fake AX trust + app-location for the drag
    /// guide screenshots (clearly labelled in-frame; never a real grant).
    public static let axTrustedFlag = "--qc-qa-ax-trusted"
    /// DEBUG-only 2026-11-07 review fixture: render the UNTRUSTED
    /// permission UI even when the QA process's REAL Accessibility trust
    /// is inherited from the owner's TCC grant (same signed app identity).
    /// Labelled in-frame; never a TCC change — display only.
    public static let axUntrustedFlag = "--qc-qa-ax-untrusted"
    public static let appLocationFlag = "--qc-qa-app-location"
    /// DEBUG-only 0.3.7 fixture: open the Details disclosure for the
    /// bounded-scroll screenshot. Never affects production.
    public static let detailsFlag = "--qc-qa-details"
    /// DEBUG-only 0.3.7: append pop-animation lifecycle timestamps here.
    public static let popLogFlag = "--qc-qa-pop-log"
    /// DEBUG-only 0.3.7: write the real NSItemProvider payload probe here.
    public static let dragProbeFlag = "--qc-qa-drag-probe"
    /// DEBUG-only 0.3.13 cards pass: force window appearance (light|dark).
    public static let appearanceFlag = "--qc-qa-appearance"
    /// DEBUG-only 0.3.13 cards pass: suppress the launch entry card so
    /// individual step scenes capture directly (on|off).
    public static let entryCardFlag = "--qc-qa-entry-card"
    /// DEBUG-only 0.3.13 cards pass: hold-guide phase to open (raw int).
    public static let holdPhaseFlag = "--qc-qa-hold-phase"
    /// DEBUG-only 0.3.13 cards pass: practice key cap state
    /// (neutral|holding|released|unavailable) — labelled, never a real hold.
    public static let practiceKeyFlag = "--qc-qa-practice-key"
    /// DEBUG-only 0.3.13 cards pass: calendar destination fixture
    /// (eventKit|google) in the ephemeral QA domain.
    public static let destinationFlag = "--qc-qa-destination"
    /// DEBUG-only 0.3.13 cards pass: the Google client config is a
    /// placeholder env fixture — label it in-frame.
    public static let googleConfigFlag = "--qc-qa-google-config"
    /// DEBUG-only 0.3.13 cards pass: display-only delete-review fixture
    /// (confirm|chooser) for the capture panel screenshots.
    public static let deleteStateFlag = "--qc-qa-delete-state"
    /// DEBUG-only 0.3.13 follow-up: repair-card fixture state
    /// (trustedNoListener) — labelled in-frame, never a real grant or
    /// TCC change; the QA process's real probes stay untouched.
    public static let repairStateFlag = "--qc-qa-repair-state"
    /// DEBUG-only 2026-11-07 review pass: initial Settings pane for the
    /// settings-surface QA screenshot (general|calendars|appearance|speech).
    /// The previous Settings QA shot captured the DEFAULT General pane —
    /// this flag lets the isolated QA host capture the real Appearance
    /// section. Compiled out of Release; production always opens General.
    public static let settingsSectionFlag = "--qc-qa-settings-section"
    /// DEBUG-only 2026-11-07 working-bar pass: voice-pill fixture state for
    /// labelled screenshots (listeningPartial|transcribing|understanding).
    /// The preview text is the SYNTHETIC fixture transcript — never owner
    /// audio, never a real capture.
    public static let voiceBarStateFlag = "--qc-qa-voice-bar-state"
    /// DEBUG-only 2026-11-07 Yes/No pass: display-only confirm fixture
    /// (single|multi) for capture-panel screenshots — no sink is configured
    /// in the QA process, so Add fails closed; nothing is written.
    public static let confirmStateFlag = "--qc-qa-confirm-state"
    /// DEBUG-only 2026-11-07 Yes/No pass: display-only note fixture
    /// (noCorrection) — the state AFTER an explicit No: recognized text
    /// retained in the editable field with the honest re-speak hint.
    public static let noteStateFlag = "--qc-qa-note-state"
    /// DEBUG-only 2026-11-07 Fn-fix pass: write a one-shot live probe of
    /// THIS QA process's Fn event-tap installability (own process only —
    /// install, record, uninstall; no events are watched, no key is
    /// posted, no mic, no TCC change).
    public static let fnTapProbeFlag = "--qc-qa-fn-tap-probe"
    /// DEBUG-only 0.3.13 cards pass: in-process PNG dump of the QA
    /// window's own content layer (no screencapture, no TCC, no screen).
    /// The app writes the 2x PNG here and exits.
    public static let shotFlag = "--qc-qa-shot"
    /// DEBUG-only 2026-11-07 launch-repair routing fix: run the REAL
    /// cold-launch routing with an ephemeral QA profile and dump which
    /// surfaces were actually created — the regression proof that no
    /// automatic repair-card presentation exists on the launch path.
    /// Value: completed | incomplete.
    public static let launchProfileFlag = "--qc-qa-launch-profile"
    /// DEBUG-only 2026-11-07 launch-repair routing fix: launch-probe
    /// dump path (written after the launch surfaces settle, then exit).
    public static let launchProbeFlag = "--qc-qa-launch-probe"

    public static func parse(arguments: [String]) -> QAHostConfig? {
        guard arguments.contains(defaultsFlag) else { return nil }
        var config = QAHostConfig()
        func value(after flag: String) -> String? {
            guard let idx = arguments.firstIndex(of: flag), idx + 1 < arguments.count else { return nil }
            return arguments[idx + 1]
        }
        if let raw = value(after: surfaceFlag), let surface = QASurface(rawValue: raw) {
            config.surface = surface
        }
        if let raw = value(after: modelsStateFlag), let state = QAModelsFixtureState(rawValue: raw) {
            config.modelsState = state
        }
        if let raw = value(after: stepFlag), let step = OnboardingStep(rawValue: Int(raw) ?? -1) {
            // Legacy step raws migrate through the SAME explicit map as
            // persisted snapshots — old QA scripts keep working.
            config.page = OnboardingPageMigration.page(forLegacyStepRaw: step.rawValue)
        }
        if let raw = value(after: pageFlag), let page = OnboardingPage(rawValue: Int(raw) ?? -1) {
            config.page = page
        }
        if let raw = value(after: glassFlag), let v = Double(raw) {
            config.glassPercent = v
        }
        config.windowIDFilePath = value(after: windowIDFileFlag)
        config.practiceAutoRun = arguments.contains(practiceFlag)
        if let raw = value(after: textSizeFlag) {
            config.textSize = raw
        }
        config.axTrustedFixture = arguments.contains(axTrustedFlag)
        config.axUntrustedFixture = arguments.contains(axUntrustedFlag)
        if let raw = value(after: appLocationFlag) {
            config.appLocationFixture = raw
        }
        config.detailsExpandedFixture = arguments.contains(detailsFlag)
        config.popLogFilePath = value(after: popLogFlag)
        config.dragProbeFilePath = value(after: dragProbeFlag)
        if let raw = value(after: appearanceFlag) {
            config.appearance = raw
        }
        config.entryCardSuppressed = (value(after: entryCardFlag) == "off")
        if let raw = value(after: holdPhaseFlag) {
            config.holdGuidePhase = Int(raw)
        }
        if let raw = value(after: practiceKeyFlag),
           OnboardingVoiceVisualPolicy.PracticeKeyState(rawValue: raw) != nil {
            config.practiceKeyState = raw
        }
        if let raw = value(after: destinationFlag) {
            config.destination = raw
        }
        config.googleConfigFixture = arguments.contains(googleConfigFlag)
        if let raw = value(after: deleteStateFlag), let state = QADeleteFixtureState(rawValue: raw) {
            config.deleteState = state
        }
        if let raw = value(after: repairStateFlag) {
            config.repairCardState = raw
        }
        config.fnTapProbePath = value(after: fnTapProbeFlag)
        config.settingsSection = value(after: settingsSectionFlag)
        if let raw = value(after: voiceBarStateFlag) {
            config.voiceBarState = raw
        }
        if let raw = value(after: confirmStateFlag) {
            config.confirmState = raw
        }
        if let raw = value(after: noteStateFlag) {
            config.noteState = raw
        }
        config.shotPath = value(after: shotFlag)
        if let raw = value(after: launchProfileFlag) {
            config.launchProfile = raw
        }
        config.launchProbePath = value(after: launchProbeFlag)
        return config
    }
}

public struct QAHostConfig: Sendable, Equatable {
    public var surface: QASurface?
    public var modelsState: QAModelsFixtureState?
    /// Onboarding page to open (from the legacy `--qc-qa-step` raw via the
    /// migration map, or the new `--qc-qa-page` raw).
    public var page: OnboardingPage?
    public var glassPercent: Double?
    public var windowIDFilePath: String?
    public var practiceAutoRun: Bool = false
    /// DEBUG-only larger-text fixture value (`large` / `xxxlarge`), if any.
    public var textSize: String?
    /// DEBUG-only: simulate `AXIsProcessTrusted() == true` for screenshots.
    public var axTrustedFixture: Bool = false
    /// DEBUG-only 2026-11-07 review: simulate the UNTRUSTED permission UI
    /// for screenshots (the QA process may inherit the owner's real trust).
    public var axUntrustedFixture: Bool = false
    /// DEBUG-only: `installed` | `dev` | `dmg` | `translocated`.
    public var appLocationFixture: String?
    /// DEBUG-only: open the Details disclosure.
    public var detailsExpandedFixture: Bool = false
    /// DEBUG-only: pop-animation lifecycle log path.
    public var popLogFilePath: String?
    /// DEBUG-only: NSItemProvider payload probe output path.
    public var dragProbeFilePath: String?
    /// DEBUG-only 0.3.13 cards pass: window appearance (light|dark).
    public var appearance: String?
    /// DEBUG-only 0.3.13 cards pass: suppress the launch entry card.
    public var entryCardSuppressed: Bool = false
    /// DEBUG-only 0.3.13 cards pass: hold-guide phase (raw int).
    public var holdGuidePhase: Int?
    /// DEBUG-only 0.3.13 cards pass: practice key cap state (labelled).
    public var practiceKeyState: String?
    /// DEBUG-only 0.3.13 cards pass: calendar destination fixture.
    public var destination: String?
    /// DEBUG-only 0.3.13 cards pass: placeholder Google client config.
    public var googleConfigFixture: Bool = false
    /// DEBUG-only 0.3.13 cards pass: display-only delete-review fixture.
    public var deleteState: QADeleteFixtureState?
    /// DEBUG-only 0.3.13 follow-up: repair-card fixture state
    /// (`trustedNoListener`) — a LABELLED screenshot state the real
    /// untrusted QA probe cannot produce without touching TCC.
    public var repairCardState: String?
    /// DEBUG-only 2026-11-07 Fn-fix pass: live event-tap probe output path.
    public var fnTapProbePath: String?
    /// DEBUG-only 2026-11-07 review pass: initial Settings pane for the
    /// settings-surface QA screenshot (raw `SettingsPane` rawValue).
    public var settingsSection: String?
    /// DEBUG-only 2026-11-07 working-bar pass: voice-pill fixture state
    /// (listeningPartial|transcribing|understanding) — labelled, synthetic
    /// preview text only, never a real capture.
    public var voiceBarState: String?
    /// DEBUG-only 2026-11-07 Yes/No pass: display-only confirm fixture
    /// (single|multi) — no sink in the QA process; Add fails closed.
    public var confirmState: String?
    /// DEBUG-only 2026-11-07 Yes/No pass: display-only note fixture
    /// (noCorrection) — post-No state with the retained transcript + hint.
    public var noteState: String?
    /// DEBUG-only 0.3.13 cards pass: in-process PNG dump path (2x, own
    /// content layer — no screencapture, no TCC).
    public var shotPath: String?
    /// DEBUG-only 2026-11-07 launch-repair routing fix: ephemeral QA
    /// launch profile for the launch probe (completed | incomplete).
    public var launchProfile: String?
    /// DEBUG-only 2026-11-07 launch-repair routing fix: launch-probe
    /// dump path.
    public var launchProbePath: String?

    public init() {}
}

#if DEBUG
/// DEBUG-only pop lifecycle log. Writes system-uptime timestamps for the
/// real QA window so once-per-presentation behaviour is evidenced from an
/// actual run, not inferred from a settled still. Compiled out of Release.
public enum QAPopLog: Sendable {
    public static var path: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: QAHostRouter.popLogFlag),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    public static func write(_ event: String) {
        guard let path else { return }
        let line = String(format: "%.4f %@\n", ProcessInfo.processInfo.systemUptime, event)
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif

/// Surfaces the DEBUG QA host can open programmatically (own process only).
/// Each routes to the SAME production controller/action — never a forked view.
public enum QASurface: String, Sendable, Equatable, CaseIterable {
    case settings
    case capture
    case coachmark
    case coachmarkFallback
    case guide
    case onboarding
    /// 0.3.13 cards pass: the compact targeted-repair card (design 7:385)
    /// through the SAME production policy + presenter.
    case repairCard
    /// DEBUG-only 2026-11-07 launch-repair routing fix: NOT an early-return
    /// surface — the REAL cold-launch routing runs with an ephemeral QA
    /// profile and the probe records which surfaces were created.
    case launchProbe
    /// DEBUG-only 2026-11-07 working-bar pass: the production voice pill
    /// (VoiceOverlayPillView) in a labelled fixture state, hosted offscreen
    /// for in-process PNG dumps — no real hold, no mic, no TCC.
    case voiceBar
}

/// DEBUG-only 0.3.13 cards pass: display-only delete-review fixture for
/// capture-panel screenshots. Pure published state — no lookup, no sink,
/// no coordinator; labelled in-frame, never a real event.
public enum QADeleteFixtureState: String, Sendable, Equatable {
    case confirm
    case chooser
}

/// DEBUG fixture states for the speech-model row. Clearly labelled fixtures —
/// never claimed as a real network download. Mock bytes only.
public enum QAModelsFixtureState: String, Sendable, Equatable, CaseIterable {
    case missing
    case downloading
    case error
    case ready
}

/// Pure factory for speech-only fixture snapshots. Never touches the network
/// or real weights.
public enum QAModelsFixture: Sendable {
    public static let fixtureLabel = "QA fixture — not a real download"

    public struct Snapshots: Sendable, Equatable {
        public var speech: ParakeetDownloadSnapshot
    }

    public static func snapshots(for state: QAModelsFixtureState) -> Snapshots {
        let speechExpected = ParakeetModelCatalog.expectedBytes
        let message = "\(fixtureLabel) · \(state.rawValue)"

        switch state {
        case .missing:
            let speech = ParakeetDownloadSnapshot(phase: .idle, bytesReceived: 0, bytesExpected: speechExpected, message: message)
            return Snapshots(speech: speech)

        case .downloading:
            let received = speechExpected / 4
            let speech = ParakeetDownloadSnapshot(phase: .downloading, bytesReceived: received, bytesExpected: speechExpected, message: message)
            return Snapshots(speech: speech)

        case .error:
            let speech = ParakeetDownloadSnapshot(
                phase: .failed, bytesReceived: speechExpected / 2, bytesExpected: speechExpected,
                message: message, lastError: "QA fixture — simulated transfer failure"
            )
            return Snapshots(speech: speech)

        case .ready:
            let speech = ParakeetDownloadSnapshot(phase: .ready, bytesReceived: speechExpected, bytesExpected: speechExpected, message: message)
            return Snapshots(speech: speech)
        }
    }
}
#endif
