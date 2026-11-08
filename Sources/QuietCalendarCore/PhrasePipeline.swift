import Foundation

/// End-to-end phrase pipeline: extraction → validation → resolution → confirmation set.
///
/// - Apple Foundation Models is the production extraction runtime by default.
/// - Its output passes the same validator + resolver as deterministic parsing.
/// - Model trust tags are ignored; everything downstream derives from fields.
/// - Time-zone is IANA (`America/Denver`-style); UTC storage falls out of `Date`.
public struct PhrasePipelineOutcome: Sendable, Equatable {
    public var set: ConfirmationSet
    public var note: String?
    public var source: DraftSource?
}

public struct PhrasePipeline: Sendable {
    public var phraseRuntime: PhraseExtractionRuntime?
    public var calendar: Calendar

    public init(phraseRuntime: PhraseExtractionRuntime? = FoundationModelsPhraseRuntime(), calendar: Calendar) {
        self.phraseRuntime = phraseRuntime
        self.calendar = calendar
    }

    public func run(transcript: String, now: Date) async -> PhrasePipelineOutcome {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PhrasePipelineOutcome(set: .failed("Type something to add to your calendar."))
        }
        let isoFormatter = ISO8601DateFormatter()
        let provenance = DraftProvenance(
            source: .builtInParser,
            transcript: trimmed,
            referenceNowISO: isoFormatter.string(from: now),
            timeZoneID: calendar.timeZone.identifier)

        if let runtime = phraseRuntime {
            do {
                try Task.checkCancellation()
                let raw = try await runtime.extract(transcript: trimmed, now: now, calendar: calendar)
                try Task.checkCancellation()
                var prov = provenance
                prov.source = .appleFoundationModels
                prov.modelTag = nil
                prov.note = "Extracted on-device by Apple Foundation Models — please review and confirm."
                return PhrasePipelineOutcome(
                    set: compose(raw: raw, transcript: trimmed, now: now, provenance: prov),
                    source: .appleFoundationModels)
            } catch is CancellationError {
                return PhrasePipelineOutcome(set: .failed("Extraction cancelled — try again."),
                                             source: .foundationModelsFallback)
            } catch let error as ExtractionRuntimeError {
                if error == .cancelled {
                    return PhrasePipelineOutcome(set: .failed(error.errorDescription ?? "Extraction cancelled."),
                                                 source: .foundationModelsFallback)
                }
                return PhrasePipelineOutcome(
                    set: composeFromText(trimmed, now: now, provenance: provenance),
                    note: error.errorDescription,
                    source: .foundationModelsFallback)
            } catch {
                return PhrasePipelineOutcome(
                    set: composeFromText(trimmed, now: now, provenance: provenance),
                    note: "Apple Intelligence could not complete extraction — used the built-in parser.",
                    source: .foundationModelsFallback)
            }
        }
        return PhrasePipelineOutcome(set: composeFromText(trimmed, now: now, provenance: provenance),
                                     source: .builtInParser)
    }

    private func composeFromText(_ text: String, now: Date, provenance: DraftProvenance) -> ConfirmationSet {
        // Built-in path: reuse the classic deterministic parser, then carry the
        // multi-draft confirmation shape (single draft, sources labelled).
        let parser = EventParser(calendar: calendar, nowProvider: { Date() })
        switch parser.extractIntent(text, now: now) {
        case .intent(let intent):
            switch EventDraftResolver(calendar: calendar).resolve(intent, now: now) {
            case .event(let draft):
                var prov = provenance
                prov.note = "Built-in parser."
                // Owner-approved daytime inference (2026-11-08): visibly
                // labelled as a default on the review card, editable.
                let daytimeLabel: [String] = intent.timeInferredDaytime
                    ? ["Start time inferred from the spoken clock using ordinary daytime meeting hours (9–5) — check and edit it if needed."]
                    : []
                let confirmation = ConfirmationDraft(
                    title: draft.title, start: draft.start, end: draft.end, location: draft.location,
                    source: .builtInParser, provenance: prov,
                    defaultsApplied: daytimeLabel,
                    reminderLeadMinutes: draft.reminderLeadMinutes,
                    notes: draft.notes)
                return .drafts([confirmation], transcript: text)
            case .needsClarification(let message):
                return .clarification(message, transcript: text)
            case .failed(let message):
                return .failed(message)
            }
        case .needsClarification(let message):
            return .clarification(message, transcript: text)
        case .failed(let message):
            return .failed(message)
        }
    }

    private func compose(raw: RawPhraseOutput, transcript: String, now: Date, provenance: DraftProvenance) -> ConfirmationSet {
        // 0.3.20: the model's raw title/notes are NORMALIZED here — the
        // structured extraction boundary — with the SAME shared normalizer
        // the deterministic parser uses (`TitleNotesNormalizer`). A model
        // title that still carries the conversational command wrapper
        // ("go ahead and add my …") or a cue-attached scheduling phrase
        // ("due morning") is cleaned; correction scaffolding ("9 a.m.
        // instead of …") never reaches the notes; an explicit
        // user-quoted/called title survives VERBATIM; a title that cleans
        // to empty stays empty so the validator asks honestly. Grounding
        // then runs on the cleaned values (cleanup only removes tokens, so
        // a cleaned phrase stays traceable to the user's own words).
        let raw = TitleNotesNormalizer.normalize(raw, transcript: transcript)
        // Plain clarification text ONLY when no event was extractable at all.
        // The original transcript is carried in the set so it never disappears.
        guard !raw.events.isEmpty else {
            let validated = PhraseValidator.validate(raw, transcript: transcript)
            let blocking = validated.flatMap { $0.issues }.first { $0.blocking }
            return .clarification(
                blocking?.message ?? "Nothing calendar-like was extracted — edit the note or pick a date and time. Your note is kept.",
                transcript: transcript)
        }
        let validated = PhraseValidator.validate(raw, transcript: transcript)
        // One draft per extracted event (resolved or blocked) with the
        // validated index ↔ draft mapping preserved — no shifts, no drops.
        // Resolver clarifications already became field issues on their draft.
        let (drafts, _, _) = MultiEventComposer.compose(
            validated: validated, transcript: transcript, now: now, calendar: calendar, provenance: provenance)
        return .drafts(drafts, transcript: transcript)
    }
}
