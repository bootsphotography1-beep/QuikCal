import Testing
import Foundation
@testable import QuietCalendarCore

/// FN-GLASS-TRANSITION FIX (2026-11-07): synthetic Fn/Globe flags through
/// the REAL production callback pipeline (`HoldToTalkEventInterpreter` →
/// `HoldToTalkEventPipeline` — the exact types the AppKit monitor drives)
/// into MOCKED mic/transcription/submit, plus the voice-bar glass policy
/// and the provider-switch motion policy. Pure tests — no TCC, no real
/// mic, no GUI, no event posting, no calendar access.
struct FnGlassTransitionFixTests {

    // MARK: - Helpers

    /// Synthetic Fn/Globe press (keycode 63, NX_SECONDARYFNMASK set).
    private func fnDown() -> HoldToTalkEventInterpreter.Decision {
        HoldToTalkEventInterpreter.decision(
            shortcut: .fn, keyCode: HoldToTalkFnKeyCode,
            functionDown: true, optionDown: false, commandDown: false, controlDown: false
        )
    }

    /// Synthetic Fn/Globe release (keycode 63, flag cleared).
    private func fnUp() -> HoldToTalkEventInterpreter.Decision {
        HoldToTalkEventInterpreter.decision(
            shortcut: .fn, keyCode: HoldToTalkFnKeyCode,
            functionDown: false, optionDown: false, commandDown: false, controlDown: false
        )
    }

    private func optionEvent(down: Bool) -> HoldToTalkEventInterpreter.Decision {
        HoldToTalkEventInterpreter.decision(
            shortcut: .option, keyCode: 58,
            functionDown: false, optionDown: down, commandDown: false, controlDown: false
        )
    }

    /// Mock capture chain the pipeline callbacks drive (mirrors the
    /// AppDelegate wiring contract: begin → gate → mic; end → stop →
    /// transcribe → submit). NEVER a real mic/transcription/calendar.
    private final class MockCaptureChain {
        var micStartCount = 0
        var micStopCount = 0
        var submitted: [String] = []
        var blockedReasons: [String] = []
        let modelReady: Bool
        let micGranted: Bool?

        init(modelReady: Bool = true, micGranted: Bool? = true) {
            self.modelReady = modelReady
            self.micGranted = micGranted
        }

        /// The REAL production gate decides; the mock only records.
        func begin() {
            switch VoiceOverlayPolicy.gate(modelReady: modelReady, micPermissionGranted: micGranted) {
            case .ready:
                micStartCount += 1
            case .blocked(let reason):
                blockedReasons.append(reason)
            }
        }

        func end() {
            guard micStartCount > micStopCount else { return }
            micStopCount += 1
            submitted.append("mock-transcript")
        }
    }

    private func makePipeline(
        shortcut: HoldToTalkShortcutKind = .fn,
        practice: Bool = false
    ) -> HoldToTalkEventPipeline {
        let pipeline = HoldToTalkEventPipeline(shortcut: shortcut)
        pipeline.setMonitoringEnabled(true)
        pipeline.practicePreviewOnly = practice
        return pipeline
    }

    // MARK: - Fn interpretation (keycode gate + flag normalization)

    @Test func fnKeycodeGateKeepsFKeysAndArrowsOutOfHolds() {
        // F1 (keycode 122) and arrows carry the SAME .function flag —
        // keycode gating is what keeps them from looking like Fn holds.
        for keyCode: UInt16 in [122, 120, 124, 125, 126] {
            let decision = HoldToTalkEventInterpreter.decision(
                shortcut: .fn, keyCode: keyCode,
                functionDown: true, optionDown: false, commandDown: false, controlDown: false
            )
            #expect(decision == .ignore, "keycode \(keyCode) must never look like Fn")
        }
        // The physical Fn key IS keycode 63.
        #expect(HoldToTalkFnKeyCode == 63)
        #expect(fnDown() == .press)
        #expect(fnUp() == .release)
    }

    @Test func fnReleaseDecisionCarriesNoFlag() {
        // Release = keycode 63 with the flag cleared.
        let decision = HoldToTalkEventInterpreter.decision(
            shortcut: .fn, keyCode: HoldToTalkFnKeyCode,
            functionDown: false, optionDown: true, commandDown: false, controlDown: false
        )
        #expect(decision == .release)
    }

    @Test func optionShortcutMatchesFlagsNotKeycode() {
        // Option shortcut: flag-based matching; a Fn-key event (keycode 63,
        // function flag) is a RELEASE decision for it (flag not down) —
        // and a no-op in the pipeline when not holding.
        #expect(optionEvent(down: true) == .press)
        #expect(optionEvent(down: false) == .release)
        let fnEventForOption = HoldToTalkEventInterpreter.decision(
            shortcut: .option, keyCode: HoldToTalkFnKeyCode,
            functionDown: true, optionDown: false, commandDown: false, controlDown: false
        )
        #expect(fnEventForOption == .release)
    }

