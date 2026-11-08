import Foundation

/// Per-confirmation idempotency for EventKit writes.
///
/// A new token is minted when a draft reaches confirmation. A successful write
/// commits that token so a second Add on the same confirmation cannot create
/// another event. Editing / re-parsing begins a new draft token. This is
/// stronger than a concurrent `isSaving` flag, which does not stop sequential
/// double-submits after the first save finishes.
public struct DraftSubmissionGate: Sendable, Equatable {
    public private(set) var draftToken: UUID?
    public private(set) var committedToken: UUID?

    public init(draftToken: UUID? = nil, committedToken: UUID? = nil) {
        self.draftToken = draftToken
        self.committedToken = committedToken
    }

    public mutating func beginNewDraft() {
        draftToken = UUID()
    }

    /// True when there is an active draft that has not yet been successfully written.
    public var canCommit: Bool {
        guard let draftToken else { return false }
        return draftToken != committedToken
    }

    public mutating func markCommitted() {
        committedToken = draftToken
    }

    public mutating func clearDraft() {
        draftToken = nil
    }
}

/// Pure policy for when note parse / transcript application is allowed.
public enum NoteInteractionGate: Sendable {
    public enum SpeechPhase: String, Sendable, Equatable {
        case idle
        case active
    }

    public static func canParse(
        isParsing: Bool,
        isSaving: Bool,
        speechPhase: SpeechPhase,
        noteIsEmpty: Bool
    ) -> Bool {
        !isParsing && !isSaving && speechPhase == .idle && !noteIsEmpty
    }

    /// Late dictation must not rewrite the note or bounce a confirmed draft.
    public static func shouldApplyTranscript(
        screenIsNote: Bool,
        isParsing: Bool,
        isSaving: Bool
    ) -> Bool {
        screenIsNote && !isParsing && !isSaving
    }
}

/// Outcome of a confirmed Add attempt with idempotency + exact-match handling.
public enum ConfirmedAddOutcome: Sendable, Equatable {
    case created(id: String)
    case alreadyCommitted
    case exactMatchNeedsConfirmation
    case failed(String)
}

/// Minimal calendar sink used by confirmed-add coordination (mockable in tests).
@MainActor
public protocol CalendarEventSink: AnyObject {
    func hasExactMatch(
        title: String,
        start: Date,
        end: Date,
        location: String?,
        calendarID: String
    ) -> Bool

    /// Adds one event. `notes` (nil/empty = none) persists the reviewed
    /// user description to `EKEvent.notes`. `reminderLeadMinutes` (nil =
    /// none) attaches an alarm BEFORE the event start — it never shifts
    /// start/end.
    func addEvent(
        title: String,
        start: Date,
        end: Date,
        location: String?,
        notes: String?,
        reminderLeadMinutes: Int?,
        calendarID: String
    ) throws -> String
}

public struct ConfirmedAddRequest: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    /// User-provided description/notes as reviewed on the confirmation
    /// card (0.3.17); nil = none. Persisted verbatim — never invented.
    public var notes: String?
    /// User-requested reminder lead minutes before the start; nil = none.
    public var reminderLeadMinutes: Int?
    public var calendarID: String
    public var allowDuplicate: Bool

    public init(
        title: String,
        start: Date,
        end: Date,
        location: String?,
        calendarID: String,
        allowDuplicate: Bool,
        notes: String? = nil,
        reminderLeadMinutes: Int? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.reminderLeadMinutes = reminderLeadMinutes
        self.calendarID = calendarID
        self.allowDuplicate = allowDuplicate
    }
}

/// Coordinates draft-token idempotency and exact-match warnings before a write.
public struct ConfirmedEventAdd: Sendable {
    public var gate: DraftSubmissionGate

    public init(gate: DraftSubmissionGate = DraftSubmissionGate()) {
        self.gate = gate
    }

    public mutating func beginNewDraft() {
        gate.beginNewDraft()
    }

    public mutating func clearDraft() {
        gate.clearDraft()
    }

    @MainActor
    public mutating func submit(
        _ request: ConfirmedAddRequest,
        sink: CalendarEventSink
    ) -> ConfirmedAddOutcome {
        guard gate.canCommit else {
            return .alreadyCommitted
        }
        if !request.allowDuplicate,
           sink.hasExactMatch(
            title: request.title,
            start: request.start,
            end: request.end,
            location: request.location,
            calendarID: request.calendarID
           ) {
            return .exactMatchNeedsConfirmation
        }
        do {
            let id = try sink.addEvent(
                title: request.title,
                start: request.start,
                end: request.end,
                location: request.location,
                notes: request.notes,
                reminderLeadMinutes: request.reminderLeadMinutes,
                calendarID: request.calendarID
            )
            gate.markCommitted()
            return .created(id: id)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Exact title/start/end/location comparison used by EventKit probes and tests.
public enum EventExactMatch: Sendable {
    public static func matches(
        title: String,
        start: Date,
        end: Date,
        location: String?,
        candidateTitle: String?,
        candidateStart: Date,
        candidateEnd: Date,
        candidateLocation: String?
    ) -> Bool {
        let normalizedLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidateLoc = candidateLocation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (candidateTitle ?? "") == title
            && candidateStart == start
            && candidateEnd == end
            && candidateLoc == normalizedLocation
    }
}
