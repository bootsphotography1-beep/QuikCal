import AppKit
import QuietCalendarCore

/// Passive modifier hold/release monitor. Does not log typed content.
/// Permissions are requested only when the user explicitly enables monitoring.
///
/// Event delivery (2026-11-07): three listener paths feed ONE pipeline —
/// the local NSEvent monitor (app key), the global NSEvent monitor
/// (standard modifiers) and the listen-only CGEventTap (the only path
/// that reliably sees the Fn/Globe key globally while the accessory app
/// is not frontmost). All three funnel through `handle(event:)` → the
/// pure `HoldToTalkEventInterpreter` → the shared `HoldToTalkEventPipeline`
/// (state machine + counters + callbacks) — the SAME pipeline the tests
/// drive with synthetic events. The state machine's phase guards make
/// double delivery count as one hold.
@MainActor
final class HoldToTalkMonitor: ObservableObject {
    /// Hardware keycode of the Fn / Globe key (kept for callers; the pure
    /// interpretation lives in `HoldToTalkEventInterpreter`).
    static let fnKeyCode: UInt16 = HoldToTalkFnKeyCode

    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var inputMonitoringAllowed = false
    /// OBSERVED event-monitor install state (0.3.13 follow-up): true only
    /// while at least one listener path (local/global NSEvent monitor or
    /// the listen-only CGEventTap) is actually installed. Published so
    /// surfaces can honestly separate "Accessibility is on" from "the
    /// shortcut listener is running" — the two were previously conflated
    /// into a single trust chip. An intent or pref never fakes this.
    @Published private(set) var listenerInstalled = false
    /// OBSERVED install state of the listen-only CGEventTap — the path
    /// that actually captures the Fn/Globe key globally (2026-11-07).
    /// The tap's event DELIVERY is gated by Input Monitoring
    /// (listen-event access); creation succeeding is NOT delivery proof
    /// (it can succeed untrusted), so the monitor gates Fn monitoring on
    /// the real `CGPreflightListenEventAccess()` probe.
    @Published private(set) var eventTapInstalled = false
    @Published var lastStatus: String?
    /// Honest diagnosis when Accessibility reads "not trusted" even though the
    /// user may see QuikCal listed in System Settings — typically a stale TCC
    /// entry pointing at an older copy (moved / re-signed app). Read-only
    /// diagnosis only; this never touches TCC and never fakes "enabled".
    @Published private(set) var accessibilityMismatchHint: String?
    /// Last practice transition for onboarding preview (no mic / no
    /// writes). Synced from the shared pipeline after every delivered
    /// event (the pipeline is the authority).
    @Published private(set) var practicePhase: HoldToTalkPhase = .idle

    // MARK: Pipeline forwards (the shared pipeline owns machine + counters
    // + callbacks; these keep the monitor's external shape unchanged).

    var machine: HoldToTalkStateMachine { pipeline.machine }
    /// ACTUAL detected hold cycles since launch — numbers only for the
    /// Copy shortcut diagnostics output; no key content ever recorded.
    var holdCycleCount: Int { pipeline.holdCycleCount }
    /// ACTUAL detected release cycles since launch.
    var releaseCycleCount: Int { pipeline.releaseCycleCount }
    /// Detected releases in onboarding practice preview — drives the
    /// honest "Released — nothing saved." status instead of the button
    /// press.
    var practiceReleaseCount: Int { pipeline.practiceReleaseCount }
    /// Timestamp of the last detected hold begin (diagnostics only).
    var lastHoldAt: Date? { pipeline.lastHoldAt }
    /// Timestamp of the last detected hold end (diagnostics only).
    var lastReleaseAt: Date? { pipeline.lastReleaseAt }

    /// Invoked ONLY on a monitor-detected practice release (not the Try-it
    /// button press). Onboarding marks its persisted "seen" here.
    var onPracticeRelease: (() -> Void)? {
        get { pipeline.onPracticeRelease }
        set { pipeline.onPracticeRelease = newValue }
    }