    // MARK: - Real pipeline → mocked mic/transcription/submit

    @Test func fnPressReleaseDrivesMockCaptureChainExactlyOnce() {
        let pipeline = makePipeline()
        let chain = MockCaptureChain()
        pipeline.onBeginHold = { chain.begin() }
        pipeline.onEndHold = { chain.end() }

        pipeline.deliver(fnDown())
        pipeline.deliver(fnUp())

        #expect(chain.micStartCount == 1)
        #expect(chain.micStopCount == 1)
        #expect(chain.submitted == ["mock-transcript"])
        #expect(chain.blockedReasons.isEmpty)
        #expect(pipeline.holdCycleCount == 1)
        #expect(pipeline.releaseCycleCount == 1)
        #expect(pipeline.lastHoldAt != nil)
        #expect(pipeline.lastReleaseAt != nil)
        #expect(pipeline.machine.phase == .idle)
    }

    @Test func doubleDeliveryFromTapAndNSEventCountsAsOneHold() {
        // The same physical press delivered by BOTH the CGEventTap and an
        // NSEvent monitor must fire the capture chain ONCE.
        let pipeline = makePipeline()
        let chain = MockCaptureChain()
        pipeline.onBeginHold = { chain.begin() }
        pipeline.onEndHold = { chain.end() }

        pipeline.deliver(fnDown())
        pipeline.deliver(fnDown())   // duplicate delivery
        pipeline.deliver(fnUp())
        pipeline.deliver(fnUp())     // duplicate delivery

        #expect(chain.micStartCount == 1)
        #expect(chain.micStopCount == 1)
        #expect(chain.submitted.count == 1)
        #expect(pipeline.holdCycleCount == 1)
        #expect(pipeline.releaseCycleCount == 1)
    }

    @Test func autorepeatWhileHoldingNeverRestartsWithoutRelease() {
        let pipeline = makePipeline()
        let chain = MockCaptureChain()
        pipeline.onBeginHold = { chain.begin() }
        pipeline.onEndHold = { chain.end() }

        pipeline.deliver(fnDown())
        pipeline.deliver(fnDown())   // autorepeat-style duplicate press
        #expect(chain.micStartCount == 1)
    }

    @Test func releaseWithoutPressIsANoOp() {
        let pipeline = makePipeline()
        let chain = MockCaptureChain()
        pipeline.onBeginHold = { chain.begin() }
        pipeline.onEndHold = { chain.end() }

        pipeline.deliver(fnUp())
        #expect(chain.micStopCount == 0)
        #expect(chain.submitted.isEmpty)
        #expect(pipeline.releaseCycleCount == 0)
        #expect(pipeline.machine.phase == .idle)
    }

    @Test func ignoredEventsNeverReachThePipelineCallbacks() {
        let pipeline = makePipeline()
        let chain = MockCaptureChain()
        pipeline.onBeginHold = { chain.begin() }
        pipeline.onEndHold = { chain.end() }

        // F1 press (keycode 122, function flag set) — interpreted .ignore.
        let f1 = HoldToTalkEventInterpreter.decision(
            shortcut: .fn, keyCode: 122,
            functionDown: true, optionDown: false, commandDown: false, controlDown: false
        )
        pipeline.deliver(f1)
        #expect(chain.micStartCount == 0)
        #expect(pipeline.holdCycleCount == 0)
    }

    @Test func blockedGateShowsActionableReasonNotSilence() {
        // Fn DID arrive but mic is denied → the chain records the REAL
        // gate's actionable reason — never a silent nothing.
        let pipeline = makePipeline()
        let chain = MockCaptureChain(modelReady: true, micGranted: false)
        pipeline.onBeginHold = { chain.begin() }
        pipeline.onEndHold = { chain.end() }

        pipeline.deliver(fnDown())
        #expect(chain.micStartCount == 0)
        #expect(chain.blockedReasons.count == 1)
        #expect(chain.blockedReasons[0].contains("Microphone"))
        #expect(chain.blockedReasons[0].contains("System Settings"))
        // Model not ready → honest model reason too.
        let modelChain = MockCaptureChain(modelReady: false, micGranted: true)
        let gate = VoiceOverlayPolicy.gate(modelReady: false, micPermissionGranted: true)
        if case .blocked(let reason) = gate {
            modelChain.blockedReasons.append(reason)
        }
        #expect(modelChain.blockedReasons[0].contains("model"))
    }

