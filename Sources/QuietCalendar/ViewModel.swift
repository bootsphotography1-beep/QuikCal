import SwiftUI
import QuietCalendarCore

@MainActor
final class AppViewModel: ObservableObject {
    enum Screen: Equatable {
        case note
        case confirm
        case schedule
        case onboarding
        /// Voice/typed delete review: lookup → chooser → confirm → result.
        case deleteReview
    }

    enum AccessPhase: Equatable {
        case unknown
        case notDetermined
        case denied
        case granted
        /// 2026-11-07 owner correction: EventKit WRITE-ONLY grant ("Allow /
        /// Add Events Only") — a REAL connection for adding events (the
        /// default calendar), without calendar browsing or voice delete.
        /// Previously folded into `notDetermined`, which made the user's
        /// "Allow" look disconnected.
        case writeOnly

        /// Whether EventKit permits WRITING events in this phase (full
        /// access or the write-only grant). Read-only features (calendar
        /// browsing, voice delete lookup) additionally require `.granted`.
        var permitsWriting: Bool {
            switch self {
            case .granted, .writeOnly: return true
            case .notDetermined, .denied, .unknown: return false
            }
        }
    }

    @Published var screen: Screen = .note
    @Published var inputText: String = ""
    @Published var draftTitle: String = ""
    @Published var draftStart: Date = Date()
    @Published var draftEnd: Date = Date().addingTimeInterval(3600)
    @Published var draftLocation: String = ""
    /// User-provided description/notes for the single-draft confirm
    /// (0.3.17; "" = none). Mirrors `ConfirmationDraft.notes` for the
    /// multi-draft path; shown + edited on the review card and persisted
    /// to EKEvent.notes / Google description as reviewed.
    @Published var draftNotes: String = ""
    /// User-requested reminder lead minutes for the single-draft confirm
    /// (nil = none). Mirrors `ConfirmationDraft.reminderLeadMinutes` for the
    /// multi-draft path; shown on the confirm card by the UI layer.
    @Published var draftReminderLeadMinutes: Int? = nil
    /// Honest saved-event receipts: one per event actually persisted by a
    /// confirmed Add (provider event ID, Google's official event URL when
    /// the insert returned one, target calendar, and the fields as saved).
    /// NEVER a pre-save preview — a failed or uncertain write produces no
    /// receipt, and a partial batch failure receipts only the events that
    /// persisted. Cleared when a new note/parse begins.
    @Published private(set) var savedReceipts: [SavedEventReceipt] = []
    @Published var clarification: String?
    @Published var statusMessage: String?
    @Published var parseNote: String?
    @Published var isParsing: Bool = false
    @Published var isSaving: Bool = false
    /// 2026-11-12 voice/glass review: true only after the LAST Add
    /// attempt FAILED (EventKit or Google path). Drives the failed-review
    /// surface ("Try again" + honest error row); the draft is preserved.
    /// Set false on a new submit and on any non-failure outcome.
    @Published private(set) var lastSaveFailed = false
    /// After an exact-match warning, a second Add intentionally creates another copy.
    @Published var duplicateAddArmed: Bool = false
    @Published var scheduleDay: Date = Calendar.current.startOfDay(for: Date())
    @Published var scheduleItems: [ScheduleItem] = []
    @Published var calendarChoices: [CalendarChoice] = []
    @Published var selectionState: CalendarSelectionState = .noneSelected
    @Published var accessPhase: AccessPhase = .unknown
    /// Read-only status of the OS-managed Apple Foundation Models runtime.
    @Published private(set) var foundationModelsReadiness: FoundationModelsReadiness = .current
    /// Bumped when the capture panel becomes key so the note field takes first responder.
    @Published var captureFocusNonce: Int = 0
    /// Multi-draft confirmation state (single-draft fields above stay in sync).
    @Published var confirmationDrafts: [ConfirmationDraft] = []
    @Published var confirmationTranscript: String = ""
    @Published var confirmationNote: String?
    /// AM/PM suggestion chips for the currently blocked draft (low-friction fix).
    /// Per-draft candidates live on each `ConfirmationDraft.ampmCandidates`;
    /// this mirrors the first blocked draft for legacy surfaces.
    @Published var ampmCandidates: [String] = []
    /// Voice-delete flow state (lookup → chooser → explicit confirm → result).
    /// Mirrors the DeleteCoordinator; every mutation is confirm-gated there.
    @Published var deleteFlow: DeleteFlowState = .idle
    /// P0 typed hold outcome: set by EVERY terminal path of a
    /// hold-originated voice flow (submitted / nothing recorded / needs
    /// attention). The AppDelegate observes it so the processing pill can
    /// never become a terminal state. Cleared on a new hold begin.
    @Published var holdOutcome: HoldOutcome?
    /// DEBUG QA host only (0.3.13 cards pass): true when the current
    /// delete-review state is a display-only fixture (labelled in-frame).
    /// Never set in Release; never gates any behavior.
    var qaDeleteFixtureActive = false

    #if DEBUG
    /// DEBUG QA fixture only (2026-11-07 review pass): arm the single-draft
    /// confirmation gate with the SAME production transition the real parse
    /// path performs (`beginNewDraft`) so the display-only ready fixture
    /// renders the honest ENABLED "Yes, add it" button. Never compiled into
    /// Release; arms no sink, writes nothing — a real click in the QA
    /// process still fails closed against real EventKit access.
    func qaArmSingleDraftFixtureGate() {
        confirmedAdd.beginNewDraft()
        duplicateAddArmed = false
    }

    /// DEBUG QA fixture only (2026-11-12 voice/glass pass): render the
    /// failed-review surface ("Couldn't add the event. Your draft is still
    /// here." + Try again) without a real write. No sink is armed, no
    /// calendar is touched — display only. Never compiled into Release.
    func qaForceSaveFailureForFixture() {
        lastSaveFailed = true
        statusMessage = "Couldn't add the event. Your draft is still here."
    }
    #endif

    let speech: SpeechCapture
    let calendarService = CalendarService()
    /// Local JSON store is retained so existing Application Support events stay untouched.
    let localStore: EventStore
    let prefs: AppPreferencesStore
    private let deterministicPipeline: ParsingPipeline
    private let phrasePipeline: PhrasePipeline
    private let deleteCoordinator = DeleteCoordinator()
    private let deleteParser = EventParser(calendar: .current, nowProvider: { Date() })
    private let defaults: UserDefaults
    private let calendarIDKey = AppPreferenceKey.selectedCalendarID