    var onBeginHold: (() -> Void)? {
        get { pipeline.onBeginHold }
        set { pipeline.onBeginHold = newValue }
    }

    var onEndHold: (() -> Void)? {
        get { pipeline.onEndHold }
        set { pipeline.onEndHold = newValue }
    }

    /// FAIL-SAFE cancel callback (2026-11-07): forwards the shared
    /// pipeline's cancel hook. Fired exactly once per cancelled hold,
    /// never from a release. The host (AppDelegate) terminates the
    /// recording with NO transcription/parse/submit.
    var onCancelHold: ((HoldToTalkCancelReason) -> Void)? {
        get { pipeline.onCancelHold }
        set { pipeline.onCancelHold = newValue }
    }

    /// When true, hold/release only updates practicePhase — no capture callbacks.
    var practicePreviewOnly: Bool {
        get { pipeline.practicePreviewOnly }
        set { pipeline.practicePreviewOnly = newValue }
    }

    /// Real monitor install state (observed presence of NSEvent monitors or
    /// the listen-only CGEventTap) — used for honest practice UI and
    /// shortcut diagnostics. An intent or pref never fakes this.
    var monitorsInstalled: Bool {
        localMonitor != nil || globalMonitor != nil || eventTap.isInstalled
    }

    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// Listen-only CGEventTap — the only path that reliably sees Fn/Globe
    /// flagsChanged globally while the accessory app is not frontmost.
    private let eventTap = HoldToTalkEventTap()
    /// The REAL production pipeline (shared with the tests).
    private var pipeline = HoldToTalkEventPipeline()
    /// Active-hold watchdog (fail-safe 2026-11-07): the bounded backstop
    /// for a lost release event. Probe = the same read-only
    /// `CGEventSource.flagsState` helper the mic-grant fail-safe uses;
    /// its only power is CANCELLATION via `cancelActiveHold`. The timer
    /// below runs ONLY while a hold is actually active.
    private lazy var watchdog: HoldToTalkHoldWatchdog = HoldToTalkHoldWatchdog(
        keyPhysicallyDown: { [weak self] in
            // Read-only live HID state; false when unconfirmable — the
            // safe direction for a STOP, never for a start.
            self?.shortcutKeyPhysicallyDown ?? false
        },
        onCancel: { [weak self] reason in
            self?.cancelActiveHold(reason: reason)
        }
    )
    /// Watchdog probe timer — created on hold-begin, invalidated on
    /// release/cancel/stop (predictable, bounded ownership).
    private var watchdogTimer: Timer?
    private let defaults: UserDefaults
    /// Read only from `deinit` (observer teardown) and MainActor methods;
    /// NSObjectProtocol tokens are not Sendable, hence the unsafe marker.
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pipeline.setShortcut(AppPreferencesStore(defaults: defaults).holdToTalkShortcut)
        refreshPermissionFlags()
        // Keep the trust flags honest across app switches (e.g. returning
        // from System Settings without the onboarding window open).
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshPermissionFlags()
                // 0.3.11: after the user grants Accessibility (returning from
                // System Settings), reattempt the persisted enabled intent.
                self.reattachIfEnabledIntent()
            }
        }
    }

    func setShortcut(_ kind: HoldToTalkShortcutKind) {
        AppPreferencesStore(defaults: defaults).holdToTalkShortcut = kind
        pipeline.setShortcut(kind)
    }

    isolated deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        // 2026-11-07 review (LOW) cleanup: both timers capture [weak self]
        // and would idle-fire as no-ops forever after dealloc. The monitor
        // is app-lifetime so this is theoretical, but invalidating here
        // closes the leak honestly. (Timer invalidate is idempotent; the
        // stop paths that already ran are unaffected.)
        trustPollTimer?.invalidate()
        watchdogTimer?.invalidate()
    }

    // MARK: Capability model (2026-11-07 privacy repair)
    //
    // The REAL macOS capability that gates global capture for the
    // CURRENT shortcut, and whether the live per-app probes say it is
    // granted. Fn/Globe is only seen globally by the listen-only
    // CGEventTap → Input Monitoring. Other modifiers are captured by
    // the global NSEvent monitor → Accessibility, OR by the tap →
    // Input Monitoring (either suffices). Never mislabel one as the
    // other; never gate on an arbitrary AX requirement when the actual
    // required capability is Input Monitoring.

    /// The capability that gates capture for the current shortcut.
    var requiredCapability: HoldToTalkCapability {
        HoldToTalkPermissionPolicy.requiredCapability(for: machine.shortcut)
    }

    /// The real per-app probes say the shortcut's capture capability is
    /// present (the ONLY authority for starting/rebinding monitoring).
    var requiredCapabilityGranted: Bool {
        HoldToTalkPermissionPolicy.mayStartMonitoring(
            shortcut: machine.shortcut,
            accessibilityTrusted: accessibilityTrusted,
            inputMonitoringAllowed: inputMonitoringAllowed
        )
    }

    func refreshPermissionFlags() {
        accessibilityTrusted = AXIsProcessTrusted()
        // Real listen-event-access probe for THIS process — the
        // capability that gates the Fn tap's event delivery.
        inputMonitoringAllowed = CGPreflightListenEventAccess()
        accessibilityMismatchHint = VoiceOverlayPolicy.accessibilityMismatchHint(
            trusted: accessibilityTrusted,
            bundlePath: Bundle.main.bundlePath
        )
        // FAIL-SAFE (2026-11-07): the shortcut's required capture
        // capability revoked mid-session is effective listener loss —
        // the system can disable the event tap at any time and a
        // mid-hold release can no longer be trusted to arrive. Stop
        // honestly (CANCELLING any active hold — never leaving a
        // click-through pill recording) instead of pretending to
        // listen. The status names the ACTUAL capability (Input
        // Monitoring for Fn, Accessibility/IM for modifiers) — never
        // mislabels one as the other.
        if machine.monitoringEnabled, !requiredCapabilityGranted {
            stopMonitoring(cancelReason: .permissionLost)
            lastStatus = HoldToTalkPermissionCopy.revokedStatus(for: machine.shortcut)
        }
    }

    /// User-triggered only — never silent grant. Prefers opening System Settings pane.
    func requestAccessibilityTrust() {
        let opened = openAccessibilitySettings()
        // Also offer the legacy prompt checkbox path as a secondary nudge.
        accessibilityTrusted = Self.promptAccessibilityTrust()
        refreshPermissionFlags()
        if accessibilityTrusted {
            lastStatus = "Accessibility access looks granted."
        } else if opened {
            lastStatus = "Opened Accessibility settings. Enable QuikCal, then return and Recheck."
        } else {
            lastStatus = HoldToTalkGuideCopy.manualFallback
        }
    }

    /// Tries known deep-link candidates; returns false if none opened (manual fallback).
    /// When a pane actually opens, posts `quikCalExternalSurfaceHandoff` so any
    /// FLOATING QuikCal surface (onboarding / repair card) yields its window
    /// level — System Settings must never be covered by our guide. Posting is
    /// UI coordination only; nothing is granted or edited here.
    @discardableResult
    func openAccessibilitySettings() -> Bool {
        openPrivacyPane(.accessibility)
    }

    /// Opens the Input Monitoring pane (the capability the Fn tap's
    /// delivery is gated on). Button-triggered only — never an
    /// automatic panel parade at launch.
    @discardableResult
    func openInputMonitoringSettings() -> Bool {
        openPrivacyPane(.inputMonitoring)
    }

    /// Opens the Microphone pane. The mic AUTHORIZATION itself is still
    /// requested only on a user hold/capture action via
    /// `AVCaptureDevice.requestAccess` — this only opens the pane.
    @discardableResult
    func openMicrophoneSettings() -> Bool {
        openPrivacyPane(.microphone)
    }

    /// Opens the Screen & System Audio Recording pane. ADVANCED /
    /// completeness only: no QuikCal feature records the screen or
    /// system audio, nothing is ever requested or gated on it.
    @discardableResult
    func openScreenRecordingSettings() -> Bool {
        openPrivacyPane(.screenRecording)
    }

    /// One pane-open path for every privacy pane: try the deep-link
    /// candidates in order; on the first that opens, yield any floating
    /// surface. Opening a pane grants nothing.
    private func openPrivacyPane(_ kind: PrivacyPaneKind) -> Bool {
        for candidate in kind.settingsURLCandidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                NotificationCenter.default.post(
                    name: .quikCalExternalSurfaceHandoff,
                    object: nil
                )
                return true
            }
        }
        return false
    }

    /// Check again, with the fresh result USED (0.3.13 follow-up): re-probes
    /// the live `AXIsProcessTrusted()` value and — when trust just became
    /// real and the user's persisted enabled intent stands — re-attaches the
    /// listener right away, so a grant made in System Settings takes effect
    /// WITHOUT an app restart. `reattachIfEnabledIntent` is guarded (explicit
    /// intent + not already installed), and `startMonitoringIfPermitted`
    /// removes any existing listeners (NSEvent monitors AND the event tap)
    /// before installing, so no duplicate event taps are possible. A stale
    /// saved untrusted state can never stick: every call ends with freshly
    /// probed flags.
    ///
    /// Review fix (2026-11-07): when monitoring is already running but the
    /// Fn event tap is missing (install failed, or bounded recovery was
    /// exhausted after system disables), the degraded status tells the user
    /// to "recheck and try again" — Check again now actually retries the
    /// tap (`repairFnTapIfMissing`). Explicit user action only; the bounded
    /// poll never calls this, so there is no retry loop.
    func checkAgainAndReattach() {
        refreshPermissionFlags()
        reattachIfEnabledIntent()
        repairFnTapIfMissing()
    }

    // MARK: Bounded trust poll (2026-11-07 owner correction)
    //
    // The app previously re-probed Accessibility ONLY on app activation
    // and explicit Check again. A menu-bar accessory app with a floating
    // onboarding window may never become "active" while the user toggles
    // the switch in System Settings and simply looks at the still-visible
    // floating window — so the grant was never noticed and holding Fn
    // did nothing even after granting. This poll is the genuine
    // permission-refresh/rebind path: while the Accessibility permission
    // step is VISIBLE, the UI starts a BOUNDED poll; every tick re-probes
    // the REAL `AXIsProcessTrusted()` value, and the moment trust becomes
    // real the persisted hold intent is re-attached and a missing Fn
    // event tap is repaired — the grant takes effect WITHOUT an app
    // restart, and nothing is ever faked from a pref.

    /// Bounded trust-poll timer — runs ONLY between
    /// `startBoundedTrustPoll()` and `stopBoundedTrustPoll()` (or the
    /// bound), never globally.
    private var trustPollTimer: Timer?
    /// When the current bounded poll window opened (nil = no poll).
    private var trustPollStartedAt: Date?

    /// Starts the bounded trust poll. Idempotent; safe to call when the
    /// permission step becomes visible. The poll self-stops when trust
    /// becomes real (after rebinding) or when the bounded window elapses.
    func startBoundedTrustPoll() {
        guard trustPollTimer == nil else { return }
        trustPollStartedAt = Date()
        let timer = Timer(timeInterval: AXPermissionStepPolicy.pollIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.trustPollTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPollTimer = timer
    }

    /// Stops the bounded trust poll (permission step no longer visible,
    /// or the caller re-arms it). Never cancels an active hold.
    func stopBoundedTrustPoll() {
        trustPollTimer?.invalidate()
        trustPollTimer = nil
        trustPollStartedAt = nil
    }

    /// One bounded poll tick: re-probe the REAL permission values; on the
    /// required-capability grant transition, rebind the persisted intent +
    /// repair a missing Fn event tap (the genuine grant-change recovery),
    /// then stop. Beyond the bound the poll stops itself (the honest
    /// timeout — the step UI explains Check again / restart).
    private func trustPollTick() {
        let started = trustPollStartedAt ?? Date()
        let wasGranted = requiredCapabilityGranted
        refreshPermissionFlags()
        if requiredCapabilityGranted {
            if !wasGranted {
                // Genuine grant-change recovery: rebind the listener set
                // (and the Fn event tap) right away — no restart needed
                // when the tap is (re)created after the grant.
                reattachIfEnabledIntent()
                repairFnTapIfMissing()
            }
            stopBoundedTrustPoll()
            return
        }
        if Date().timeIntervalSince(started) >= AXPermissionStepPolicy.maxWaitSeconds {
            stopBoundedTrustPoll()
        }
    }

    /// User-triggered only (Check again): if the Fn shortcut is active and
    /// monitoring is running but the listen-only event tap is NOT installed,
    /// reinstall the full listener set (stop-then-start removes old monitors
    /// and the old tap first — no duplicates). Never called from a timer.
    /// Gated on the shortcut's REQUIRED capability (Fn → Input Monitoring),
    /// never an arbitrary AX requirement.
    private func repairFnTapIfMissing() {
        guard AppPreferencesStore(defaults: defaults).holdToTalkEnabledExplicit == true else { return }
        guard machine.monitoringEnabled else { return } // reattachIfEnabledIntent covers the off case
        guard requiredCapabilityGranted else { return }
        guard HoldToTalkListenerPolicy.fnCaptureDegraded(
            shortcut: machine.shortcut,
            eventTapInstalled: eventTap.isInstalled
        ) else { return }
        startMonitoringIfPermitted()
    }

    private static func promptAccessibilityTrust() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// User-triggered only — never a silent or launch-time grant. Fires
    /// the SUPPORTED system request (`CGRequestListenEventAccess`,
    /// macOS 10.15+); the user still decides in the system UI. On a
    /// real grant this is genuine grant-change recovery: the persisted
    /// intent is re-bound and a missing Fn tap is (re)created right
    /// away — a tap created AFTER the grant delivers; if it still
    /// doesn't, the honest restart note applies. Never mislabels the
    /// Input Monitoring status as Accessibility.
    func requestInputMonitoring() {
        let granted = CGRequestListenEventAccess()
        inputMonitoringAllowed = granted || CGPreflightListenEventAccess()
        if inputMonitoringAllowed {
            reattachIfEnabledIntent()
            repairFnTapIfMissing()
            lastStatus = machine.shortcut == .fn
                ? "Input Monitoring granted — Fn hold-to-talk is permitted. " + HoldToTalkPermissionCopy.inputMonitoringRestartNote
                : "Input Monitoring granted — hold-to-talk is permitted (Accessibility also works)."
        } else {
            lastStatus = "Input Monitoring not granted. Open Input Monitoring settings, enable QuikCal, then Check again — typing still works."
        }
    }

    func startMonitoringIfPermitted() {
        refreshPermissionFlags()
        stopMonitoring()
        // Gate on the ACTUAL required capability for the current
        // shortcut (Fn → Input Monitoring; other modifiers →
        // Accessibility OR Input Monitoring) — never an arbitrary AX
        // requirement. A pref or an intent never fakes this.
        guard requiredCapabilityGranted else {
            pipeline.setMonitoringEnabled(false)
            lastStatus = HoldToTalkPermissionCopy.requiredNotGrantedStatus(for: machine.shortcut)
            return
        }
        pipeline.setMonitoringEnabled(true)
        pipeline.setShortcut(AppPreferencesStore(defaults: defaults).holdToTalkShortcut)
        pipeline.forceIdle()
        practicePhase = .idle

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(nsEvent: event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(nsEvent: event)
        }
        // The listen-only CGEventTap (2026-11-07): the path that actually
        // sees the Fn/Globe key globally while QuikCal is not frontmost.
        // Its event DELIVERY is gated by the Input Monitoring probe above
        // (creation can succeed untrusted and is never delivery proof).
        // The tap's callback lands on the main thread (main runloop
        // source) and feeds the SAME `handle(event:)` pipeline; the state
        // machine's phase guards make double delivery (tap + NSEvent
        // monitor) count as one hold — no duplicate callbacks.
        let tapInstalled = eventTap.install { [weak self] tapEvent in
            self?.handle(
                keyCode: tapEvent.keyCode,
                functionDown: tapEvent.functionDown,
                optionDown: tapEvent.optionDown,
                commandDown: tapEvent.commandDown,
                controlDown: tapEvent.controlDown
            )
        }
        // FAIL-SAFE (2026-11-07): learn when the tap becomes effectively
        // dead (bounded recovery exhausted) so published state stays
        // honest AND any in-flight hold is cancelled — the tap's death is
        // primary-listener loss for the Fn shortcut.
        eventTap.onEffectivelyDead = { [weak self] in
            self?.handleEventTapEffectivelyDead()
        }
        eventTapInstalled = tapInstalled
        // Observe ACTUAL install success — never claim "on" from intent alone.
        let localInstalled = localMonitor != nil
        let globalInstalled = globalMonitor != nil
        listenerInstalled = HoldToTalkListenerPolicy.listenerInstalled(
            local: localInstalled, global: globalInstalled, eventTap: tapInstalled
        )
        guard listenerInstalled else {
            pipeline.setMonitoringEnabled(false)
            lastStatus = "Hold-to-talk could not start (event monitors did not install). Typing still works — try again."
            return
        }
        // Fn-specific honesty: without the tap, Fn capture is degraded to
        // the (unreliable) NSEvent paths — say so instead of a plain "on".
        if HoldToTalkListenerPolicy.fnCaptureDegraded(shortcut: machine.shortcut, eventTapInstalled: tapInstalled) {
            lastStatus = practicePreviewOnly
                ? "Practice preview is limited — the Fn system tap did not install. Recheck Accessibility, then try again."
                : "Hold-to-talk is on, but the Fn system tap did not install — Fn may not register. Recheck Accessibility, then try again. Typing still works."
            return
        }
        lastStatus = practicePreviewOnly
            ? "Practice preview on (\(machine.shortcut.displayName)). Hold then release — nothing is written."
            : (machine.shortcut == .fn
                ? "Hold-to-talk monitoring on (Fn) — Input Monitoring verified; the first hold confirms delivery. Release stops recording, then parse → confirm."
                : "Hold-to-talk monitoring on (\(machine.shortcut.displayName)). The first hold confirms delivery. Release stops recording, then parse → confirm.")
    }

    // MARK: Launch persistence (0.3.11)

    /// Called once at app launch. Restores monitoring ONLY when the user's
    /// persisted intent is enabled AND the shortcut's REQUIRED capability
    /// is really granted right now (the live per-app probe — a pref never
    /// fakes it). Runs the one-time backward-compatible migration of the
    /// enabled intent. Otherwise stays off — honestly, and without
    /// touching anything.
    func restoreMonitoringAtLaunch() {
        let prefs = AppPreferencesStore(defaults: defaults)
        guard prefs.holdToTalkMonitoringEnabled else { return }
        refreshPermissionFlags()
        guard HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: prefs.holdToTalkEnabledExplicit,
            requiredCapabilityGranted: requiredCapabilityGranted,
            monitoringInstalled: machine.monitoringEnabled
        ) else {
            // Enabled intent but the required capability not granted yet:
            // stay off until the activation reattempt sees the REAL
            // grant. Never a fake "on".
            if prefs.holdToTalkEnabledExplicit == true, !requiredCapabilityGranted {
                lastStatus = "Hold-to-talk is enabled but waits for \(requiredCapability.displayName) access. Open its settings, enable QuikCal, then Check again."
            }
            return
        }
        startMonitoringIfPermitted()
    }

    /// Reattempt on app activation: only when the persisted intent is
    /// explicitly enabled (no migration side effects here), the
    /// shortcut's REQUIRED capability is REALLY granted now, and
    /// monitoring is not already installed.
    func reattachIfEnabledIntent() {
        guard AppPreferencesStore(defaults: defaults).holdToTalkEnabledExplicit == true else { return }
        guard !machine.monitoringEnabled else { return }
        guard requiredCapabilityGranted else { return }
        startMonitoringIfPermitted()
    }

    /// Explicit enable (onboarding / Settings): persist the intent, then
    /// attempt a real install. Status reflects the actual outcome.
    func enablePersistedMonitoring() {
        AppPreferencesStore(defaults: defaults).holdToTalkMonitoringEnabled = true
        startMonitoringIfPermitted()
    }

    /// Explicit disable (Settings): persist the choice and stop. The
    /// launch/activation restore respects this and never re-enables it.
    /// A hold active at disable is CANCELLED (fail-safe 2026-11-07) —
    /// recording terminated, nothing submitted.
    func disablePersistedMonitoring() {
        AppPreferencesStore(defaults: defaults).holdToTalkMonitoringEnabled = false
        stopMonitoring(cancelReason: .monitoringStopped)
        lastStatus = "Hold-to-talk is off. Enable it again anytime — typing still works."
    }

    /// The CURRENT physical modifier state of the configured shortcut, read
    /// straight from the HID event source — independent of any
    /// monitor-delivered events. Used as a fail-safe cross-check before a
    /// delayed mic grant may continue a hold: if the release event was
    /// swallowed while the system prompt had key focus, a stale "holding"
    /// phase can never auto-record, because the physical key is read live.
    /// Read-only (`CGEventSource.flagsState`) — no permission, no event
    /// injection, no TCC touch. When the read cannot confirm the key down,
    /// the answer is `false` (the safe direction: "hold again" instead of
    /// recording).
    var shortcutKeyPhysicallyDown: Bool {
        let flags = CGEventSource.flagsState(.hidSystemState)
        switch machine.shortcut {
        case .fn: return flags.contains(.maskSecondaryFn)
        case .option: return flags.contains(.maskAlternate)
        case .command: return flags.contains(.maskCommand)
        case .control: return flags.contains(.maskControl)
        }
    }

    /// Stops monitoring. FAIL-SAFE (2026-11-07): a hold active when the
    /// listener set goes away is CANCELLED first — the recording is
    /// terminated with NO transcription/submit, the held state and pill
    /// are cleared, and a stale `.holding` phase can never linger. The
    /// default reason is `.listenerLost` (the listener set is being
    /// removed/replaced); callers with a more specific cause pass it.
    func stopMonitoring(cancelReason: HoldToTalkCancelReason = .listenerLost) {
        cancelActiveHold(reason: cancelReason)
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
        eventTap.uninstall()
        eventTapInstalled = false
        pipeline.setMonitoringEnabled(false)
        listenerInstalled = false
        pipeline.forceIdle()
        practicePhase = .idle
    }

    // MARK: Hold cancellation fail-safe (2026-11-07)

    /// CANCELS an active hold through the shared pipeline — the fail-safe
    /// path DISTINCT from release: NO transcribe, NO parse, NO submit,
    /// ever. Idempotent (a no-op when no hold is active), fires
    /// `onCancelHold` exactly once per hold, closes the watchdog, and
    /// clears the held state so a fresh press cycle is required to record
    /// again (a late/stale release event or delayed mic grant can never
    /// continue or start a recording after this).
    func cancelActiveHold(reason: HoldToTalkCancelReason) {
        stopWatchdog()
        pipeline.cancelHold(reason: reason)
        practicePhase = pipeline.practicePhase
    }

    /// The Fn event tap became EFFECTIVELY DEAD (system disabled it and
    /// bounded recovery is exhausted). For the Fn shortcut the tap is the
    /// PRIMARY listener — its death mid-hold is effective listener loss
    /// EVEN IF the NSEvent monitors remain registered (global Fn delivery
    /// over NSEvent is unreliable, so a future release cannot be
    /// trusted): cancel the hold honestly. When not holding, only the
    /// published install state changes (honest down-state) plus the
    /// degraded status. Recovery stays explicit: Check again reinstalls
    /// the listener, but a still-held key never auto-restarts recording —
    /// a fresh valid press cycle is required.
    private func handleEventTapEffectivelyDead() {
        eventTapInstalled = false
        listenerInstalled = HoldToTalkListenerPolicy.listenerInstalled(
            local: localMonitor != nil,
            global: globalMonitor != nil,
            eventTap: false
        )
        if machine.shortcut == .fn, pipeline.machine.phase == .holding {
            cancelActiveHold(reason: .listenerLost)
            lastStatus = "Shortcut disconnected. Recording stopped. Use Check again, then hold the key again."
            return
        }
        guard machine.shortcut == .fn else { return }
        lastStatus = practicePreviewOnly
            ? "Practice preview is limited — the Fn system tap stopped. Recheck Accessibility, then try again."
            : "Hold-to-talk is on, but the Fn system tap stopped — Fn may not register. Recheck Accessibility, then try again. Typing still works."
    }

    // MARK: Active-hold watchdog (lost-release / cap backstop)

    /// Opens the watchdog window after the pipeline reports a real hold.
    /// The probe timer runs ONLY while a hold is actually active
    /// (capturing or practicing) — never globally, never idle.
    private func startWatchdogIfHolding() {
        guard pipeline.machine.phase == .holding else { return }
        watchdog.holdBegan()   // idempotent: double delivery is one hold
        guard watchdogTimer == nil else { return }
        let timer = Timer(timeInterval: HoldToTalkWatchdogPolicy.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.watchdogTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    /// One scheduled probe tick. A cancel decision closes the watchdog
    /// from inside `tick()`, so the timer is invalidated here —
    /// predictable ownership, closed on release/cancel/stop.
    private func watchdogTick() {
        watchdog.tick()
        if !watchdog.isActive {
            watchdogTimer?.invalidate()
            watchdogTimer = nil
        }
    }

    /// Closes the watchdog window (release, cancel, stop). Idempotent.
    private func stopWatchdog() {
        watchdog.holdEnded()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    /// ONE interpretation entry point for ALL listener paths (NSEvent
    /// monitors and the CGEventTap both reduce their event to keycode +
    /// modifier-flag booleans first). Pure interpretation (2026-11-07):
    /// Fn/Globe is matched by KEYCODE 63 + the `.function` flag — arrow
    /// keys and F-keys also carry the flag, so keycode gating is what
    /// keeps F1…F12 from looking like Fn holds. Other shortcuts keep
    /// flag-based matching. The decision then flows through the shared
    /// production pipeline (state machine → counters → callbacks) — the
    /// exact path the synthetic tests drive.
    private func handle(
        keyCode: UInt16,
        functionDown: Bool,
        optionDown: Bool,
        commandDown: Bool,
        controlDown: Bool
    ) {
        let decision = HoldToTalkEventInterpreter.decision(
            shortcut: machine.shortcut,
            keyCode: keyCode,
            functionDown: functionDown,
            optionDown: optionDown,
            commandDown: commandDown,
            controlDown: controlDown
        )
        pipeline.deliver(decision)
        practicePhase = pipeline.practicePhase
        // Watchdog sync (fail-safe 2026-11-07): the probe window is open
        // exactly while the pipeline reports an active hold — opened on a
        // real press, closed on a real release (or a cancel from any
        // fail-safe path, which also calls `stopWatchdog`).
        if pipeline.machine.phase == .holding {
            startWatchdogIfHolding()
        } else {
            stopWatchdog()
        }
    }

    /// NSEvent path: extract the same primitives the tap path delivers.
    private func handle(nsEvent: NSEvent) {
        handle(
            keyCode: nsEvent.keyCode,
            functionDown: nsEvent.modifierFlags.contains(.function),
            optionDown: nsEvent.modifierFlags.contains(.option),
            commandDown: nsEvent.modifierFlags.contains(.command),
            controlDown: nsEvent.modifierFlags.contains(.control)
        )
    }
}