    @Test func practicePreviewFiresPracticeReleaseNotCapture() {
        let pipeline = makePipeline(practice: true)
        let chain = MockCaptureChain()
        var practiceReleases = 0
        pipeline.onBeginHold = { chain.begin() }
        pipeline.onEndHold = { chain.end() }
        pipeline.onPracticeRelease = { practiceReleases += 1 }

        pipeline.deliver(fnDown())
        #expect(pipeline.practicePhase == .holding)
        pipeline.deliver(fnUp())
        #expect(pipeline.practicePhase == .idle)

        // Practice mode: NO capture callbacks, NO mic — only the honest
        // practice release signal.
        #expect(chain.micStartCount == 0)
        #expect(chain.submitted.isEmpty)
        #expect(practiceReleases == 1)
        #expect(pipeline.practiceReleaseCount == 1)
        #expect(pipeline.holdCycleCount == 1)
    }

    // MARK: - Tap recovery + listener honesty policies

    @Test func tapReenableIsBoundedAndThenHonest() {
        #expect(EventTapRecoveryPolicy.shouldReenable(disableCount: 0))
        #expect(EventTapRecoveryPolicy.shouldReenable(disableCount: 2))
        #expect(!EventTapRecoveryPolicy.shouldReenable(disableCount: 3))
        #expect(!EventTapRecoveryPolicy.shouldReenable(disableCount: 10))
    }

    @Test func listenerAggregationRequiresARealPath() {
        #expect(HoldToTalkListenerPolicy.listenerInstalled(local: false, global: false, eventTap: false) == false)
        #expect(HoldToTalkListenerPolicy.listenerInstalled(local: false, global: false, eventTap: true) == true)
        #expect(HoldToTalkListenerPolicy.listenerInstalled(local: true, global: false, eventTap: false) == true)
        #expect(HoldToTalkListenerPolicy.listenerInstalled(local: false, global: true, eventTap: false) == true)
    }

    @Test func fnWithoutTapIsFlaggedDegradedOtherShortcutsNot() {
        #expect(HoldToTalkListenerPolicy.fnCaptureDegraded(shortcut: .fn, eventTapInstalled: false))
        #expect(!HoldToTalkListenerPolicy.fnCaptureDegraded(shortcut: .fn, eventTapInstalled: true))
        #expect(!HoldToTalkListenerPolicy.fnCaptureDegraded(shortcut: .option, eventTapInstalled: false))
        #expect(!HoldToTalkListenerPolicy.fnCaptureDegraded(shortcut: .command, eventTapInstalled: false))
    }

    // MARK: - Diagnostics: tap line + press/release timestamps, no content

    @Test func diagnosticsCarryTapStateAndTimestampsButNoKeyContent() {
        let hold = Date(timeIntervalSince1970: 1_760_000_000)
        let release = Date(timeIntervalSince1970: 1_760_000_002)
        let facts = ShortcutDiagnosticsFacts(
            appVersion: "0.3.12",
            bundlePath: "/Applications/QuikCal.app",
            bundleID: "com.quietcalendar.app",
            codeSignature: "valid ad-hoc",
            accessibilityTrustedNow: true,
            inputMonitoringPreflight: false,
            listenerInstalled: true,
            eventTapInstalled: true,
            enabledIntent: true,
            monitoringIntentPersisted: true,
            selectedShortcut: "Fn",
            holdCount: 2,
            releaseCount: 2,
            practiceReleaseCount: 1,
            lastHoldAt: hold,
            lastReleaseAt: release,
            macOSVersion: "macOS 27.0"
        )
        let text = ShortcutDiagnosticsFormatter.render(facts)
        #expect(text.contains("fn_event_tap_installed: yes"))
        #expect(text.contains("listener_installed: yes"))
        #expect(text.contains("last_press_time: ") && !text.contains("last_press_time: none"))
        #expect(text.contains("last_release_time: ") && !text.contains("last_release_time: none"))
        // Numbers/timestamps only — no key content fields exist.
        #expect(!text.lowercased().contains("key_content"))
    }

    @Test func diagnosticsWithoutCyclesSayNone() {
        let facts = ShortcutDiagnosticsFacts(
            appVersion: "0.3.12",
            bundlePath: "/Applications/QuikCal.app",
            bundleID: "com.quietcalendar.app",
            codeSignature: "valid ad-hoc",
            accessibilityTrustedNow: false,
            listenerInstalled: false,
            eventTapInstalled: false,
            selectedShortcut: "Fn",
            holdCount: 0,
            releaseCount: 0,
            macOSVersion: "macOS 27.0"
        )
        let text = ShortcutDiagnosticsFormatter.render(facts)
        #expect(text.contains("fn_event_tap_installed: no"))
        #expect(text.contains("last_press_time: none"))
        #expect(text.contains("last_release_time: none"))
    }

    // MARK: - Voice-bar glass policy (one preview, background-only material)

