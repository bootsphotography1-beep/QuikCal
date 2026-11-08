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
    private var isNoteCapsule: Bool { vm.screen == .note }

    var body: some View {
        content
            .padding(isNoteCapsule ? 0 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    : AnyShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
                if vm.screen == .note {
                    inputFocused = true
                }
                requestBarHeight()
            }
            .onChange(of: measuredSingleLineHeight) { _, _ in requestBarHeight() }
            .onChange(of: measuredInputHeight) { _, _ in requestBarHeight() }
            .onChange(of: statusSignature) { _, _ in requestBarHeight() }
    }

    private var effectiveGlass: Double {
        // Reduce Transparency handled inside GlassBackground; intensity still stored.
        glassIntensity
    }

    @ViewBuilder
    private var content: some View {
        switch vm.screen {
        case .onboarding:
            // Inline fallback if panel opened before dedicated window.
            VStack(alignment: .leading, spacing: 10) {
                Text("Finish setup in the onboarding window.")
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
        CaptureBarSizingPolicy.clampedHeight(
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
            inputRow
                .frame(height: inputRowHeight)
            if let status = statusLine {
                statusStrip(status)
            }
            if showsAMPMChips {
                ampmChipStrip
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        .padding(.horizontal, 20)
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
    }

    private var inputField: some View {
        TextField("Add to your calendar…", text: $vm.inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(inputFont)
            .lineLimit(CaptureBarSizingPolicy.inputLineLimit)
            .focused($inputFocused)
            .onChange(of: vm.inputText) { _, _ in vm.inputChanged() }
            .disabled(vm.isParsing || vm.isSaving)
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

    // MARK: Confirm (P1: explicit Yes/No, onboarding tokens; 2026-11-07
    // review pass — default REVIEW CARD, not a form-first material slab)

    /// Destination line for the review card (0.3.21: the bar itself no
    /// longer shows the account email — only this expanded review surface
    /// names the destination, where the user actually confirms the write).
    private var destinationLabel: String {
        switch vm.prefs.calendarDestinationKind {
        case .eventKit:
            return vm.selectedCalendarTitle
        case .google:
            if let account = googleAuth.activeAccount {
                return "Google · \(account.email)"
            }
            return "Google · not signed in"
        }
    }

    /// Shared design tokens (onboarding REV2.1): soft sage accent, deep
    /// sage #4e7a62 primary fill, continuous radii 16/12.
    private enum ConfirmTone {
        static let accent = Color(red: 0.45, green: 0.62, blue: 0.52)
        static let primaryFill = Color(red: 0.306, green: 0.478, blue: 0.384)
    }

    /// Edit-details disclosure state (single-draft path).
    @State private var editDetailsExpanded = false

    private var confirmBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if DEBUG
            if vm.qaDeleteFixtureActive {
                // Labelled QA fixture: display-only state for a screenshot —
                // no sink is configured; Add fails closed in this process.
                Text("QA fixture — display-only state")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
            #endif
            // Plain review question — the user decides on the READABLE
            // card, not on a form-first material slab.
            Text(ConfirmationReviewFormat.title(draftCount: vm.confirmationDrafts.isEmpty ? 1 : vm.confirmationDrafts.count))
                .font(.system(size: 16, weight: .semibold))
            if vm.confirmationDrafts.isEmpty {
                // Legacy single-draft path: FULL review — the title and
                // description wrap completely (no 2-line cutoff), and the
                // whole review scrolls vertically when the content is
                // taller than the panel. The Yes/No controls stay pinned
                // below the scroll, always reachable on screen.
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        singleReviewCard
                        DisclosureGroup("Edit details", isExpanded: $editDetailsExpanded) {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Title", text: $vm.draftTitle)
                                    .textFieldStyle(.roundedBorder)
                                DatePicker("Starts", selection: $vm.draftStart)
                                DatePicker("Ends", selection: $vm.draftEnd)
                                TextField("Location", text: $vm.draftLocation)
                                    .textFieldStyle(.roundedBorder)
                                // Description (0.3.17): the user's extra
                                // detail, editable before save — it persists
                                // to EKEvent.notes / Google description as
                                // reviewed here.
                                TextField("Description", text: $vm.draftNotes, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(2...6)
                                // Reminder (0.3.16): explicit preset menu routed
                                // through the ViewModel setter — out-of-range
                                // values are refused there, never clamped here.
                                HStack {
                                    Text("Reminder")
                                        .font(.system(size: 12.5))
                                    Spacer()
                                    ReminderPresetMenu(leadMinutes: vm.draftReminderLeadMinutes) { lead in
                                        vm.setDraftReminderLeadMinutes(lead)
                                    }
                                }
                                if vm.draftEnd <= vm.draftStart {
                                    Text("End must be after start.").font(.caption).foregroundStyle(.red)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .font(.system(size: 12.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // Multi-draft confirmation list: brief readable summary
                // cards with per-draft safety (blocking issues, AM/PM
                // chips, readiness) all explicit; edit fields per draft
                // under its own disclosure.
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.confirmationDrafts, id: \.id) { draft in
                            draftRow(draft)
                        }
                    }
                }
            }
            // Partial-batch honesty (0.3.16): when some events persisted and
            // unsaved drafts remain on this screen, the receipts for the
            // SAVED events are shown here — only confirmed persisted writes
            // produce receipts, so a partial failure never claims all saved.
            if !vm.savedReceipts.isEmpty {
                SavedReceiptSection(receipts: vm.savedReceipts)
            }
            if let status = vm.statusMessage {
                Text(status).font(.caption).foregroundStyle(.red)
            }
            if let googleBlock = vm.googleAddBlockMessage {
                Text(googleBlock)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // P1 explicit Yes/No: Yes is the EXISTING safe Add action
            // (idempotency / readiness gates / duplicate arming —
            // unchanged semantics, explicit wording). No is NON-MUTATING:
            // rejects the draft generation, keeps the recognized text
            // editable, hints re-speak. A voice "yes" NEVER authorizes a
            // write — only this button does. No duplicate Back: No is
            // the single explicit rejection (it also restores the text).
            HStack {
                Button("No") { vm.rejectConfirmationDrafts() }
                    .disabled(!noButtonEnabled)
                    .help("Not added — keep the text to edit or speak again")
                Spacer()
                Button {
                    if vm.confirmationDrafts.isEmpty {
                        vm.addConfirmedEvent()
                    } else {
                        vm.addAllConfirmationDrafts()
                    }
                } label: {
                    if vm.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(addButtonTitle)
                    }
                }
                .buttonStyle(ConfirmPrimaryButtonStyle())
                .disabled(addButtonDisabled)
                .help(vm.googleAddBlockMessage ?? "Add to the selected calendar")
            }
        }
        .padding(8)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(vm.draftTitle.isEmpty ? "Untitled event" : vm.draftTitle)
                .font(.system(size: 16, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(ConfirmationReviewFormat.dateTimeLine(start: vm.draftStart, end: vm.draftEnd))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let location = vm.draftLocation.trimmingCharacters(in: .whitespaces) as String?, !location.isEmpty {
                Label(location, systemImage: "mappin")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Description (0.3.17): the user's extra detail as parsed —
            // shown in full before save, editable under Edit details. Only
            // real user-provided content appears here; nothing is invented.
            if let notes = vm.draftNotes.trimmingCharacters(in: .whitespacesAndNewlines) as String?, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
            // Reminder info (0.3.16): shown when one was parsed or set —
            // editable via the preset menu under Edit details.
            if let lead = vm.draftReminderLeadMinutes {
                Label(ReminderLeadFormat.phrase(minutes: lead), systemImage: "bell")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Label(destinationLabel, systemImage: "calendar")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
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
        return vm.duplicateAddArmed ? "Yes, add a copy" : ConfirmationRejectionPolicy.yesLabel(pendingCount: 1)
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

    /// Design tokens for the delete flow (Figma 24:99–24:132).
    private enum DeleteTone {
        static let actionRed = Color(red: 0.843, green: 0.0, blue: 0.082)   // #d70015
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
#if DEBUG
            if vm.qaDeleteFixtureActive {
                // Labelled QA fixture: display-only state for a screenshot —
                // no real event, no sink; confirm fails closed in this process.
                Text("QA fixture — no real event")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
#endif
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
                // Design 24:99/24:102 — reviewed target + explicit confirm.
                VStack(alignment: .leading, spacing: 6) {
                    Text(DeleteFlowCopy.confirmTitle)
                        .font(.system(size: 13, weight: .medium))
                    Text(deleteTargetLine(target))
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                deleteActionRow(confirmEnabled: true) {
                    vm.confirmDeleteClicked()
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

    /// Cancel + "Delete event" pair (design 24:106/24:108). The red action
    /// is the ONLY mutation trigger in the whole flow.
    private func deleteActionRow(confirmEnabled: Bool, onConfirm: @escaping () -> Void) -> some View {
        HStack {
            Button(DeleteFlowCopy.cancelButton) { vm.cancelDelete() }
                .buttonStyle(.bordered)
            Spacer()
            Button {
                onConfirm()
            } label: {
                Text(DeleteFlowCopy.deleteButton)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(minHeight: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(DeleteTone.actionRed)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!confirmEnabled)
            .opacity(confirmEnabled ? 1 : 0.5)
            .accessibilityLabel(DeleteFlowCopy.deleteButton)
        }
    }

    /// "Title — Fri 14 Nov · 2:00–3:00 PM · Calendar: Home"
    private func deleteTargetLine(_ target: DeleteTarget) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE d MMM"
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        return "\(target.title) — \(dayFormatter.string(from: target.start)) · \(timeFormatter.string(from: target.start))–\(timeFormatter.string(from: target.end)) · Calendar: \(target.calendarTitle)"
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

/// P1 confirm primary button: deep-sage capsule (#4e7a62, AA for white
/// text) matching the onboarding primary — the EXPLICIT Yes action.
private struct ConfirmPrimaryButtonStyle: ButtonStyle {    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.85 : 1))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(isEnabled
                          ? Color(red: 0.306, green: 0.478, blue: 0.384)
                            .opacity(configuration.isPressed ? 0.75 : 1)
                          : Color(red: 0.306, green: 0.478, blue: 0.384).opacity(0.35))
            )
    }
}