    private var parseTask: Task<Void, Never>?
    private var parseGeneration = 0
    private var saveGeneration = 0
    private var confirmedAdd = ConfirmedEventAdd()
    private var holdToTalkActive = false

    var onAfterSuccessfulAdd: (() -> Void)?
    var onRequestPanelResize: ((CapturePresentationPhase) -> Void)?
    /// 0.3.21 Spotlight capsule: the capture view measures its wrapped
    /// input and requests the capsule window height (already clamped to
    /// `barAvailableHeight` by `CaptureBarSizingPolicy`). Applied only in
    /// the bar phases — the confirmation review keeps its own size.
    var onRequestBarHeight: ((CGFloat) -> Void)?
    /// Available height for the capsule on the display the panel targets
    /// (set by the AppDelegate before presenting). Growth beyond this
    /// becomes internal input scrolling instead of leaving the screen.
    var barAvailableHeight: CGFloat = 10_000

    /// Google write context supplied by the app layer. Nil means Google is
    /// not ready (unconfigured / signed out / no target calendar) — the
    /// ViewModel then refuses the write with a clear message. No silent
    /// fallback to EventKit and never a guessed destination.
    struct GoogleWriteContext {
        /// Concrete sink (conforms to both the Add and Delete sink
        /// protocols) so the delete lane can reuse the same writer.
        let sink: GoogleCalendarWriteSink
        let calendarID: String
        let calendarSummary: String
    }
    var googleWriterProvider: (() -> GoogleWriteContext?)?

    /// Live Google destination readiness, supplied by the app layer from the
    /// real auth/calendar state (GoogleOAuthService.destinationReadiness).
    /// Nil (not wired) means not ready — fail closed.
    var googleReadinessProvider: (() -> GoogleDestinationReadiness?)?