    @Test func tintAlphaDecreasesWithGlassAndKeepsContrastFloor() {
        let zero = VoiceBarGlassPolicy.tintAlpha(intensity: 0)
        let half = VoiceBarGlassPolicy.tintAlpha(intensity: 0.5)
        let one = VoiceBarGlassPolicy.tintAlpha(intensity: 1)
        // More glass → LESS solid charcoal, monotonic.
        #expect(zero > half)
        #expect(half > one)
        // Endpoints are the pinned policy values.
        #expect(abs(zero - VoiceBarGlassPolicy.maxTintAlpha) < 0.001)
        #expect(abs(one - VoiceBarGlassPolicy.minTintAlpha) < 0.001)
        // Contrast floor: the tint never drops below the legibility bound.
        #expect(one >= 0.55)
        // Input clamped.
        #expect(VoiceBarGlassPolicy.tintAlpha(intensity: -3) == zero)
        #expect(VoiceBarGlassPolicy.tintAlpha(intensity: 4.2) == one)
    }

    @Test func contentIsNeverBlurredAtAnySetting() {
        #expect(VoiceBarGlassPolicy.contentBlurRadius == 0)
        #expect(VoiceBarGlassPolicy.tintAlpha(intensity: 0.0) >= 0)
        #expect(VoiceBarGlassPolicy.tintAlpha(intensity: 1.0) >= 0)
    }

    @Test func reduceTransparencyGetsOpaqueSurfaceNotFakeGlass() {
        #expect(VoiceBarGlassPolicy.reduceTransparencyTintAlpha >= 0.96)
        #expect(VoiceBarGlassPolicy.reduceTransparencyTintAlpha > VoiceBarGlassPolicy.maxTintAlpha)
    }

    @Test func nativeGlassOnlyOnMacOS26Plus() {
        #expect(VoiceBarGlassPolicy.usesNativeLiquidGlass(runtimeMajorVersion: 26))
        #expect(VoiceBarGlassPolicy.usesNativeLiquidGlass(runtimeMajorVersion: 27))
        #expect(!VoiceBarGlassPolicy.usesNativeLiquidGlass(runtimeMajorVersion: 14))
        #expect(!VoiceBarGlassPolicy.usesNativeLiquidGlass(runtimeMajorVersion: 15))
        // The preview stages the bar TOP-CENTER (like the real overlay).
        #expect(VoiceBarGlassPolicy.previewBarPlacementTopCenter)
    }

    // MARK: - Provider-switch motion (Mac calendars ↔ Google)

    @Test func switchDurationInsideApprovedBand() {
        let duration = ProviderSwitchMotionPolicy.duration(reduceMotion: false)
        #expect(duration != nil)
        #expect(ProviderSwitchMotionPolicy.durationInsideApprovedBand(duration!))
        // Band bounds honest: 180 ms and 250 ms are inside, outside is not.
        #expect(ProviderSwitchMotionPolicy.durationInsideApprovedBand(0.18))
        #expect(ProviderSwitchMotionPolicy.durationInsideApprovedBand(0.25))
        #expect(!ProviderSwitchMotionPolicy.durationInsideApprovedBand(0.17))
        #expect(!ProviderSwitchMotionPolicy.durationInsideApprovedBand(0.26))
    }

    @Test func reduceMotionSwitchesInstantlyNoTimerDelay() {
        // nil = instant state change — no animation, no Timer delaying
        // the business logic.
        #expect(ProviderSwitchMotionPolicy.duration(reduceMotion: true) == nil)
    }

    @Test func unselectedLaneIsInvisibleNonInteractiveAndHidden() {
        #expect(ProviderSwitchMotionPolicy.laneOpacity(isSelected: true) == 1)
        #expect(ProviderSwitchMotionPolicy.laneOpacity(isSelected: false) == 0)
        #expect(ProviderSwitchMotionPolicy.laneIsInteractive(isSelected: true))
        #expect(!ProviderSwitchMotionPolicy.laneIsInteractive(isSelected: false))
        #expect(ProviderSwitchMotionPolicy.laneIsAccessibilityVisible(isSelected: true))
        #expect(!ProviderSwitchMotionPolicy.laneIsAccessibilityVisible(isSelected: false))
    }

    @Test func exactlyOneLaneInteractivePreservesSingleLaneXOR() {
        #expect(ProviderSwitchMotionPolicy.exactlyOneLaneInteractive(eventKitSelected: true, googleSelected: false))
        #expect(ProviderSwitchMotionPolicy.exactlyOneLaneInteractive(eventKitSelected: false, googleSelected: true))
        #expect(!ProviderSwitchMotionPolicy.exactlyOneLaneInteractive(eventKitSelected: true, googleSelected: true))
        #expect(!ProviderSwitchMotionPolicy.exactlyOneLaneInteractive(eventKitSelected: false, googleSelected: false))
    }
}
