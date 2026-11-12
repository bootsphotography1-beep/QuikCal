import SwiftUI
import QuietCalendarCore

/// Floating capture UI — 0.3.21 Spotlight-style single capsule for capture;
/// expands into the separate full review surface for confirm / schedule.
struct CaptureContentView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var googleAuth: GoogleOAuthService
    @Binding var glassIntensity: Double
    var onOpenSettings: () -> Void
    var onOpenOnboarding: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var inputFocused: Bool

    /// 0.3.21 capsule measuring — the wrapped-input height is measured with
    /// a hidden replica at the field's exact width, so growth happens in
    /// discrete per-line steps (no jitter, no live word-driven width: the
    /// bar width is fixed by `CaptureBarSizingPolicy`).
    @State private var measuredSingleLineHeight: CGFloat = 0
    @State private var measuredInputHeight: CGFloat = 0

    /// Capture state renders as the single capsule (full-bleed glass); every
    /// other state keeps the padded review-card chrome.
    private var isNoteCapsule: Bool {
        vm.screen == .note && vm.holdOutcome != .nothingRecorded
    }

    /// 2026-11-12 voice/glass: in-place edit mode for the single-draft
    /// review ("Edit details" → the Edit event details surface; edits the
    /// SAME draft; Done returns to review — it never adds the event).
    @State private var voiceEditMode = false
    /// Transient just-saved receipt bar over the schedule surface (the
    /// approved ~1.6 s hold → 140 ms fade + Y 0 → −8 dismiss). Renders ONLY
    /// from confirmed persisted receipts.
    @State private var receiptHoldVisible = false

    #if DEBUG
    /// DEBUG-only: the note-screen QA fixtures are captured from the
    /// offscreen fixture window. Render the capsule at its intrinsic
    /// content height (the way the real panel always presents it) instead
    /// of stretching the capsule clip across the fixed fixture window.
    /// Never compiled into Release.
    private var qaTightNoteCapture: Bool {
        ProcessInfo.processInfo.arguments.contains("--qc-qa-note-state")
    }
    #else
    private var qaTightNoteCapture: Bool { false }
    #endif

    var body: some View {
        content
            .padding(isNoteCapsule ? 0 : 14)
            .frame(maxWidth: .infinity, maxHeight: qaTightNoteCapture ? nil : .infinity, alignment: .top)
            .background {
                if isNoteCapsule {
                    SpotlightCapsuleBackground(intensity: effectiveGlass)
                } else {
                    GlassBackground(intensity: effectiveGlass)
                }
            }
            .clipShape(
                isNoteCapsule
                    ? AnyShape(Capsule())
                    : AnyShape(RoundedRectangle(cornerRadius: QuietDesign.Voice.Metric.cardCorner, style: .continuous))
            )
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: vm.presentationPhase)
            .onChange(of: vm.presentationPhase) { _, phase in
                vm.onRequestPanelResize?(phase)
            }
            .onChange(of: vm.captureFocusNonce) { _, _ in
                guard vm.screen == .note else { return }
                inputFocused = true
            }
            .onAppear {
                applyQADisplayOverridesIfRequested()
                if vm.screen == .note {
                    inputFocused = true
                }
                requestBarHeight()
            }
            .onChange(of: measuredSingleLineHeight) { _, _ in requestBarHeight() }
            .onChange(of: measuredInputHeight) { _, _ in requestBarHeight() }
            .onChange(of: statusSignature) { _, _ in requestBarHeight() }
            .onChange(of: vm.holdOutcome) { _, _ in requestBarHeight() }
    }

    private var effectiveGlass: Double {
        // Reduce Transparency handled inside GlassBackground; intensity still stored.
        glassIntensity
    }

    #if DEBUG
    /// DEBUG-only QA fixture flags (2026-11-12): let the isolated QA host
    /// render specific approved-design fixtures in the capture panel for
    /// screenshots. Never compiled into Release; the fixtures fail closed
    /// (no sink, no write) exactly like the existing QA fixtures, and the
    /// in-frame orange label renders for each.
    private var qaReceiptPreviewOnly: Bool {
        ProcessInfo.processInfo.arguments.contains("--qc-qa-receipt-preview")
    }

    private func applyQADisplayOverridesIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--qc-qa-edit-mode") { voiceEditMode = true }
        if args.contains("--qc-qa-clarify") {
            vm.clarification = "Morning or evening?"
            vm.ampmCandidates = ["7:00 AM", "7:00 PM"]
            vm.qaDeleteFixtureActive = true
        }
        if args.contains("--qc-qa-empty") {
            vm.holdOutcome = .nothingRecorded
            vm.statusMessage = nil
            vm.qaDeleteFixtureActive = true
        }
        if args.contains("--qc-qa-saving-state") {
            vm.isSaving = true
            vm.qaDeleteFixtureActive = true
        }
        if args.contains("--qc-qa-failed-state") {
            vm.qaForceSaveFailureForFixture()
            vm.qaDeleteFixtureActive = true
        }
        if args.contains("--qc-qa-receipt-preview") {
            vm.qaDeleteFixtureActive = true
        }
    }
    #else
    private var qaReceiptPreviewOnly: Bool { false }
    private func applyQADisplayOverridesIfRequested() {}
    #endif

    /// Calendar name for the saving/receipt surfaces WITHOUT the account
    /// email — only the calendar title the user sees in their provider.
    private var saveTargetCalendarName: String {
        switch vm.prefs.calendarDestinationKind {
        case .eventKit:
            return vm.selectedCalendarTitle
        case .google:
            return googleAuth.activeAccount?.targetCalendarSummary ?? "Google Calendar"
        }
    }

    /// Signature of the confirmed receipts currently on screen (drives the
    /// just-saved receipt hold exactly once per save generation).
    private var savedReceiptSignature: String {
        vm.savedReceipts.map(\.eventID).joined(separator: "|")
    }

    private func shortReceiptDetail(_ receipt: SavedEventReceipt) -> String {
        ConfirmationReviewFormat.dateTimeLine(start: receipt.start, end: receipt.end)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.screen {
        case .onboarding:
            // Inline fallback if panel opened before dedicated window.
            VStack(alignment: .leading, spacing: 10) {
                Text("Finish setup to continue.")
                    .font(.system(.body, design: .default))
                Button("Open onboarding") { onOpenOnboarding() }
                    .buttonStyle(.borderedProminent)
            }
        case .note:
            noteCapsule
        case .confirm:
            confirmBlock
        case .deleteReview:
            deleteBlock
        case .schedule:
            scheduleBlock
        }
    }

    // MARK: Note / listening / parsing — the 0.3.21 Spotlight capsule
    //
    // ONE compact horizontally elongated capsule (fixed width, ~64 pt tall
    // single-line): leading calendar icon (waveform while recording), a
    // LARGE readable input with the "Add to your calendar…" placeholder,
    // and minimal trailing controls (dictate, submit, settings) integrated
    // in the same row — no bulky second row, no exposed account email.
    // A concise status line (clarification / error / speech message /
    // destination hint) appears inside the capsule only when needed, and
    // the capsule grows DOWNWARD (top edge anchored) for wrapped input,
    // bounded by the available screen; beyond the bound the input field
    // scrolls internally. All transcript/editor text is preserved.

    /// Large readable system-SF input font (Spotlight-like).
    private var inputFont: Font { .system(size: 20, weight: .regular, design: .default) }

    private var extraInputLines: Int {
        CaptureBarSizingPolicy.lineCount(
            measuredInputHeight: measuredInputHeight,
            measuredSingleLineHeight: measuredSingleLineHeight
        )
    }

    private var requestedBarHeight: CGFloat {
        CaptureBarSizingPolicy.barHeight(
            inputLineCount: extraInputLines,
            hasStatusStrip: statusLine != nil,
            hasChipRow: showsAMPMChips
        )
    }

    /// Final capsule height, clamped to the available screen height so
    /// growth never leaves the display.
    private var effectiveBarHeight: CGFloat {
        if vm.screen == .note && vm.holdOutcome == .nothingRecorded {
            // The approved empty state needs room for its two explicit
            // actions — never a clipped capsule.
            return CaptureBarSizingPolicy.clampedHeight(
                requested: 148,
                availableHeight: vm.barAvailableHeight
            )
        }
        return CaptureBarSizingPolicy.clampedHeight(
            requested: requestedBarHeight,
            availableHeight: vm.barAvailableHeight
        )
    }

    private var inputRowHeight: CGFloat {
        max(
            CaptureBarSizingPolicy.capsuleHeight,
            effectiveBarHeight
                - (statusLine != nil ? CaptureBarSizingPolicy.statusStripHeight : 0)
                - (showsAMPMChips ? CaptureBarSizingPolicy.chipStripHeight : 0)
        )
    }

    /// Meridiem-ambiguous clock chips (0.3.22): shown on the note screen
    /// only while an am/pm clarification is asking.
    private var showsAMPMChips: Bool {
        !vm.ampmCandidates.isEmpty && vm.clarification != nil
    }

    private func requestBarHeight() {
        vm.onRequestBarHeight?(effectiveBarHeight.rounded())
    }

    private var noteCapsule: some View {
        VStack(spacing: 0) {
            #if DEBUG
            qaFixtureLabel
                .padding(.horizontal, 16)
                .padding(.top, 12)
            #endif
            if vm.holdOutcome == .nothingRecorded {
                // Approved "empty / no speech" state — an empty or very
                // short hold never produces a draft. Honest retry paths:
                // hold again, or type instead. Explicit actions only.
                emptyCaptureCard
            } else {
                inputRow
                    .frame(height: inputRowHeight)
                if let status = statusLine {
                    statusStrip(status)
                }
                if showsAMPMChips {
                    ampmChipStrip
                }
            }
            Spacer(minLength: 0)
                .frame(maxHeight: qaTightNoteCapture ? 0 : .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: qaTightNoteCapture ? nil : .infinity, alignment: .top)
    }

    /// The approved empty state: "I didn't catch that." — an explicit
    /// recovery choice (hold again, or type). Renders only after a hold
    /// produced NOTHING (`HoldOutcome.nothingRecorded`) — never as a
    /// stand-in for a draft or a parse result.
    private var emptyCaptureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(QuietDesign.Voice.VoiceColor.micLiveTint(colorScheme))
                        .frame(width: QuietDesign.Voice.Metric.micCircle,
                               height: QuietDesign.Voice.Metric.micCircle)
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(QuietDesign.Voice.VoiceColor.micLiveGlyph(colorScheme))
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("I didn't catch that.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                    Text(HoldOutcomeCopy.nothingRecordedRetryCopy)
                        .font(.system(size: 11))
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Dismiss") {
                    vm.holdOutcome = nil
                    vm.statusMessage = nil
                }
                .buttonStyle(QuietSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button("Type instead") {
                    vm.holdOutcome = nil
                    vm.statusMessage = nil
                    inputFocused = true
                }
                .buttonStyle(QuietPrimaryButtonStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// Real am/pm candidates from the resolver, rendered as chips under the
    /// clarification. Tapping one re-parses the SAME note with the chosen
    /// meridiem — nothing is written until the user confirms the draft.
    private var ampmChipStrip: some View {
        HStack(spacing: 8) {
            ForEach(vm.ampmCandidates, id: \.self) { candidate in
                if candidate.lowercased().hasSuffix("pm") {
                    Button(candidate) { vm.resolveClarificationAMPM(isPM: true) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button(candidate) { vm.resolveClarificationAMPM(isPM: false) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 44)
        .frame(height: CaptureBarSizingPolicy.chipStripHeight)
        .disabled(vm.isParsing || vm.isSaving)
        .accessibilityLabel("Start time choices")
    }

    private var inputRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: vm.speech.state == .recording ? "waveform" : "calendar")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(vm.speech.state == .recording ? Color.red : QuietPalette.accent)
                .accessibilityHidden(true)

            inputField

            if vm.isParsing {
                ProgressView().controlSize(.small)
            }

            trailingControls
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputField: some View {
        TextField("Add to your calendar…", text: $vm.inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(inputFont)
            .lineLimit(CaptureBarSizingPolicy.inputLineLimit)
            .focused($inputFocused)
            .onChange(of: vm.inputText) { _, _ in vm.inputChanged() }
            .disabled(vm.isParsing || vm.isSaving)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) { inputMeasurer }
            .accessibilityLabel("Event note")
    }

    /// Hidden measuring replica at the field's exact width: drives the
    /// discrete per-line downward growth (never the bar width).
    private var inputMeasurer: some View {
        ZStack(alignment: .leading) {
            Text("Add to your calendar…")
                .font(inputFont)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { measuredSingleLineHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, h in measuredSingleLineHeight = h }
                    }
                )
            Text(vm.inputText.isEmpty ? "Add to your calendar…" : vm.inputText)
                .font(inputFont)
                .lineLimit(CaptureBarSizingPolicy.inputLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { measuredInputHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, h in measuredInputHeight = h }
                    }
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Minimal trailing controls, integrated in the input row — compact,
    /// discoverable, accessibility-labelled, subtle hover feedback.
    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: 8) {
            CapsuleIconControl(
                systemImage: micSymbol,
                label: vm.speech.state == .recording || vm.speech.state == .finishing
                    ? "Stop dictation" : "Dictate",
                help: "Local Parakeet — mic → confirm → Add",
                tint: vm.speech.state == .recording ? .red : .secondary
            ) {
                vm.speech.toggle()
            }
            .disabled(vm.isParsing || vm.isSaving)

            CapsuleIconControl(
                systemImage: "arrow.right.circle.fill",
                label: "Add to calendar",
                help: "Review what QuikCal understood before anything is saved",
                tint: vm.canParseNote ? QuietPalette.primaryFill : .secondary
            ) {
                vm.submitNote()
            }
            .disabled(!vm.canParseNote)

            CapsuleIconControl(
                systemImage: "gearshape",
                label: "Settings",
                help: "Open Settings (the capture bar hides and your text is kept)",
                tint: .secondary
            ) {
                onOpenSettings()
            }
        }
    }

    /// Concise in-capsule status line — only when there is something to say.
    /// Provider info stays a subtle hint (never an account-email row): it
    /// appears solely when the destination is not ready to save.
    private var statusLine: (text: String, color: Color)? {
        if let clarification = vm.clarification {
            return (clarification, .orange)
        }
        if let status = vm.statusMessage {
            return (status, .red)
        }
        if let speechMessage = vm.speech.message {
            return (speechMessage, .secondary)
        }
        if let hint = destinationHint {
            return (hint, .secondary)
        }
        return nil
    }

    private var statusSignature: String {
        statusLine?.text ?? ""
    }

    private var destinationHint: String? {
        switch vm.prefs.calendarDestinationKind {
        case .eventKit:
            if vm.selectionState.needsAttention {
                return "Pick a calendar in Settings to save events."
            }
            return nil
        case .google:
            if googleAuth.activeAccount == nil {
                return "Google Calendar — sign in in Settings."
            }
            if googleAuth.activeAccount?.targetCalendarID == nil {
                return "Choose a Google calendar in Settings."
            }
            return nil
        }
    }

    private func statusStrip(_ status: (text: String, color: Color)) -> some View {
        Text(status.text)
            .font(.system(size: 11.5))
            .foregroundStyle(status.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(height: CaptureBarSizingPolicy.statusStripHeight, alignment: .top)
            .padding(.top, 1)
            .accessibilityLabel("Status")
            .accessibilityValue(status.text)
    }

    private var micSymbol: String {
        switch vm.speech.state {
        case .recording, .finishing: return "stop.circle.fill"
        case .requesting: return "mic.badge.ellipsis"
        case .idle: return "mic"
        }
    }

    // MARK: Confirm — the approved 2026-11-12 voice/glass review surface
    //
    // ONE readable review card: header row (sage calendar tile + the plain
    // question) + X close (non-mutating, same as Cancel), the event title,
    // full date/time, location, reminder rows, a compact destination pill,
    // "Edit details" (in-place edit of the SAME draft), a divider, and the
    // pinned footer: Cancel · "Nothing added yet" · "Add event".
    // Saving swaps the whole card for the compact glass saving bar; only a
    // CONFIRMED persisted write produces receipts (rendered on the schedule
    // surface + the transient receipt bar — never a pre-save preview).

    /// Destination for the review pill + saving/receipt bars — the calendar
    /// title only, never the account email.
    private var destinationLabel: String {
        switch vm.prefs.calendarDestinationKind {
        case .eventKit:
            return vm.selectedCalendarTitle
        case .google:
            if let summary = googleAuth.activeAccount?.targetCalendarSummary, !summary.isEmpty {
                return "\(summary) · Google Calendar"
            }
            return "Google Calendar"
        }
    }

    private var confirmBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            qaFixtureLabel
            if qaReceiptPreviewOnly {
                #if DEBUG
                // Synthetic QA receipt preview — no write occurred.
                VStack(spacing: 12) {
                    Spacer(minLength: 8)
                    VoiceReceiptBar(
                        calendarName: "Personal",
                        title: "Lunch with Alex",
                        detail: "Tomorrow · 12:00–1:00 PM"
                    )
                    .frame(maxWidth: 400)
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity)
                #endif
            } else if vm.isSaving {
                savingStage
            } else if voiceEditMode {
                editingStage
            } else {
                reviewStage
            }
        }
        #if DEBUG
        .accessibilityElement(children: .contain)
        #endif
    }

    /// Shared orange QA-fixture label — display-only states, never a real
    /// capture/write. Compiled out of Release.
    @ViewBuilder
    private var qaFixtureLabel: some View {
        #if DEBUG
        if vm.qaDeleteFixtureActive {
            Text("QA fixture — display-only state")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
        }
        #endif
    }

    // MARK: - Saving stage (compact glass bar; the review card is replaced)

    private var savingStage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 26)
            VoiceSavingBar(destination: saveTargetCalendarName)
            Spacer(minLength: 26)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Review stage (the approved review card)

    private var reviewStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            singleReviewHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if vm.confirmationDrafts.isEmpty {
                        // Single-event review: the full readable card.
                        singleReviewCard
                    } else {
                        // Multi-event batch: the per-draft list only —
                        // never a fake single-event merge.
                        multiDraftList
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            reviewDestinationRow
            if let status = vm.statusMessage {
                reviewStatusRow(status)
            } else if let googleBlock = vm.googleAddBlockMessage {
                Text(googleBlock)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let hint = destinationHint {
                // Destination isn't ready — say exactly why in the same
                // honest voice as the note bar (never a silent disabled Add).
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            reviewFooter
        }
    }

    private var singleReviewHeader: some View {
        HStack(spacing: 10) {
            QuietIconTile(systemImage: "calendar", side: 28)
            Text(ConfirmationReviewFormat.title(draftCount: vm.confirmationDrafts.isEmpty ? 1 : vm.confirmationDrafts.count))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
            Spacer(minLength: 8)
            closeButton(action: { vm.rejectConfirmationDrafts() }, enabled: noButtonEnabled, label: "Dismiss review without adding")
        }
    }

    /// Round X close — the same NON-MUTATING action as Cancel/Escape
    /// (rejected draft generation; never a calendar write).
    private func closeButton(action: @escaping () -> Void, enabled: Bool, label: String) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                .frame(width: 26, height: 26)
                .background(Circle().fill(QuietDesign.Voice.VoiceColor.closeButtonFill(colorScheme)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(label)
    }

    /// Destination pill + Edit details — one row, per the approved design.
    /// The pill names the calendar title only (never the account email);
    /// tapping it opens Settings to change the destination explicitly.
    private var reviewDestinationRow: some View {
        HStack(spacing: 12) {
            Button { onOpenSettings() } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(QuietPalette.accent)
                        .frame(width: 8, height: 8)
                    Text(destinationLabel)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.055)))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Change the destination calendar in Settings")
            .accessibilityLabel("Destination calendar")
            .accessibilityValue(destinationLabel)

            Spacer(minLength: 8)

            if vm.confirmationDrafts.isEmpty {
                Button("Edit details") {
                    voiceEditMode = true
                }
                .buttonStyle(QuietTextButtonStyle())
                .accessibilityLabel("Edit event details")
            }
        }
    }

    /// Honest status row: failure renders in the failure red with a warning
    /// glyph; any other status stays a quieter caution line.
    private func reviewStatusRow(_ status: String) -> some View {
        Group {
            if vm.lastSaveFailed {
                Label(status, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(QuietDesign.Voice.VoiceColor.failureRed)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Pinned footer: Cancel · the honest "Nothing added yet" · Add event.
    private var reviewFooter: some View {
        HStack(spacing: 12) {
            Button("Cancel") { vm.rejectConfirmationDrafts() }
                .buttonStyle(QuietSecondaryButtonStyle())
                .disabled(!noButtonEnabled)
                .help("Nothing is added — keep the text to edit or speak again")
            Spacer(minLength: 8)
            if vm.savedReceipts.isEmpty && !vm.isSaving {
                Text("Nothing added yet")
                    .font(.system(size: 11))
                    .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
            }
            if vm.isSaving {
                ProgressView().controlSize(.small)
            } else {
                Button(addButtonTitle) {
                    if vm.confirmationDrafts.isEmpty {
                        vm.addConfirmedEvent()
                    } else {
                        vm.addAllConfirmationDrafts()
                    }
                }
                .buttonStyle(QuietPrimaryButtonStyle())
                .disabled(addButtonDisabled)
                .help(vm.googleAddBlockMessage ?? "Add to the selected calendar")
            }
        }
    }

    // MARK: - Editing stage (the approved "Edit event details" card)

    private var editingStage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                QuietIconTile(systemImage: "pencil", side: 28)
                Text("Edit event details")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                Spacer(minLength: 8)
                closeButton(action: { voiceEditMode = false }, enabled: true, label: "Finish editing, back to review")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    editField(label: "TITLE") {
                        TextField("Title", text: $vm.draftTitle)
                            .textFieldStyle(VoiceFieldStyle())
                    }
                    HStack(alignment: .top, spacing: 8) {
                        editField(label: "DATE") {
                            DatePicker("", selection: $vm.draftStart, displayedComponents: [.date])
                                .labelsHidden()
                        }
                        editField(label: "STARTS") {
                            DatePicker("", selection: $vm.draftStart, displayedComponents: [.hourAndMinute])
                                .labelsHidden()
                        }
                        editField(label: "ENDS") {
                            DatePicker("", selection: $vm.draftEnd, displayedComponents: [.hourAndMinute])
                                .labelsHidden()
                        }
                    }
                    editField(label: "LOCATION") {
                        TextField("Location", text: $vm.draftLocation)
                            .textFieldStyle(VoiceFieldStyle())
                    }
                    HStack(alignment: .top, spacing: 8) {
                        editField(label: "REMINDER") {
                            ReminderPresetMenu(leadMinutes: vm.draftReminderLeadMinutes) { lead in
                                vm.setDraftReminderLeadMinutes(lead)
                            }
                        }
                        editField(label: "CALENDAR") {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(QuietPalette.accent)
                                    .frame(width: 8, height: 8)
                                Text(destinationLabel)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Button("Change…") { onOpenSettings() }
                                    .buttonStyle(QuietTextButtonStyle())
                                    .accessibilityLabel("Change destination calendar in Settings")
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(QuietDesign.Voice.VoiceColor.fieldFill(colorScheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(QuietDesign.Voice.VoiceColor.cardStroke(colorScheme), lineWidth: 1)
                            )
                        }
                    }
                    editField(label: "NOTES") {
                        TextField("Add a note…", text: $vm.draftNotes, axis: .vertical)
                            .textFieldStyle(VoiceFieldStyle())
                            .lineLimit(2...4)
                    }
                    if vm.draftEnd <= vm.draftStart {
                        Text("End must be after start.")
                            .font(.caption)
                            .foregroundStyle(QuietDesign.Voice.VoiceColor.failureRed)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Cancel") { voiceEditMode = false }
                    .buttonStyle(QuietSecondaryButtonStyle())
                    .help("Back to review — the draft is kept, nothing is added")
                Spacer(minLength: 8)
                Button("Done") { voiceEditMode = false }
                    .buttonStyle(QuietPrimaryButtonStyle())
                    .help("Back to review — Done does not add the event")
            }
        }
    }

    /// One labelled field row: small-caps caption above the control.
    private func editField<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3, content: {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
            content()
        })
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Multi-draft confirmation list (unchanged behavior; restyled chrome).
    private var multiDraftList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !vm.confirmationTranscript.isEmpty {
                DisclosureGroup("Original note") {
                    Text(vm.confirmationTranscript).font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .font(.system(size: 12.5, weight: .medium))
            }
            if let note = vm.confirmationNote ?? vm.parseNote {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(vm.confirmationDrafts, id: \.id) { draft in
                    draftRow(draft)
                }
            }
        }
    }

    /// Readable single-event review card: prominent title, description,
    /// human date/time, location, reminder, and the destination calendar —
    /// the actual content the user is confirming (material follows the
    /// system light/dark appearance; no parser provenance in the primary
    /// UI). 0.3.17: the title and description wrap COMPLETELY (no 2-line
    /// cutoff — the owner must be able to review the full event); long
    /// content scrolls in the surrounding scroll view instead of being
    /// cut off.
    private var singleReviewCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(vm.draftTitle.isEmpty ? "Untitled event" : vm.draftTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            // Full date/time with a sage calendar glyph (the approved
            // review rows).
            Label {
                Text(ConfirmationReviewFormat.dateTimeLine(start: vm.draftStart, end: vm.draftEnd))
                    .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
            } icon: {
                Image(systemName: "calendar")
                    .foregroundStyle(QuietPalette.accent)
            }
            .font(.system(size: 12.5, weight: .medium))
            .monospacedDigit()
            if let location = vm.draftLocation.trimmingCharacters(in: .whitespaces) as String?, !location.isEmpty {
                Label {
                    Text(location)
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                } icon: {
                    Image(systemName: "mappin")
                        .foregroundStyle(QuietPalette.accent)
                }
                .font(.system(size: 12.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            }
            // Description (0.3.17): the user's extra detail as parsed —
            // shown in full before save, editable under Edit details.
            if let notes = vm.draftNotes.trimmingCharacters(in: .whitespacesAndNewlines) as String?, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 12.5))
                    .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
            // Reminder info: shown when one was parsed or set — editable
            // via the preset menu under Edit details.
            if let lead = vm.draftReminderLeadMinutes {
                Label {
                    Text(ReminderLeadFormat.phrase(minutes: lead))
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                } icon: {
                    Image(systemName: "bell")
                        .foregroundStyle(QuietPalette.accent)
                }
                .font(.system(size: 12.5, weight: .medium))
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Review: \(vm.draftTitle), \(ConfirmationReviewFormat.dateTimeLine(start: vm.draftStart, end: vm.draftEnd)), calendar \(destinationLabel)")
    }

    /// No is refused while a write is in flight or already committed —
    /// never a pretend cancel of an executed calendar write.
    private var noButtonEnabled: Bool {
        ConfirmationRejectionPolicy.mayReject(
            isSaving: vm.isSaving,
            anyDraftCommitted: vm.confirmationDrafts.contains { $0.savedEventID != nil }
        )
    }

    private var addButtonTitle: String {
        if !vm.confirmationDrafts.isEmpty {
            let pending = vm.confirmationDrafts.filter { $0.savedEventID == nil }.count
            return ConfirmationRejectionPolicy.yesLabel(pendingCount: pending)
        }
        if vm.lastSaveFailed { return "Try again" }
        if vm.duplicateAddArmed { return "Add a copy" }
        return "Add event"
    }

    private var addButtonDisabled: Bool {
        if !vm.confirmationDrafts.isEmpty {
            let addable = vm.confirmationDrafts.filter { $0.canAdd || $0.duplicateAddArmed }.count
            // Google parity: the batch Add obeys the same live destination
            // readiness as the single Add (nil message = ready/EventKit).
            return vm.isSaving || addable == 0 || vm.googleAddBlockMessage != nil
        }
        return !vm.canAddDraft
    }

    /// Per-draft state for the edit disclosure (one per row identity).
    @State private var expandedDraftIDs: Set<UUID> = []

    /// Brief readable summary card per draft: title, human date/time,
    /// location, phrase — with the draft's blocking issues, AM/PM chips,
    /// overlap warnings and defaults all EXPLICIT (safety is never hidden
    /// behind the disclosure). Edit fields live under the per-draft
    /// disclosure. Parser provenance is NOT shown (source info lives in
    /// Settings/diagnostics, not the calendar confirmation).
    private func draftRow(_ draft: ConfirmationDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.title.isEmpty ? "Untitled event" : draft.title)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ConfirmationReviewFormat.dateTimeLine(start: draft.start, end: draft.end))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    if let location = draft.location, !location.isEmpty {
                        Label(location, systemImage: "mappin")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Description (0.3.17): the user's extra detail, shown
                    // in full on the card — no line-count cutoff.
                    if let notes = draft.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    // Reminder info (0.3.16): shown when one was parsed or
                    // set — editable in this draft's edit disclosure.
                    if let lead = draft.reminderLeadMinutes {
                        Label(ReminderLeadFormat.phrase(minutes: lead), systemImage: "bell")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let sourcePhrase = draft.sourcePhrase, !sourcePhrase.isEmpty {
                        Text("From your note: \(sourcePhrase)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if draft.savedEventID != nil {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if !expandedDraftIDs.contains(draft.id) {
                    Button {
                        withAnimation { _ = expandedDraftIDs.insert(draft.id) }
                    } label: {
                        Text("Edit")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit details for \(draft.title)")
                } else {
                    Button {
                        _ = withAnimation { expandedDraftIDs.remove(draft.id) }
                    } label: {
                        Text("Done")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Finish editing \(draft.title)")
                    Button { vm.removeConfirmationDraft(draft.id) } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove this event")
                }
            }
            if draft.isUnresolved {
                Text("Did not resolve yet — fix the time below. Nothing will be added until this is fixed.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if !draft.defaultsApplied.isEmpty {
                ForEach(draft.defaultsApplied, id: \.self) { line in
                    Text(line).font(.caption2).foregroundStyle(.orange)
                }
            }
            if let warning = draft.overlapWarning {
                Text(warning).font(.caption2).foregroundStyle(.orange)
            }
            ForEach(draft.issues, id: \.message) { issue in
                Text(issue.message)
                    .font(.caption2)
                    .foregroundStyle(issue.blocking ? .red : .secondary)
            }
            // Low-friction chips rendered from THIS draft's actual resolver
            // candidates (not hardcoded). "noon"/"midnight" are distinct
            // 12:00 actions, never a pm shift.
            let chipCandidates = draft.ampmCandidates.isEmpty
                ? (draft.issues.contains(where: { $0.kind == .ampmAmbiguous }) ? ["am", "pm"] : [])
                : draft.ampmCandidates
            if !chipCandidates.isEmpty && draft.savedEventID == nil {
                HStack(spacing: 8) {
                    ForEach(chipCandidates, id: \.self) { candidate in
                        if candidate.lowercased().hasSuffix("pm") {
                            Button(candidate) { vm.resolveCandidate(for: draft.id, candidate: candidate) }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(candidate) { vm.resolveCandidate(for: draft.id, candidate: candidate) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            if expandedDraftIDs.contains(draft.id) && draft.savedEventID == nil {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Title", text: Binding(
                        get: { draft.title },
                        set: { vm.updateConfirmationDraft(draft.id, title: $0) }))
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        DatePicker("Starts", selection: Binding(
                            get: { draft.start },
                            set: { vm.updateConfirmationDraft(draft.id, start: $0) }))
                        DatePicker("Ends", selection: Binding(
                            get: { draft.end },
                            set: { vm.updateConfirmationDraft(draft.id, end: $0) }))
                    }
                    TextField("Location", text: Binding(
                        get: { draft.location ?? "" },
                        set: { vm.updateConfirmationDraft(draft.id, location: $0) }))
                        .textFieldStyle(.roundedBorder)
                    // Description (0.3.17): per-draft extra detail, edited
                    // through the ViewModel (same reviewed value persists
                    // to EKEvent.notes / Google description).
                    TextField("Description", text: Binding(
                        get: { draft.notes ?? "" },
                        set: { vm.updateConfirmationDraft(draft.id, notes: $0) }), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...6)
                    // Reminder (0.3.16): per-draft preset menu through the
                    // ViewModel setter (out-of-range refused there).
                    HStack {
                        Text("Reminder")
                            .font(.system(size: 12.5))
                        Spacer()
                        ReminderPresetMenu(leadMinutes: draft.reminderLeadMinutes) { lead in
                            vm.setConfirmationDraftReminder(draft.id, leadMinutes: lead)
                        }
                    }
                }
                .padding(.top, 4)
            }
            Divider()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // MARK: Delete review (explicit confirm only — never a silent mutation)

    /// Design tokens for the delete flow — the approved deep red delete
    /// confirmation (#B83A42, white text); success only after verified deletion.
    private enum DeleteTone {
        static let actionRed = QuietDesign.Voice.VoiceColor.deleteDestructive
        static let successGreen = Color(red: 0.102, green: 0.541, blue: 0.239) // #1a8a3d
    }

    private var deleteTranscriptRow: some View {
        // The original phrase stays visible above every delete state, so
        // the user always sees exactly what they said.
        Text("“\(vm.inputText)”")
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
    }

    @ViewBuilder
    private var deleteBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Labelled QA fixture: display-only state for a screenshot —
            // no real event, no sink; confirm fails closed in this process.
            qaFixtureLabel
            deleteTranscriptRow

            switch vm.deleteFlow {
            case .idle, .resolving:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(DeleteFlowCopy.findingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                deleteCancelButton

            case .noMatch(let message):
                // Design 24:124 — red caption, retry by editing the note.
                Text(message)
                    .font(.caption)
                    .foregroundStyle(DeleteTone.actionRed)
                deleteCancelButton

            case .choose(let candidates, let selectedID):
                // Design 24:111 — explicit chooser; no automatic choice.
                VStack(alignment: .leading, spacing: 8) {
                    Text(DeleteFlowCopy.chooserTitle)
                        .font(.system(size: 13, weight: .medium))
                    ForEach(candidates) { candidate in
                        Button {
                            vm.selectDeleteCandidate(candidate.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selectedID == candidate.id ? "circle.inset.filled" : "circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(selectedID == candidate.id ? DeleteTone.actionRed : .secondary)
                                Text(deleteCandidateLine(candidate))
                                    .font(.system(size: 12))
                                    .foregroundStyle(selectedID == candidate.id ? .primary : .secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedID == candidate.id ? [.isSelected] : [])
                    }
                }
                deleteActionRow(confirmEnabled: selectedID != nil) {
                    vm.confirmDeleteSelection()
                }

            case .confirmOne(let target):
                // Reviewed target + explicit confirm — the approved delete
                // design (deep red action, read-only destination calendar,
                // never a delete on release or on the X button).
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(DeleteTone.actionRed.opacity(0.12))
                                .frame(width: 28, height: 28)
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DeleteTone.actionRed)
                        }
                        .accessibilityHidden(true)
                        Text(DeleteFlowCopy.confirmTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                        Spacer(minLength: 8)
                        closeButton(action: { vm.cancelDelete() }, enabled: true, label: "Dismiss delete review without deleting")
                    }
                    Text(target.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Label {
                        Text(ConfirmationReviewFormat.dateTimeLine(start: target.start, end: target.end))
                            .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    } icon: {
                        Image(systemName: "calendar")
                            .foregroundStyle(QuietPalette.accent)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .monospacedDigit()
                    // Read-only destination: the exact calendar this delete
                    // targets — no chevron, no picker, nothing editable.
                    HStack(spacing: 7) {
                        Circle()
                            .fill(QuietPalette.accent)
                            .frame(width: 8, height: 8)
                        Text(target.calendarTitle)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(QuietDesign.Color.labelPrimary(colorScheme))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.055))
                    )
                    .accessibilityLabel("Delete target calendar \(target.calendarTitle)")
                    Text("This removes the event from \(target.calendarTitle).")
                        .font(.system(size: 12))
                        .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                    Divider()
                    HStack(spacing: 12) {
                        Button(DeleteFlowCopy.cancelButton) { vm.cancelDelete() }
                            .buttonStyle(QuietSecondaryButtonStyle())
                            .help("Nothing is deleted")
                        Spacer(minLength: 8)
                        Text("Confirm to delete")
                            .font(.system(size: 11))
                            .foregroundStyle(QuietDesign.Color.labelSecondary(colorScheme))
                        destructiveDeleteButton(enabled: true) { vm.confirmDeleteClicked() }
                    }
                }

            case .deleting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(DeleteFlowCopy.deletingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .deleted(let title, let detail):
                // Design 24:132 — success row only after verified deletion.
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DeleteTone.successGreen)
                    Text(DeleteFlowCopy.deletedRow(title: title, detail: detail))
                        .font(.system(size: 13))
                        .foregroundStyle(DeleteTone.successGreen)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DeleteTone.successGreen.opacity(0.1))
                )
                Button("Done") { vm.dismissDeleteResult() }
                    .buttonStyle(.bordered)

            case .failed(let message), .unavailable(let message), .uncertain(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                deleteCancelButton
            }
        }
    }

    private var deleteCancelButton: some View {
        Button(DeleteFlowCopy.cancelButton) { vm.cancelDelete() }
            .buttonStyle(.bordered)
    }

    /// Cancel + "Delete event" pair (the chooser path). The red action is
    /// the ONLY mutation trigger in the whole flow.
    private func deleteActionRow(confirmEnabled: Bool, onConfirm: @escaping () -> Void) -> some View {
        HStack {
            Button(DeleteFlowCopy.cancelButton) { vm.cancelDelete() }
                .buttonStyle(QuietSecondaryButtonStyle())
            Spacer()
            destructiveDeleteButton(enabled: confirmEnabled, action: onConfirm)
        }
    }

    /// The one destructive control: filled deep red (#B83A42) with white
    /// text. Disabled state never implies a mutation happened.
    private func destructiveDeleteButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(DeleteFlowCopy.deleteButton)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: 30)
                .background(
                    Capsule(style: .continuous)
                        .fill(DeleteTone.actionRed.opacity(enabled ? 1 : 0.35))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(DeleteFlowCopy.deleteButton)
    }

    /// "Title · Fri 14 Nov, 2:00 PM"
    private func deleteCandidateLine(_ candidate: EventCandidate) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE d MMM"
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        return "\(candidate.title) · \(dayFormatter.string(from: candidate.start)), \(timeFormatter.string(from: candidate.start))"
    }

    // MARK: Schedule (saved view — 0.3.20 restyle: the onboarding
    // serif/sage/matte design language, and a provider-truthful day view)

    private var scheduleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 2026-11-12: the transient quiet receipt bar after a confirmed
            // save — ~1.6 s hold, then a 140 ms fade + Y 0 → −8 dismiss.
            // Renders ONLY from confirmed persisted receipts (same honesty
            // contract as the receipt cards below); never a pre-save claim.
            if receiptHoldVisible, let last = vm.savedReceipts.last {
                VoiceReceiptBar(
                    calendarName: last.calendarSummary
                        ?? (last.provider == .google ? "Google Calendar" : "Apple Calendar"),
                    title: last.title,
                    detail: shortReceiptDetail(last)
                )
                .frame(maxWidth: 400)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -8)))
            }
            // 0.3.16 owner clarification: after a confirmed successful Add
            // the SAVED EVENT itself is shown — rendered ONLY from real
            // persisted-write receipts (`SavedEventReceipt`), with Google's
            // own event link when the insert returned one. This is the
            // just-saved display, never a bulk import or history sync.
            if !vm.savedReceipts.isEmpty {
                SavedReceiptSection(receipts: vm.savedReceipts)
            }
            // 0.3.20 provider truth: the day browser lists APPLE calendars
            // via EventKit ONLY. When the destination is Google, an empty
            // Apple day list under a Google receipt reads as a failed save —
            // so the day section is hidden for the Google destination (the
            // receipt's own "View on Google Calendar" link is the honest
            // view path; no Google calendar read scopes are ever requested
            // to fake a day list).
            if vm.prefs.calendarDestinationKind == .eventKit {
                eventKitDayBrowser
            }
            if let status = vm.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            // Sage capsule primary (onboarding style) — not stock blue.
            Button("New entry") { vm.startNewEntry() }
                .buttonStyle(QuietPrimaryButtonStyle())
                .frame(maxWidth: .infinity)
        }
        .onAppear { vm.reloadScheduleIfPossible() }
        .task(id: savedReceiptSignature) {
            // Show the just-saved receipt bar once per receipt generation,
            // hold ~1.6 s, then dismiss it with the approved 140 ms
            // (fade + Y 0 → −8; opacity-only under Reduce Motion).
            guard !savedReceiptSignature.isEmpty else { return }
            receiptHoldVisible = true
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeOut(duration: QuietDesign.Voice.Motion.dismiss)) {
                receiptHoldVisible = false
            }
        }
    }

    /// Apple-Calendar day browser (EventKit destination only): serif day
    /// heading, sage-coordinated arrow chips, matte rows with a coordinated
    /// stroke — the onboarding/QuietUI design language, not stock chrome.
    private var eventKitDayBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { vm.shiftScheduleDay(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QuietPalette.accent)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(QuietPalette.accent.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous day")
                Text(vm.scheduleDay, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .frame(maxWidth: .infinity)
                Button { vm.shiftScheduleDay(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QuietPalette.accent)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(QuietPalette.accent.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next day")
            }
            Label(vm.selectedCalendarTitle, systemImage: "calendar")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if vm.scheduleItems.isEmpty {
                        Text(dayBrowserEmptyCopy)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.scheduleItems) { item in
                            scheduleRow(item)
                        }
                    }
                }
            }
        }
    }

    /// Honest empty states: with less than full access the day list is not
    /// readable at all — never claim "no events" the app could not see.
    private var dayBrowserEmptyCopy: String {
        vm.accessPhase == .granted
            ? "No events on this day in \(vm.selectedCalendarTitle)."
            : "Day view needs Full Calendar access — events you add still save."
    }

    /// One day row on a matte coordinated surface (QuietUI), matching the
    /// receipt cards' material instead of a flat grey fill.
    private func scheduleRow(_ item: ScheduleItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.callout.weight(.medium))
            Text(timeRange(item)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(QuietPalette.surface(colorScheme: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(QuietPalette.surfaceStroke(colorScheme: colorScheme), lineWidth: 1)
        )
    }

    private func timeRange(_ item: ScheduleItem) -> String {
        if item.isAllDay { return "All day" }
        let start = item.start.formatted(date: .omitted, time: .shortened)
        let end = item.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
}

/// Compact trailing control inside the 0.3.21 capture capsule: a small
/// icon button with a subtle hover fill (never invisible, never chunky),
/// a 30×30 pt hit target, an accessibility label, and a help tooltip.
private struct CapsuleIconControl: View {
    let systemImage: String
    let label: String
    let help: String
    var tint: Color = .secondary
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(help)
    }
}

/// Soft edit-card field (2026-11-12): rounded 10 rectangle with the
/// approved field fill + hairline stroke — scheme-adaptive.
private struct VoiceFieldStyle: TextFieldStyle {
    @Environment(\.colorScheme) private var colorScheme

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(QuietDesign.Voice.VoiceColor.fieldFill(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(QuietDesign.Voice.VoiceColor.cardStroke(colorScheme), lineWidth: 1)
            )
    }
}
