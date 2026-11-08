import Foundation

/// Composes per-event resolutions into a confirmation set: one draft per
/// extracted event (resolved OR blocked/unresolved), in model order, with the
/// validated index ↔ draft mapping preserved (no shifts). Blocked events are
/// retained as editable placeholder cards carrying their field issues and
/// actual AM/PM candidates — they are never compacted away. A resolver
/// clarification becomes a blocking field issue on that draft only, never
/// discards the whole pipeline. Inherits a *common date only when
/// unambiguous*, and warns (never reschedules) on overlaps.
public enum MultiEventComposer: Sendable {
    public static func compose(
        validated: [ValidatedPhrases],
        transcript: String,
        now: Date,
        calendar: Calendar,
        provenance: DraftProvenance
    ) -> (drafts: [ConfirmationDraft], clarifications: [String], warnings: [String]) {
        let resolver = DateResolver(calendar: calendar)

        // Common-date inheritance: only if every phrase-null sibling shares one
        // unambiguous explicit date phrase. Never inherits time or duration.
        var inheritedDate: String? = nil
        let explicitDates = Set(validated.compactMap { $0.phrases.datePhrase?.lowercased() })
        if validated.contains(where: { $0.phrases.datePhrase == nil }) && explicitDates.count == 1 {
            inheritedDate = validated.first(where: { $0.phrases.datePhrase != nil })?.phrases.datePhrase
        }

        var drafts: [ConfirmationDraft] = []
        var clarifications: [String] = []
        for (index, v) in validated.enumerated() {
            var phrases = v.phrases
            if phrases.datePhrase == nil, let inherited = inheritedDate {
                phrases.datePhrase = inherited
            }
            var prov = provenance
            if let note = v.evidenceNote, !note.isEmpty {
                prov.note = ((prov.note ?? "") + " " + note).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let sourcePhrase = sourcePhraseText(for: phrases)
            switch resolver.resolve(phrases, transcript: transcript, now: now, provenance: prov) {
            case .resolved(let draft):
                var c = ConfirmationDraft(
                    title: draft.title, start: draft.start, end: draft.end, location: draft.location,
                    source: draft.provenance.source, provenance: draft.provenance,
                    defaultsApplied: draft.defaultsApplied, issues: v.issues,
                    phrases: phrases, eventIndex: index,
                    ampmCandidates: [], sourcePhrase: sourcePhrase,
                    reminderLeadMinutes: draft.reminderLeadMinutes,
                    notes: draft.notes)
                // If validator already flagged this event blocking (e.g. an
                // ampmAmbiguous the resolver nevertheless resolved via
                // context), the resolver's contextual resolution wins and the
                // stale blocking flag must not keep it blocked. Detect by
                // re-checking: resolver resolved ⇒ drop ampmAmbiguous blocking
                // flags that the contextual path satisfied.
                if v.issues.contains(where: { $0.blocking && $0.kind == .ampmAmbiguous }) {
                    c.issues = v.issues.filter { !($0.blocking && $0.kind == .ampmAmbiguous) }
                }
                drafts.append(c)
            case .clarification(let message, let candidates):
                clarifications.append(message)
                // Retain as an editable placeholder card: title/source phrase,
                // placeholder start/end (editable), field issues, real candidates.
                let issue = ValidationIssue(eventIndex: index, kind: issueKind(for: message, phrases: phrases),
                                            message: message, blocking: true)
                var issues = v.issues
                if !issues.contains(where: { $0.message == message }) { issues.append(issue) }
                let (placeholderStart, placeholderEnd) = placeholderTimes(
                    phrases: phrases, now: now, calendar: calendar, provenance: prov)
                drafts.append(ConfirmationDraft(
                    title: phrases.title ?? "",
                    start: placeholderStart, end: placeholderEnd,
                    location: phrases.location,
                    source: prov.source, provenance: prov,
                    defaultsApplied: ["Did not resolve yet — pick a time or edit the fields below. Nothing will be added until this is fixed."],
                    issues: issues,
                    phrases: phrases, eventIndex: index,
                    ampmCandidates: candidates, sourcePhrase: sourcePhrase,
                    notes: phrases.notes))
            }
        }

        // Overlap warnings across resolved drafts — warn, never reschedule or trim.
        var warnings: [String] = []
        let resolved = drafts.filter { !$0.isUnresolved }
        for i in resolved.indices {
            for j in resolved.indices where j > i {
                let a = resolved[i], b = resolved[j]
                if a.start < b.end, b.start < a.end {
                    warnings.append("“\(a.title)” and “\(b.title)” overlap — both will be added as shown.")
                }
            }
        }
        // Attach overlap warnings to the matching drafts (by title, stable order).
        for i in drafts.indices where !drafts[i].isUnresolved {
            if let warning = warnings.first(where: { $0.contains(drafts[i].title) }) {
                drafts[i].overlapWarning = warning
            }
        }
        return (drafts, clarifications, warnings)
    }

    static func sourcePhraseText(for phrases: EventPhrases) -> String? {
        let parts = [phrases.title, phrases.datePhrase, phrases.timePhrase, phrases.durationPhrase,
                     phrases.location, phrases.reminderPhrase]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Map a resolver clarification to a field-issue kind.
    static func issueKind(for message: String, phrases: EventPhrases) -> DerivedUncertainty {
        let m = message.lowercased()
        if m.contains("am or") || m.contains("am/pm") || m.contains("pick one") { return .ampmAmbiguous }
        if phrases.title == nil || m.contains("called") { return .missingTitle }
        if m.contains("passed") || m.contains("does not exist") || m.contains("doesn't exist") || m.contains("daylight") { return .noDate }
        if m.contains("time") || m.contains("clock") { return .noTime }
        if m.contains("day") { return .noDate }
        return .vague
    }

    /// Editable placeholder start/end for a blocked event: the referenced day
    /// (or today/tomorrow default day) at the best-effort parsed clock, else
    /// 09:00. Always end > start. The user edits these via DatePickers; the
    /// draft stays blocked (canAdd false) until issues are resolved.
    static func placeholderTimes(phrases: EventPhrases, now: Date, calendar: Calendar,
                                 provenance: DraftProvenance) -> (Date, Date) {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        let parser = EventParser(calendar: calendar, nowProvider: { now })
        if let datePhrase = phrases.datePhrase, !datePhrase.isEmpty {
            if let parsed = parser.parseDatePhrase(datePhrase, now: now).components,
               let y = parsed.year, let mo = parsed.month, let d = parsed.day {
                comps.year = y; comps.month = mo; comps.day = d
            }
        }
        var hour = 9, minute = 0
        if let timePhrase = phrases.timePhrase,
           let parsed = parser.parseTimePhrase(timePhrase).components,
           let h = parsed.hour, let mi = parsed.minute {
            hour = h; minute = mi
        } else if let timePhrase = phrases.timePhrase,
                  let comps2 = PhraseValidator.bareHourComponents(timePhrase) {
            hour = comps2.hour % 12; minute = comps2.minute
        }
        comps.hour = hour; comps.minute = minute; comps.second = 0
        comps.timeZone = calendar.timeZone
        let start = calendar.date(from: comps) ?? now
        var duration = 3600
        if let dp = phrases.durationPhrase, let parsed = parser.parseDurationPhrase(dp) {
            duration = EventDraftResolver.normalizedDuration(parsed)
        }
        let end = calendar.date(byAdding: .second, value: duration, to: start) ?? start.addingTimeInterval(3600)
        return (start, end)
    }
}