    init(
        defaults: UserDefaults = .standard,
        speechCapture: SpeechCapture? = nil
    ) {
        self.defaults = defaults
        self.prefs = AppPreferencesStore(defaults: defaults)
        let dir: URL
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dir = base.appendingPathComponent("QuietCalendar", isDirectory: true)
        } else {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuietCalendar", isDirectory: true)
        }
        self.localStore = EventStore(directory: dir)
        let calendar = Calendar.current
        self.phrasePipeline = PhrasePipeline(calendar: calendar)
        self.deterministicPipeline = ParsingPipeline(
            parser: EventParser(calendar: calendar, nowProvider: { Date() }),
            calendar: calendar)
        if let speechCapture {
            self.speech = speechCapture
        } else {
            let prefsStore = AppPreferencesStore(defaults: defaults)
            self.speech = SpeechCapture(
                modelURLProvider: { prefsStore.resolveParakeetModelURL() }
            )
        }
        speech.onFinalTranscript = { [weak self] text in
            self?.applyTranscript(text)
        }
        speech.refreshModelReadiness()
        refreshAccessPhase()
        refreshSelection()
    }

    func refreshFoundationModelsReadiness() {
        foundationModelsReadiness = .current
    }

    var selectedCalendarTitle: String {
        selectionState.choice?.displayName ?? "No calendar selected"
    }

    var speechPhase: NoteInteractionGate.SpeechPhase {
        switch speech.state {
        case .idle: return .idle
        case .requesting, .recording, .finishing: return .active
        }
    }

    var presentationPhase: CapturePresentationPhase {
        if speech.state == .recording || speech.state == .requesting || holdToTalkActive {
            return .listening
        }
        if isParsing { return .parsing }
        switch screen {
        case .confirm, .deleteReview: return .confirmation
        case .schedule: return .daySchedule
        case .note, .onboarding: return .note
        }
    }

    /// UI gate for Parse: idle mic, non-empty note, not already parsing/saving.
    var canParseNote: Bool {
        NoteInteractionGate.canParse(
            isParsing: isParsing,
            isSaving: isSaving,
            speechPhase: speechPhase,
            noteIsEmpty: inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    var canAddDraft: Bool {
        let destinationReady: Bool
        switch prefs.calendarDestinationKind {
        case .eventKit:
            destinationReady = selectionState.choice != nil && accessPhase.permitsWriting
        case .google:
            // Derived from the REAL Google state (signed-in account, usable
            // tokens, loaded writable calendar list containing the selected
            // target). Never hardcoded; an unwired provider fails closed.
            destinationReady = googleDestinationStatus?.isReady == true
        }
        return !isSaving
            && !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draftEnd > draftStart
            && destinationReady
            && (confirmedAdd.gate.canCommit || duplicateAddArmed)
    }

    /// The live Google readiness verdict while Google is the destination;
    /// nil for EventKit or when no readiness provider is wired.
    var googleDestinationStatus: GoogleDestinationReadiness? {
        guard prefs.calendarDestinationKind == .google else { return nil }
        return googleReadinessProvider?()
    }

    /// User-facing reason the Google Add is currently blocked (confirm screen,
    /// next to the disabled Add button). nil when ready or not using Google.
    var googleAddBlockMessage: String? {
        guard let status = googleDestinationStatus, !status.isReady else { return nil }
        return status.failureMessage
    }

    // MARK: - Calendar selection / onboarding

    func refreshAccessPhase() {
        switch calendarService.authorizationStatus {
        case .fullAccess:
            accessPhase = .granted
        case .denied, .restricted:
            accessPhase = .denied
        case .writeOnly:
            // 2026-11-07 owner correction: a write-only grant is a REAL
            // connected-for-writing state — never folded back into
            // "not determined" (that made the user's Allow look lost).
            accessPhase = .writeOnly
        case .notDetermined:
            accessPhase = .notDetermined
        @unknown default:
            accessPhase = .unknown
        }
    }

    func refreshSelection() {
        refreshAccessPhase()
        switch accessPhase {
        case .granted:
            calendarChoices = calendarService.writableChoices()
        case .writeOnly:
            // Write-only cannot enumerate calendars — the default calendar
            // for new events is the honest writable choice.
            calendarChoices = calendarService.defaultWritableChoices()
        case .notDetermined, .denied, .unknown:
            calendarChoices = []
        }
        let stored = defaults.string(forKey: calendarIDKey)
        selectionState = CalendarSelection.resolve(storedID: stored, choices: calendarChoices)
    }

    func requestCalendarAccess() {
        statusMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.calendarService.requestFullAccess()
                // Permission callback → refresh the store's source state,
                // the main-actor observable phase, and the calendar
                // enumeration TOGETHER, so the Allow is reflected as
                // connected immediately (2026-11-07 owner correction).
                self.calendarService.refreshAfterAuthorizationChange()
                self.refreshAccessPhase()
                if self.accessPhase.permitsWriting {
                    self.refreshSelection()
                    if self.selectionState.choice != nil {
                        // Stay in current flow; dedicated onboarding window manages Continue.
                    } else if self.calendarChoices.isEmpty {
                        self.statusMessage = "No writable calendars were found in the accounts configured on this Mac."
                    } else if self.accessPhase == .writeOnly {
                        // Honest write-only connection copy — never a
                        // demand for full access from the UI.
                        self.statusMessage = "Calendar connected (add events to your default calendar). Full Access additionally enables calendar browsing and voice delete."
                    }
                } else {
                    self.accessPhase = .denied
                    self.statusMessage = "Calendar access was not granted. You can still type notes, but adding requires access."
                }
            } catch {
                self.refreshAccessPhase()
                self.statusMessage = "Could not request calendar access: \(error.localizedDescription)"
            }
        }
    }

    func selectCalendar(_ choice: CalendarChoice) {
        defaults.set(choice.id, forKey: calendarIDKey)
        prefs.calendarDestinationKind = .eventKit
        refreshSelection()
        statusMessage = nil
    }

    func openOnboarding() {
        cancelParse()
        speech.cancel()
        refreshSelection()
        screen = .onboarding
    }

    /// Settings helper: refresh EventKit choices without forcing the capture panel into onboarding chrome.
    func openOnboardingInline() {
        refreshSelection()
        requestCalendarAccess()
    }

    // MARK: - Hold to talk

    /// P0 symmetric begin: returns true ONLY when capture actually started
    /// (the confirm gate passed AND speech left `.idle` — `.requesting`
    /// counts as started). Callers must not claim Listening on false.
    @discardableResult
    func beginHoldToTalk() -> Bool {
        // Inherited race fix: pressing hold while confirm must not start mic or resize.
        guard HoldToTalkConfirmPolicy.shouldBeginCapture(whenScreenIsConfirm: screen == .confirm) else {
            return false
        }
        holdToTalkActive = true
        if screen != .note {
            screen = .note
        }
        statusMessage = nil
        holdOutcome = nil
        if speech.state == .idle {
            speech.start()
        }
        let started = speech.state != .idle
        if started {
            onRequestPanelResize?(.listening)
        }
        return started
    }

    /// P0 symmetric end: EVERY release resolves. Returns true when the
    /// normal finish path ran (capture was active); false when nothing was
    /// actually recording — in that case an honest typed outcome is set so
    /// the pill resolves immediately (never a silent return to idle).
    @discardableResult
    func endHoldToTalk() -> Bool {
        holdToTalkActive = false
        // If begin was ignored (confirm open) or capture already failed,
        // there is nothing to stop — resolve honestly instead of sticking.
        guard speech.state == .recording || speech.state == .requesting || speech.state == .finishing else {
            if speech.message == nil && statusMessage == nil {
                statusMessage = HoldOutcomeCopy.nothingRecordedRetryCopy
            }
            holdOutcome = .nothingRecorded
            return false
        }
        // Stop recording; when final transcript arrives, parse → confirm (never auto-write).
        speech.onFinalTranscript = { [weak self] text in
            guard let self else { return }
            self.applyTranscript(text)
            self.submitNote()
            // P0 TERMINAL-STATE GUARANTEE: every submitNote early-return
            // path (empty text, blocked destination, delete clarification,
            // …) must resolve the processing pill — if no observed signal
            // (isParsing / speech message) will fire, resolve right here.
            if !self.isParsing && !self.isSaving {
                self.holdOutcome = .needsAttention(
                    self.statusMessage ?? self.clarification ?? HoldOutcomeCopy.nothingRecordedRetryCopy
                )
            } else {
                self.holdOutcome = .submitted
            }
            // Restore default transcript handler for mic button.
            self.speech.onFinalTranscript = { [weak self] t in
                self?.applyTranscript(t)
            }
        }
        speech.stop()
        return true
    }

    /// FAIL-SAFE cancel (2026-11-07): terminate an in-flight hold WITHOUT
    /// the release→transcribe→parse→submit path. `SpeechCapture.cancel()`
    /// tears down the engine, cancels the inference task and deletes the
    /// temp audio; its generation token makes any late completion a
    /// no-op, so NO transcript can ever arrive from a cancelled hold.
    /// Called when listener paths die mid-hold, Accessibility is lost,
    /// hold-to-talk is turned off, the watchdog confirms a lost release,
    /// the recording cap elapses, or the app quits — never from a
    /// trusted release.
    func cancelHoldToTalk() {
        holdToTalkActive = false
        // Restore the default (non-submitting) transcript handler so a
        // hypothetical later mic-button capture behaves normally.
        speech.onFinalTranscript = { [weak self] text in
            self?.applyTranscript(text)
        }
        speech.cancel()
    }

    // MARK: - Note → parse → confirm

    func applyTranscript(_ text: String) {
        guard NoteInteractionGate.shouldApplyTranscript(
            screenIsNote: screen == .note,
            isParsing: isParsing,
            isSaving: isSaving
        ) else { return }
        inputText = text
        clarification = nil
        statusMessage = nil
        parseNote = nil
    }

    func inputChanged() {
        clarification = nil
        statusMessage = nil
        parseNote = nil
        if screen == .confirm {
            screen = .note
            confirmedAdd.clearDraft()
            duplicateAddArmed = false
        }
        if screen == .deleteReview {
            // Editing the note cancels any pending delete review — the
            // reviewed target is dropped, nothing was mutated.
            deleteCoordinator.reset()
            deleteFlow = .idle
            screen = .note
        }
        cancelParse()
    }

    func submitNote() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            clarification = nil
            statusMessage = "Type something to add to your calendar."
            return
        }
        guard !isSaving, !isParsing else { return }

        // A new parse invalidates any pending delete review (the delete UI
        // only renders on .deleteReview, and beginDelete resets anyway —
        // this keeps the coordinator from holding a stale reviewed target).
        if case .idle = deleteFlow {} else {
            deleteCoordinator.reset()
            deleteFlow = .idle
        }

        if speech.state != .idle {
            speech.cancel()
        }

        // Voice-delete routing: a cheap deterministic discriminator runs
        // BEFORE any add parsing — a leading delete cue never reaches the
        // add pipeline, and a "delete" appearing anywhere else (quoted,
        // injected inside an add request, mid-sentence) is never a delete.
        switch DeleteIntentDiscriminator.classify(text, parser: deleteParser, now: Date()) {
        case .deleteQuery(let query):
            beginDelete(query)
            return
        case .needsClarification(let message):
            cancelParse()
            clarification = message
            statusMessage = nil
            screen = .note
            onRequestPanelResize?(.note)
            return
        case .notDelete:
            break
        }

        if prefs.calendarDestinationKind == .eventKit {
            refreshSelection()
            if selectionState.needsAttention || !accessPhase.permitsWriting {
                statusMessage = "Choose a writable calendar before adding events."
                return
            }
        }
        // Google destination: parse → confirm preview always runs; the Add
        // button itself is gated by the live readiness verdict (canAddDraft),
        // and the confirm screen shows googleAddBlockMessage when blocked.

        cancelParse()
        parseGeneration += 1
        let token = parseGeneration
        isParsing = true
        clarification = nil
        statusMessage = nil
        parseNote = nil
        onRequestPanelResize?(.parsing)

        parseTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.phrasePipeline.run(transcript: text, now: Date())
            guard !Task.isCancelled, self.parseGeneration == token else { return }
            self.isParsing = false
            self.applyPhrase(outcome: outcome, token: token)
        }
    }

    // MARK: - Voice delete (lookup → chooser → EXPLICIT confirm → verified delete)

    /// Begin a delete flow on the single active lane (EventKit XOR Google).
    /// Lookup only — nothing is mutated until the user clicks "Delete event"
    /// on the reviewed target.
    private func beginDelete(_ query: DeleteQuery) {
        cancelParse()
        deleteCoordinator.reset()
        deleteFlow = .idle
        clarification = nil
        statusMessage = nil
        parseNote = nil

        switch prefs.calendarDestinationKind {
        case .eventKit:
            refreshSelection()
            guard accessPhase == .granted else {
                statusMessage = DeleteFlowCopy.eventKitFullAccessNeeded
                return
            }
            guard let choice = selectionState.choice else {
                statusMessage = DeleteFlowCopy.eventKitNoCalendar
                return
            }
            screen = .deleteReview
            deleteFlow = .resolving
            onRequestPanelResize?(.confirmation)
            Task { [weak self] in
                guard let self else { return }
                self.deleteFlow = await self.deleteCoordinator.begin(
                    query: query,
                    calendarID: choice.id,
                    calendarTitle: choice.title,
                    calendar: Calendar.current,
                    now: Date(),
                    sink: self.calendarService
                )
            }
        case .google:
            guard let status = googleDestinationStatus else {
                statusMessage = DeleteFlowCopy.googleNotReady(GoogleDestinationBlock.unavailable.message)
                return
            }
            guard status.isReady, let context = googleWriterProvider?() else {
                statusMessage = DeleteFlowCopy.googleNotReady(
                    status.failureMessage ?? GoogleDestinationBlock.unavailable.message)
                return
            }
            screen = .deleteReview
            deleteFlow = .resolving
            onRequestPanelResize?(.confirmation)
            Task { [weak self] in
                guard let self else { return }
                self.deleteFlow = await self.deleteCoordinator.begin(
                    query: query,
                    calendarID: context.calendarID,
                    calendarTitle: context.calendarSummary,
                    calendar: Calendar.current,
                    now: Date(),
                    sink: context.sink
                )
            }
        }
    }

    /// Chooser selection (ambiguous matches) — no automatic choice.
    func selectDeleteCandidate(_ id: String) {
        deleteFlow = deleteCoordinator.select(candidateID: id)
    }

    /// Proceed from the chooser to the confirmation panel with the
    /// explicitly selected candidate.
    func confirmDeleteSelection() {
        deleteFlow = deleteCoordinator.confirmSelection()
    }

    /// The FINAL explicit user action. The coordinator ignores it unless a
    /// reviewed target is pending, revalidates against live provider state,
    /// performs one delete, and verifies before claiming success.
    func confirmDeleteClicked() {
        guard case .confirmOne = deleteFlow else { return }
        let sink: EventDeleteSink
        switch prefs.calendarDestinationKind {
        case .eventKit:
            sink = calendarService
        case .google:
            guard let context = googleWriterProvider?() else {
                deleteFlow = .failed(DeleteFlowCopy.googleNotReady(GoogleDestinationBlock.unavailable.message))
                return
            }
            sink = context.sink
        }
        Task { [weak self] in
            guard let self else { return }
            self.deleteFlow = await self.deleteCoordinator.confirmDelete(
                sink: sink, calendar: Calendar.current)
        }
    }

    /// Cancel the delete flow. Never mutates; ignored while a delete is
    /// in flight (a cancel can never race into an unexpected deletion).
    func cancelDelete() {
        deleteFlow = deleteCoordinator.cancel()
        if case .idle = deleteFlow {
            screen = .note
            onRequestPanelResize?(.note)
        }
    }

    /// Dismiss a finished delete result back to the note field.
    func dismissDeleteResult() {
        deleteCoordinator.reset()
        deleteFlow = .idle
        screen = .note
        onRequestPanelResize?(.note)
    }

    private func applyPhrase(outcome: PhrasePipelineOutcome, token: Int) {        guard parseGeneration == token else { return }
        parseNote = outcome.note
        switch outcome.set {
        case .drafts(let drafts, let transcript):
            confirmationDrafts = drafts
            confirmationTranscript = transcript
            confirmationNote = outcome.note
            savedReceipts = []
            if let first = drafts.first {
                draftTitle = first.title; draftStart = first.start; draftEnd = first.end
                draftLocation = first.location ?? ""
                draftNotes = first.notes ?? ""
                draftReminderLeadMinutes = first.reminderLeadMinutes
            }
            clarification = nil; statusMessage = nil
            confirmedAdd.beginNewDraft(); duplicateAddArmed = false
            ampmCandidates = []
            screen = .confirm
            onRequestPanelResize?(.confirmation)
        case .clarification(let message, let transcript):
            // Plain clarification ONLY when no event was extractable. The
            // original note is preserved (input + confirmationTranscript) —
            // it never disappears.
            clarification = message; statusMessage = nil; screen = .note
            confirmationTranscript = transcript
            if !transcript.isEmpty { inputText = transcript }
            ampmCandidates = []
            onRequestPanelResize?(.note)
        case .failed(let message):
            clarification = nil; statusMessage = message; screen = .note
            onRequestPanelResize?(.note)
        }
    }

    /// Edit one confirmation draft and re-validate THAT draft only: stable ID,
    /// original transcript, and every other draft are untouched. A manual
    /// DatePicker start/end edit is an explicit time choice, so a stale
    /// AM/PM-ambiguity block is cleared for this draft; other blocking
    /// issues (missing title, instruction-like, vague, …) stay blocking.
    func updateConfirmationDraft(_ id: UUID, title: String? = nil, start: Date? = nil,
                                 end: Date? = nil, location: String? = nil, notes: String? = nil) {
        guard let index = confirmationDrafts.firstIndex(where: { $0.id == id }) else { return }
        var draft = confirmationDrafts[index]
        if let title { draft.title = title }
        if let start { draft.start = start }
        if let end { draft.end = end }
        if let location { draft.location = location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        if let notes { draft.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        let timeEdited = start != nil || end != nil
        if timeEdited {
            draft.issues.removeAll { $0.kind == .ampmAmbiguous || $0.kind == .noTime }
            draft.ampmCandidates = []
        }
        draft.issues = draft.issues.filter { $0.kind != .missingTitle }
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.issues.append(ValidationIssue(kind: .missingTitle, message: "What is this event called?", blocking: true))
        }
        if draft.end <= draft.start {
            draft.issues.append(ValidationIssue(kind: .slotRejected, message: "End must be after start.", blocking: true))
        } else {
            draft.issues.removeAll { $0.kind == .slotRejected && $0.message == "End must be after start." }
        }
        confirmationDrafts[index] = draft
    }

    func removeConfirmationDraft(_ id: UUID) {
        confirmationDrafts.removeAll { $0.id == id }
        if confirmationDrafts.isEmpty { screen = .note }
    }

    /// Set or clear the reminder for ONE confirmation draft (minutes before
    /// the event start). Explicit: nil clears the reminder (provider
    /// defaults are then left untouched). Out-of-range values are refused
    /// with an honest message — never clamped.
    func setConfirmationDraftReminder(_ id: UUID, leadMinutes: Int?) {
        guard let index = confirmationDrafts.firstIndex(where: { $0.id == id }) else { return }
        if let leadMinutes,
           !(0...EventDraftResolver.maximumReminderLeadMinutes).contains(leadMinutes) {
            statusMessage = "That reminder is too far ahead — reminders can be at most 4 weeks (28 days) before an event."
            return
        }
        confirmationDrafts[index].reminderLeadMinutes = leadMinutes
    }

    /// Set or clear the reminder for the single-draft confirmation (minutes
    /// before the event start). Same honesty rules as the draft variant.
    func setDraftReminderLeadMinutes(_ leadMinutes: Int?) {
        if let leadMinutes,
           !(0...EventDraftResolver.maximumReminderLeadMinutes).contains(leadMinutes) {
            statusMessage = "That reminder is too far ahead — reminders can be at most 4 weeks (28 days) before an event."
            return
        }
        draftReminderLeadMinutes = leadMinutes
    }

    /// Low-friction AM/PM resolution: chip supplies the missing meridiem.
    /// Re-resolves THIS draft's stored phrases through the real resolver
    /// (stable ID + original transcript preserved; other drafts untouched).
    /// "noon" is a distinct 12:00 action, never a pm shift.
    func resolveAMPM(for draftID: UUID, isPM: Bool) {
        resolveCandidate(for: draftID, candidate: isPM ? "pm" : "am")
    }

    /// Resolve with an actual candidate string from the draft ("12:30 pm",
    /// "noon", …). Falls back to the legacy hour-shift only when the draft
    /// carries no phrases (built-in single-draft path).
    func resolveCandidate(for draftID: UUID, candidate: String) {
        guard let index = confirmationDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        var draft = confirmationDrafts[index]
        guard let phrases = draft.phrases else {
            // Legacy path: shift the placeholder hour (am/pm only).
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: draft.start)
            let minute = calendar.component(.minute, from: draft.start)
            let isPM = candidate.lowercased().hasSuffix("pm")
            let target: Int
            if isPM { target = (hour < 12) ? hour + 12 : hour }
            else    { target = (hour >= 12) ? hour - 12 : hour }
            if target != hour,
               let newStart = calendar.date(bySettingHour: target, minute: minute, second: 0, of: draft.start) {
                let duration = draft.end.timeIntervalSince(draft.start)
                draft.start = newStart
                draft.end = newStart.addingTimeInterval(duration)
            }
            draft.issues.removeAll { $0.kind == .ampmAmbiguous }
            draft.ampmCandidates = []
            confirmationDrafts[index] = draft
            return
        }
        let now: Date = ISO8601DateFormatter().date(from: draft.provenance.referenceNowISO) ?? Date()
        let resolver = DateResolver(calendar: Calendar.current)
        // Normalise bare "am"/"pm" chip labels to the draft's bare clock.
        var effectiveCandidate = candidate
        let lowered = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "am" || lowered == "pm", let base = phrases.timePhrase {
            effectiveCandidate = "\(base) \(lowered)"
        }
        switch resolver.resolveWithCandidate(phrases, transcript: draft.provenance.transcript,
                                             now: now, provenance: draft.provenance, candidate: effectiveCandidate) {
        case .resolved(let resolved):
            draft.title = resolved.title
            draft.start = resolved.start
            draft.end = resolved.end
            draft.location = resolved.location
            draft.notes = resolved.notes
            draft.reminderLeadMinutes = resolved.reminderLeadMinutes
            draft.defaultsApplied = resolved.defaultsApplied
            draft.provenance = resolved.provenance
            draft.issues.removeAll { $0.kind == .ampmAmbiguous || $0.kind == .noTime || $0.kind == .noDate }
            draft.ampmCandidates = []
            confirmationDrafts[index] = draft
        case .clarification(let message, let candidates):
            draft.ampmCandidates = candidates
            draft.issues.removeAll { $0.kind == .ampmAmbiguous }
            draft.issues.append(ValidationIssue(eventIndex: draft.eventIndex, kind: .ampmAmbiguous, message: message, blocking: true))
            confirmationDrafts[index] = draft
        }
        ampmCandidates = confirmationDrafts.first(where: { $0.isUnresolved })?.ampmCandidates ?? []
    }

    private func apply(outcome: ParseOutcome, token: Int) {
        guard parseGeneration == token else { return }
        parseNote = outcome.note
        switch outcome.result {
        case .event(let draft):
            draftTitle = draft.title
            draftStart = draft.start
            draftEnd = draft.end
            draftLocation = draft.location ?? ""
            draftNotes = draft.notes ?? ""
            draftReminderLeadMinutes = draft.reminderLeadMinutes
            savedReceipts = []
            clarification = nil
            statusMessage = nil
            ampmCandidates = []
            confirmedAdd.beginNewDraft()
            duplicateAddArmed = false
            screen = .confirm
            onRequestPanelResize?(.confirmation)
        case .needsClarification(let message):
            clarification = message
            statusMessage = nil
            // Meridiem-ambiguous clock (0.3.22): real am/pm candidates ride
            // with the clarification so the note screen can offer chips.
            ampmCandidates = outcome.ampmCandidates
            screen = .note
            onRequestPanelResize?(.note)
        case .failed(let message):
            clarification = nil
            statusMessage = message
            ampmCandidates = []
            screen = .note
            onRequestPanelResize?(.note)
        }
    }

    /// AM/PM chip on the note screen (0.3.22): re-parse the SAME note with
    /// the chosen meridiem — the recognized clock hour is updated (e.g.
    /// 3:00 → 15:00), nothing else changes, and the resulting draft still
    /// needs an explicit Add before anything is written to a calendar.
    func resolveClarificationAMPM(isPM: Bool) {
        guard !isParsing, !isSaving else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cancelParse()
        parseGeneration += 1
        let token = parseGeneration
        isParsing = true
        clarification = nil
        statusMessage = nil
        parseNote = nil
        ampmCandidates = []
        onRequestPanelResize?(.parsing)
        parseTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.deterministicPipeline.parse(text, now: Date(), forcingPM: isPM)
            guard !Task.isCancelled, self.parseGeneration == token else { return }
            self.isParsing = false
            self.apply(outcome: outcome, token: token)
        }
    }

    func cancelConfirmation() {
        cancelParse()
        confirmedAdd.clearDraft()
        duplicateAddArmed = false
        screen = .note
        clarification = nil
        statusMessage = nil
        ampmCandidates = []
        onRequestPanelResize?(.note)
    }

    /// P1 — explicit "No" on the confirm screen: NON-MUTATING rejection of
    /// the current draft generation. Nothing is written to any calendar
    /// (the rejection path never reaches a write coordinator/sink); the
    /// original recognized transcript stays in the editable note field, and
    /// the hint offers re-speak via the hold shortcut. Refused while a
    /// write is in flight or already committed — never a fake cancel of an
    /// executed calendar write.
    func rejectConfirmationDrafts() {
        guard ConfirmationRejectionPolicy.mayReject(
            isSaving: isSaving,
            anyDraftCommitted: confirmationDrafts.contains { $0.savedEventID != nil }
                || (confirmedAdd.gate.canCommit == false && confirmationDrafts.isEmpty && screen == .confirm)
        ) else { return }
        let outcome = ConfirmationRejectionPolicy.reject(
            transcript: confirmationTranscript.isEmpty ? inputText : confirmationTranscript,
            shortcutName: prefs.holdToTalkShortcut.shortName
        )
        cancelParse()
        confirmedAdd.clearDraft()
        duplicateAddArmed = false
        confirmationDrafts = []
        confirmationTranscript = ""
        confirmationNote = nil
        ampmCandidates = []
        inputText = outcome.restoredTranscript
        clarification = nil
        parseNote = nil
        statusMessage = outcome.hint
        holdOutcome = .needsAttention(outcome.hint)
        screen = .note
        onRequestPanelResize?(.note)
    }

    func startNewEntry() {
        cancelParse()
        speech.cancel()
        confirmedAdd.clearDraft()
        duplicateAddArmed = false
        deleteCoordinator.reset()
        deleteFlow = .idle
        inputText = ""
        clarification = nil
        statusMessage = nil
        parseNote = nil
        ampmCandidates = []
        draftTitle = ""
        draftLocation = ""
        draftNotes = ""
        draftReminderLeadMinutes = nil
        savedReceipts = []
        screen = .note
        onRequestPanelResize?(.note)
    }

    // MARK: - Explicit Add (EventKit write only after this)

    func addConfirmedEvent() {
        guard !isSaving else { return }
        if draftEnd <= draftStart {
            statusMessage = "End must be after start."
            return
        }

        if prefs.calendarDestinationKind == .google {
            addConfirmedEventToGoogle()
            return
        }

        // Single destination — never dual-write EventKit + Google.
        let destination = DestinationPolicy.resolve(
            kind: prefs.calendarDestinationKind,
            eventKitCalendarID: selectionState.choice?.id,
            googleAccountID: prefs.googleActiveAccountID,
            googleCalendarID: nil
        )
        guard case .eventKit(let calendarID) = destination else {
            statusMessage = "Choose a writable calendar before adding."
            return
        }
        guard accessPhase.permitsWriting else {
            statusMessage = "Calendar access required."
            return
        }

        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard confirmedAdd.gate.canCommit || duplicateAddArmed else {
            statusMessage = "Already added from this confirmation."
            return
        }

        saveGeneration += 1
        let token = saveGeneration
        isSaving = true
        lastSaveFailed = false
        statusMessage = nil

        let start = draftStart
        let end = draftEnd
        let location = draftLocation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let notes = draftNotes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let allowDuplicate = duplicateAddArmed
        let reminderLeadMinutes = draftReminderLeadMinutes

        let outcome = confirmedAdd.submit(
            ConfirmedAddRequest(
                title: title,
                start: start,
                end: end,
                location: location,
                calendarID: calendarID,
                allowDuplicate: allowDuplicate,
                notes: notes,
                reminderLeadMinutes: reminderLeadMinutes
            ),
            sink: calendarService
        )

        guard saveGeneration == token else { return }

        switch outcome {
        case .created(let eventID):
            isSaving = false
            lastSaveFailed = false
            duplicateAddArmed = false
            scheduleDay = Calendar.current.startOfDay(for: start)
            inputText = ""
            clarification = nil
            parseNote = nil
            // Honest saved-event receipt: only the confirmed persisted write
            // produces one (never the pre-save preview).
            savedReceipts.append(SavedEventReceipt(
                provider: .eventKit,
                eventID: eventID,
                calendarID: calendarID,
                calendarSummary: selectionState.choice?.title,
                title: title,
                start: start,
                end: end,
                location: location,
                notes: notes,
                reminderLeadMinutes: reminderLeadMinutes))
            reloadScheduleIfPossible()
            screen = .schedule
            statusMessage = "Added to \(selectionState.choice?.title ?? "calendar")."
            onAfterSuccessfulAdd?()
            onRequestPanelResize?(.daySchedule)
        case .alreadyCommitted:
            isSaving = false
            lastSaveFailed = false
            statusMessage = "Already added from this confirmation."
            scheduleDay = Calendar.current.startOfDay(for: start)
            reloadScheduleIfPossible()
            screen = .schedule
            onRequestPanelResize?(.daySchedule)
        case .exactMatchNeedsConfirmation:
            isSaving = false
            lastSaveFailed = false
            duplicateAddArmed = true
            statusMessage = "An identical event is already on this calendar. Press Add again to create another copy."
        case .failed(let message):
            isSaving = false
            lastSaveFailed = true
            refreshSelection()
            if case .missing = selectionState {
                statusMessage = "That calendar is no longer writable. Choose another calendar."
            } else {
                statusMessage = message
            }
        }
    }

    /// Explicit confirmed Add to the selected Google calendar. The write runs
    /// through GoogleWriteCoordinator: duplicate probe first (fail-closed),
    /// then one events.insert. No automatic writes, no EventKit side-write.
    /// Gated on the live readiness verdict — never on a hardcoded flag.
    private func addConfirmedEventToGoogle() {
        guard let status = googleDestinationStatus else {
            statusMessage = GoogleDestinationBlock.unavailable.message
            return
        }
        guard status.isReady, let context = googleWriterProvider?() else {
            statusMessage = status.failureMessage ?? GoogleDestinationBlock.unavailable.message
            return
        }
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard confirmedAdd.gate.canCommit || duplicateAddArmed else {
            statusMessage = "Already added from this confirmation."
            return
        }

        saveGeneration += 1
        let token = saveGeneration
        isSaving = true
        lastSaveFailed = false
        statusMessage = nil

        let start = draftStart
        let end = draftEnd
        let location = draftLocation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let notes = draftNotes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let allowDuplicate = duplicateAddArmed
        let reminderLeadMinutes = draftReminderLeadMinutes
        let summary = context.calendarSummary

        Task { @MainActor [weak self] in
            guard let self, self.saveGeneration == token else { return }
            var draft = ConfirmationDraft(
                title: title, start: start, end: end, location: location,
                source: .appDefaulted,
                provenance: DraftProvenance(
                    source: .appDefaulted,
                    transcript: self.confirmationTranscript,
                    referenceNowISO: ISO8601DateFormatter().string(from: Date()),
                    timeZoneID: TimeZone.current.identifier
                ),
                reminderLeadMinutes: reminderLeadMinutes,
                notes: notes
            )
            draft.duplicateAddArmed = allowDuplicate
            let result = await GoogleWriteCoordinator.write(
                drafts: [draft], calendarID: context.calendarID, calendarSummary: summary, sink: context.sink)
            guard self.saveGeneration == token else { return }
            self.isSaving = false
            switch result.outcomes[draft.id] {
            case .created:
                self.duplicateAddArmed = false
                self.scheduleDay = Calendar.current.startOfDay(for: start)
                self.inputText = ""
                self.clarification = nil
                self.parseNote = nil
                // Honest saved-event receipts from the confirmed write result
                // (provider event ID + Google's own htmlLink when returned).
                self.savedReceipts.append(contentsOf: result.receipts)
                self.reloadScheduleIfPossible()
                self.screen = .schedule
                self.statusMessage = "Added to \(summary) (Google)."
                self.onAfterSuccessfulAdd?()
                self.onRequestPanelResize?(.daySchedule)
            case .exactMatchNeedsConfirmation:
                self.duplicateAddArmed = true
                self.statusMessage = "An identical event is already on this Google calendar. Press Add again to create another copy."
            case .alreadySaved:
                self.statusMessage = "Already added from this confirmation."
                self.lastSaveFailed = false
            case .commitUncertain(let message):
                self.statusMessage = "Save outcome uncertain (\(message)) — press Add again; an already-saved event will be recognised, not duplicated."
            case .failed(let message):
                self.statusMessage = "Could not add to Google Calendar: \(message)."
                self.lastSaveFailed = true
            case .none:
                self.statusMessage = "Could not add to Google Calendar."
                self.lastSaveFailed = true
            }
        }
    }

    /// Batch Add for the confirmation set to the selected Google calendar:
    /// sequential per-event inserts with exact-match probes; per-draft
    /// outcomes are honest (earlier successes stay saved if a later one fails).
    private func addAllConfirmationDraftsToGoogle() {
        guard let status = googleDestinationStatus else {
            statusMessage = GoogleDestinationBlock.unavailable.message
            return
        }
        guard status.isReady, let context = googleWriterProvider?() else {
            statusMessage = status.failureMessage ?? GoogleDestinationBlock.unavailable.message
            return
        }
        guard !confirmationDrafts.isEmpty else { return }
        saveGeneration += 1
        let token = saveGeneration
        isSaving = true; statusMessage = nil
        lastSaveFailed = false
        let drafts = confirmationDrafts
        let summary = context.calendarSummary

        Task { @MainActor [weak self] in
            guard let self, self.saveGeneration == token else { return }
            let result = await GoogleWriteCoordinator.write(
                drafts: drafts, calendarID: context.calendarID, calendarSummary: summary, sink: context.sink)
            guard self.saveGeneration == token else { return }
            self.isSaving = false
            var savedCount = 0
            var failures: [String] = []
            for index in drafts.indices {
                guard let outcome = result.outcomes[drafts[index].id] else { continue }
                switch outcome {
                case .created(let id):
                    self.confirmationDrafts[index].savedEventID = id
                    savedCount += 1
                case .exactMatchNeedsConfirmation:
                    self.confirmationDrafts[index].duplicateAddArmed = true
                    failures.append("“\(drafts[index].title)” matches an event already on this Google calendar — press Add again to create a copy.")
                case .alreadySaved:
                    break
                case .failed(let message):
                    failures.append(message)
                case .commitUncertain(let message):
                    // Draft kept; retry re-probes exact matches first, so an
                    // actually-persisted event is never duplicated.
                    failures.append("Save outcome uncertain for “\(drafts[index].title)” (\(message)) — press Add again; an already-saved event will be recognised, not duplicated.")
                }
            }
            if savedCount > 0 {
                self.statusMessage = "Added \(savedCount) event\(savedCount == 1 ? "" : "s") to \(summary) (Google)."
                if let firstSaved = self.confirmationDrafts.first(where: { $0.savedEventID != nil }) {
                    self.scheduleDay = Calendar.current.startOfDay(for: firstSaved.start)
                }
                // Receipts ONLY for the drafts that actually persisted —
                // a partial failure never claims all events saved.
                self.savedReceipts.append(contentsOf: result.receipts)
                self.reloadScheduleIfPossible()
                if self.confirmationDrafts.allSatisfy({ $0.savedEventID != nil }) {
                    self.inputText = ""; self.clarification = nil; self.parseNote = nil
                    self.screen = .schedule
                }
                self.onAfterSuccessfulAdd?()
            } else if !failures.isEmpty {
                self.statusMessage = failures.joined(separator: " ")
                self.lastSaveFailed = true
            }
        }
    }

    /// Batch Add for the confirmation set: each addable draft goes to the chosen
    /// EventKit calendar exactly once; per-draft outcomes are reported and
    /// unsaved drafts are kept (already-saved ones are never rewritten).
    func addAllConfirmationDrafts() {
        guard !isSaving else { return }
        if prefs.calendarDestinationKind == .google {
            addAllConfirmationDraftsToGoogle()
            return
        }
        let destination = DestinationPolicy.resolve(
            kind: prefs.calendarDestinationKind,
            eventKitCalendarID: selectionState.choice?.id,
            googleAccountID: prefs.googleActiveAccountID,
            googleCalendarID: nil)
        guard case .eventKit(let calendarID) = destination else {
            statusMessage = "Choose a writable calendar before adding."
            return
        }
        guard accessPhase.permitsWriting else {
            statusMessage = "Calendar access required."
            return
        }
        saveGeneration += 1
        let token = saveGeneration
        isSaving = true; statusMessage = nil
        lastSaveFailed = false
        let result = WriteCoordinator().write(
            drafts: confirmationDrafts, calendarID: calendarID,
            calendarSummary: selectionState.choice?.title, sink: calendarService)
        guard saveGeneration == token else { return }
        isSaving = false
        var savedCount = 0
        var failures: [String] = []
        for index in confirmationDrafts.indices {
            guard let outcome = result.outcomes[confirmationDrafts[index].id] else { continue }
            switch outcome {
            case .created(let id):
                confirmationDrafts[index].savedEventID = id
                savedCount += 1
            case .exactMatchNeedsConfirmation:
                confirmationDrafts[index].duplicateAddArmed = true
                failures.append("“\(confirmationDrafts[index].title)” matches an event already on this calendar — press Add again to create a copy.")
            case .alreadySaved:
                break
            case .failed(let message):
                failures.append(message)
            case .commitUncertain(let message):
                // Draft kept; retry re-probes exact matches first, so a
                // partially persisted event is never duplicated.
                failures.append("Save outcome uncertain for “\(confirmationDrafts[index].title)” (\(message)) — press Add again; an already-saved event will be recognised, not duplicated.")
            }
        }
        if savedCount > 0 {
            statusMessage = "Added \(savedCount) event\(savedCount == 1 ? "" : "s") to \(selectionState.choice?.title ?? "calendar")."
            if let firstSaved = confirmationDrafts.first(where: { $0.savedEventID != nil }) {
                scheduleDay = Calendar.current.startOfDay(for: firstSaved.start)
            }
            // Receipts ONLY for the drafts that actually persisted.
            savedReceipts.append(contentsOf: result.receipts)
            reloadScheduleIfPossible()
            if confirmationDrafts.allSatisfy({ $0.savedEventID != nil }) {
                inputText = ""; clarification = nil; parseNote = nil
                screen = .schedule
            }
            onAfterSuccessfulAdd?()
        } else if !failures.isEmpty {
            statusMessage = failures.joined(separator: " ")
            lastSaveFailed = true
        }
    }

    func reloadScheduleIfPossible() {
        refreshSelection()
        guard case .valid(let choice) = selectionState, accessPhase == .granted else {
            scheduleItems = []
            return
        }
        scheduleItems = calendarService.schedule(on: scheduleDay, calendarID: choice.id)
    }

    func showScheduleForDraftDay() {
        scheduleDay = Calendar.current.startOfDay(for: draftStart)
        reloadScheduleIfPossible()
        screen = .schedule
    }

    func shiftScheduleDay(_ delta: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: delta, to: scheduleDay) {
            scheduleDay = Calendar.current.startOfDay(for: next)
            reloadScheduleIfPossible()
        }
    }

    // MARK: - Cleanup

    func cancelParse() {
        parseGeneration += 1
        parseTask?.cancel()
        parseTask = nil
        isParsing = false
    }

    func prepareForPopoverOpen() {
        refreshSelection()
        if screen == .schedule {
            reloadScheduleIfPossible()
        }
        // Leaving schedule keeps the day view; note/confirm drafts stay intact across toggle.
        if screen == .onboarding {
            screen = .note
        }
        onRequestPanelResize?(presentationPhase)
    }

    func requestCaptureFieldFocus() {
        captureFocusNonce &+= 1
    }
}
