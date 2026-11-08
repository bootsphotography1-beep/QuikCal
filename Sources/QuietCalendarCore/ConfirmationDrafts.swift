import Foundation

/// One editable draft in the confirmation list — one per extracted event,
/// including blocked/unresolved ones. `canAdd` is derived: any blocking
/// validation/resolver issue disables Add for this draft only; other drafts
/// remain addable. Editing re-validates the selected draft only.
public struct ConfirmationDraft: Sendable, Equatable, Codable {
    public var id: UUID
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    public var source: DraftSource
    public var provenance: DraftProvenance
    public var defaultsApplied: [String]
    public var issues: [ValidationIssue]
    public var overlapWarning: String?
    public var savedEventID: String?
    /// Per-draft duplicate guard: a second Add after an exact-match warning is intentional.
    public var duplicateAddArmed: Bool
    /// Extracted phrases for THIS event (stable per-event mapping; nil for
    /// built-in single-draft path). Used to re-resolve on AM/PM chip / edits.
    public var phrases: EventPhrases?
    /// Index of this event in the model's raw `events` array (no shifts).
    public var eventIndex: Int?
    /// Actual AM/PM candidates from the resolver for this draft (not hardcoded).
    public var ampmCandidates: [String]
    /// Human-readable source phrase(s) for this event, shown on the card.
    public var sourcePhrase: String?
    /// User-requested reminder lead minutes before the start; nil = none
    /// (provider default reminders stay untouched). Backward-compatible
    /// Codable: drafts encoded before this field decode with nil.
    public var reminderLeadMinutes: Int?
    /// User-provided description/notes (0.3.17), shown and editable on the
    /// review card; persisted to EKEvent.notes / Google description as
    /// reviewed. Backward-compatible Codable: older drafts decode with nil.
    public var notes: String?

    public init(id: UUID = UUID(), title: String, start: Date, end: Date, location: String?,
                source: DraftSource, provenance: DraftProvenance,
                defaultsApplied: [String] = [], issues: [ValidationIssue] = [],
                overlapWarning: String? = nil,
                phrases: EventPhrases? = nil, eventIndex: Int? = nil,
                ampmCandidates: [String] = [], sourcePhrase: String? = nil,
                reminderLeadMinutes: Int? = nil, notes: String? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end
        self.location = location; self.source = source; self.provenance = provenance
        self.defaultsApplied = defaultsApplied; self.issues = issues
        self.overlapWarning = overlapWarning
        self.savedEventID = nil; self.duplicateAddArmed = false
        self.phrases = phrases; self.eventIndex = eventIndex
        self.ampmCandidates = ampmCandidates; self.sourcePhrase = sourcePhrase
        self.reminderLeadMinutes = reminderLeadMinutes
        self.notes = notes
    }

    // Backwards-compatible decoding for drafts encoded before these fields existed.
    private enum CodingKeys: String, CodingKey {
        case id, title, start, end, location, source, provenance, defaultsApplied
        case issues, overlapWarning, savedEventID, duplicateAddArmed
        case phrases, eventIndex, ampmCandidates, sourcePhrase, reminderLeadMinutes, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        source = try c.decode(DraftSource.self, forKey: .source)
        provenance = try c.decode(DraftProvenance.self, forKey: .provenance)
        defaultsApplied = try c.decodeIfPresent([String].self, forKey: .defaultsApplied) ?? []
        issues = try c.decodeIfPresent([ValidationIssue].self, forKey: .issues) ?? []
        overlapWarning = try c.decodeIfPresent(String.self, forKey: .overlapWarning)
        savedEventID = try c.decodeIfPresent(String.self, forKey: .savedEventID)
        duplicateAddArmed = try c.decodeIfPresent(Bool.self, forKey: .duplicateAddArmed) ?? false
        phrases = try c.decodeIfPresent(EventPhrases.self, forKey: .phrases)
        eventIndex = try c.decodeIfPresent(Int.self, forKey: .eventIndex)
        ampmCandidates = try c.decodeIfPresent([String].self, forKey: .ampmCandidates) ?? []
        sourcePhrase = try c.decodeIfPresent(String.self, forKey: .sourcePhrase)
        reminderLeadMinutes = try c.decodeIfPresent(Int.self, forKey: .reminderLeadMinutes)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    public var canAdd: Bool {
        !issues.contains { $0.blocking } && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && end > start && savedEventID == nil
    }

    public var needsDuplicateConfirmation: Bool {
        duplicateAddArmed && savedEventID == nil
    }

    /// True for a retained placeholder that has not resolved yet.
    public var isUnresolved: Bool { issues.contains { $0.blocking } }
}

public enum ConfirmationSet: Sendable, Equatable {
    case drafts([ConfirmationDraft], transcript: String)
    case clarification(String, transcript: String)
    case failed(String)
}

extension [ConfirmationDraft] {
    public var allAddable: Bool { allSatisfy { $0.canAdd } }
}
