import Foundation

/// Validated, schema-clean phrases. Nulls are preserved — defaults are applied
/// later by the resolver and labelled, never invented here.
public struct EventPhrases: Sendable, Equatable, Codable {
    public var title: String?
    public var datePhrase: String?
    public var timePhrase: String?
    public var durationPhrase: String?
    public var location: String?
    /// Reminder lead-time phrase ("15 minutes before", "an hour before"),
    /// when the note asked for a reminder. Optional, additive (v2 schema):
    /// older model outputs without it decode as nil.
    public var reminderPhrase: String?
    /// Event description/notes (0.3.17): the user's extra detail copied
    /// verbatim from the note. Optional, additive — older model outputs
    /// without it decode as nil.
    public var notes: String?

    public init(title: String? = nil, datePhrase: String? = nil, timePhrase: String? = nil,
                durationPhrase: String? = nil, location: String? = nil, reminderPhrase: String? = nil,
                notes: String? = nil) {
        self.title = title; self.datePhrase = datePhrase; self.timePhrase = timePhrase
        self.durationPhrase = durationPhrase; self.location = location
        self.reminderPhrase = reminderPhrase; self.notes = notes
    }
}

public enum DerivedUncertainty: String, Sendable, Equatable, CaseIterable, Codable {
    case noDate, noTime, ampmAmbiguous, vague, correctedTime, conflictingTime, multiEvent
    case instructionLike, missingTitle, missingDuration, missingLocation
    case negation, filler, slotRejected, emptyEvents, locationPrompt, personNotPlace
}

/// Meridiem inferred from same-event transcript context for a bare clock.
/// `.conflicting` means two different qualifiers were present — ask, never guess.
public enum ContextualMeridiem: Sendable, Equatable {
    case am
    case pm
    case twentyFour
    case conflicting

    public var label: String {
        switch self {
        case .am: return "morning/midnight"
        case .pm: return "noon/afternoon"
        case .twentyFour: return "24 hour time"
        case .conflicting: return "conflicting"
        }
    }

    /// Concrete 24h hour for a bare 1–12 clock under this meridiem.
    public func hour24(forBareHour hour: Int) -> Int {
        switch self {
        case .am: return hour % 12
        case .pm: return hour % 12 + 12
        case .twentyFour: return hour
        case .conflicting: return hour
        }
    }
}

public struct ValidationIssue: Sendable, Equatable, Codable {
    public var eventIndex: Int?
    public var kind: DerivedUncertainty
    public var message: String
    public var blocking: Bool

    public init(eventIndex: Int? = nil, kind: DerivedUncertainty, message: String, blocking: Bool) {
        self.eventIndex = eventIndex; self.kind = kind; self.message = message; self.blocking = blocking
    }
}

public struct ValidatedPhrases: Sendable, Equatable {
    public var phrases: EventPhrases
    public var originalPhrases: EventPhrases
    public var issues: [ValidationIssue]
    public var evidenceNote: String?

    public var hasBlockingIssue: Bool { issues.contains { $0.blocking } }
}

/// Deterministic validator — the safety core.
///
/// There are **no literal content blacklists** here: an attacker-supplied word is
/// legitimate event content whenever the user actually said it. Injection is
/// handled primarily structurally: transcript instructions are never executed,
/// model output is data only, and any extracted phrase that cannot be grounded
/// in the user's own words is nulled and asks for clarification.
/// `containsInstructionLikeSpan` is a *pattern-based heuristic signal* (regex
/// word patterns), not a structural proof and not a guarantee — see its docs.
public enum PhraseValidator: Sendable {
    public static let timeOfDayWords: Set<String> = ["morning", "afternoon", "evening", "night"]
    public static let vagueWords: Set<String> = ["ish", "around", "about", "roughly", "sometime"]

    // MARK: - Global entry

    public static func validate(_ raw: RawPhraseOutput, transcript: String) -> [ValidatedPhrases] {
        // G1 — nonempty (also enforced by the decoder; defence in depth).
        guard !raw.events.isEmpty else {
            return [ValidatedPhrases(
                phrases: EventPhrases(),
                originalPhrases: EventPhrases(),
                issues: [ValidationIssue(kind: .emptyEvents,
                    message: "Nothing calendar-like was extracted — edit the note or pick a date and time. Your note is kept.",
                    blocking: true)],
                evidenceNote: nil
            )]
        }
        let globalIssues = globalIssues(transcript: transcript)
        let multi = raw.events.count > 1
        return raw.events.enumerated().map { index, event in
            let phrases = EventPhrases(
                title: event.title, datePhrase: event.datePhrase, timePhrase: event.timePhrase,
                durationPhrase: event.durationPhrase, location: event.location,
                reminderPhrase: event.reminderPhrase, notes: event.notes)
            var validated = validateEvent(phrases, transcript: transcript, eventIndex: index)
            if multi {
                validated.issues.append(ValidationIssue(eventIndex: index, kind: .multiEvent,
                    message: "One of \(raw.events.count) events from this note.", blocking: false))
            }
            validated.issues.insert(contentsOf: globalIssues.map {
                ValidationIssue(eventIndex: index, kind: $0.kind, message: $0.message, blocking: $0.blocking)
            }, at: 0)
            return validated
        }
    }

    private static func globalIssues(transcript: String) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if containsInstructionLikeSpan(transcript) {
            // Structural defence: instruction-like spans are never executed, and
            // any draft touching one is blocked until the user confirms it is
            // genuinely their event (no content blacklists involved).
            issues.append(ValidationIssue(kind: .instructionLike,
                message: "Part of this note read like an instruction to the app — it was treated as ordinary event text and not acted on. Confirm the draft matches your own words before adding.",
                blocking: true))
        }
        if containsCorrectionMarker(transcript) {
            issues.append(ValidationIssue(kind: .correctedTime,
                message: "You corrected something — the latest wording is used; the original is kept in the provenance note.",
                blocking: false))
        }
        if containsFiller(transcript) {
            issues.append(ValidationIssue(kind: .filler,
                message: "Filler words were ignored.", blocking: false))
        }
        // Multi-event coverage heuristic (non-blocking prompt only, not a proof).
        if transcript.components(separatedBy: " and ").count > 1 && hasTwoClockTimes(transcript) {
            issues.append(ValidationIssue(kind: .multiEvent,
                message: "You may have mentioned more than one event — check the list in case one was missed.",
                blocking: false))
        }
        return issues
    }

    // MARK: - Per-event rules

    private static func validateEvent(_ input: EventPhrases, transcript: String, eventIndex: Int) -> ValidatedPhrases {
        var p = input
        var issues: [ValidationIssue] = []
        var evidenceParts: [String] = []

        // --- Grounding: phrases must trace to the transcript (structural, not a blacklist).
        // Harmless normalisation is accepted: case, punctuation, filler, and article/stop
        // words are ignored when checking coverage.
        for (field, value) in [("title", p.title), ("date_phrase", p.datePhrase),
                               ("time_phrase", p.timePhrase), ("duration_phrase", p.durationPhrase),
                               ("location", p.location), ("reminder_phrase", p.reminderPhrase),
                               ("notes", p.notes)] {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if !isGrounded(value, in: transcript) {
                issues.append(ValidationIssue(eventIndex: eventIndex, kind: .instructionLike,
                    message: "The extracted \(field.replacingOccurrences(of: "_", with: " ")) could not be traced to your words — it was cleared so nothing invented is saved. Re-type it if it mattered.",
                    blocking: true))
                switch field {
                case "title": p.title = nil
                case "date_phrase": p.datePhrase = nil
                case "time_phrase": p.timePhrase = nil
                case "duration_phrase": p.durationPhrase = nil
                case "reminder_phrase": p.reminderPhrase = nil
                case "notes": p.notes = nil
                default: p.location = nil
                }
            }
        }

        // --- S1: whole-sentence slot capture on the date phrase.
        if let datePhrase = p.datePhrase {
            let words = datePhrase.split(separator: " ").count
            let hasTimeToken = containsTimeOrDurationToken(datePhrase)
            if words > 6 || hasTimeToken {
                p.datePhrase = nil
                issues.append(ValidationIssue(eventIndex: eventIndex, kind: .slotRejected,
                    message: "Part of this looked like the whole sentence — pick the day.",
                    blocking: true))
            }
        }

        // --- S2: time-of-day words are never clock times.
        // A SPOKEN clock phrase that carries its own day part ("three
        // o'clock in the afternoon") IS a clock time — only a bare day
        // part ("afternoon") is rejected as not-a-time.
        if let timePhrase = p.timePhrase {
            let lowered = timePhrase.lowercased()
            if timeOfDayWords.contains(where: { lowered.contains($0) }),
               clockComponents(in: timePhrase) == nil,
               SpokenClock.components(inPhrase: timePhrase) == nil {
                let dayWord = timeOfDayWords.first(where: { lowered.contains($0) }) ?? "morning"
                issues.append(ValidationIssue(eventIndex: eventIndex, kind: .vague,
                    message: "“\(dayWord.capitalized)” is not a clock time — what time should this start?",
                    blocking: true))
                p.timePhrase = dayWord // keep as a vague marker; resolver asks for a clock time
            }
        }

        // --- S3: bare hour without am/pm.
        // A bare clock like 12:30 / 2 is ambiguous UNLESS (a) it is unambiguous
        // 24h (hour 13-23 or 0 with a colon, or an explicit "24 hour time"
        // phrase), or (b) the same event segment carries a noon/midday,
        // afternoon, morning, or midnight qualifier. A colon alone does NOT
        // make 12:30 into 24h. Context inference is bounded to the segment
        // containing this event's time phrase — it never bleeds across
        // " and "-separated events. Conflicting qualifiers ask.
        if let timePhrase = p.timePhrase, isBareHour(timePhrase) {
            if isUnambiguous24Hour(timePhrase: timePhrase, transcript: transcript) {
                // Unambiguous 24h — no issue.
            } else if let ctx = contextualMeridiem(transcript: transcript, timePhrase: timePhrase),
                      ctx != .conflicting {
                issues.append(ValidationIssue(eventIndex: eventIndex, kind: .correctedTime,
                    message: "Inferred \(ctx == .am ? "am" : "pm") from “\(ctx.label)” context in the same event — confirm the start time.",
                    blocking: false))
                evidenceParts.append("Inferred meridiem from \(ctx.label) context for time “\(timePhrase)”")
            } else if contextualMeridiem(transcript: transcript, timePhrase: timePhrase) == .conflicting {
                issues.append(ValidationIssue(eventIndex: eventIndex, kind: .ampmAmbiguous,
                    message: "Conflicting time-of-day context for \(timePhrase) — did you mean am or pm? Pick one below.",
                    blocking: true))
            } else {
                issues.append(ValidationIssue(eventIndex: eventIndex, kind: .ampmAmbiguous,
                    message: "Did you mean \(timePhrase)am or \(timePhrase)pm? Pick one below.",
                    blocking: true))
            }
        }

        // --- S5: hedged times.
        if let timePhrase = p.timePhrase {
            let lowered = timePhrase.lowercased()
            if lowered.contains("-ish") || lowered.hasSuffix("ish") || vagueWords.contains(where: { lowered.split(separator: " ").contains(Substring($0)) }) {
                issues.append(ValidationIssue(eventIndex: eventIndex, kind: .vague,
                    message: "“\(timePhrase)” is approximate — pick an exact start time.",
                    blocking: true))
            }
        }

        // --- Conflicting times inside one field without a correction marker.
        if let timePhrase = p.timePhrase, !containsCorrectionMarker(transcript),
           timePhrase.components(separatedBy: " and ").count > 1 {
            issues.append(ValidationIssue(eventIndex: eventIndex, kind: .conflictingTime,
                message: "Two times appeared without a correction — pick the one to use.",
                blocking: true))
        }
        // Correction: keep latest time in the field; validator already checked the
        // transcript marker. Preserve the original for provenance.
        if containsCorrectionMarker(transcript), let timePhrase = p.timePhrase {
            let parts = timePhrase.split(separator: ",")
            if parts.count > 1, let latest = parts.last {
                let latestText = latest.trimmingCharacters(in: .whitespacesAndNewlines)
                evidenceParts.append("Used corrected time “\(latestText)”; original wording was “\(timePhrase)”")
                p.timePhrase = latestText
            }
        }

        // --- Missing / negated / optional fields.
        if (p.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            p.title = nil
            issues.append(ValidationIssue(eventIndex: eventIndex, kind: .missingTitle,
                message: "What is this event called?", blocking: true))
        }
        if p.durationPhrase == nil {
            issues.append(ValidationIssue(eventIndex: eventIndex, kind: .missingDuration,
                message: "No duration stated — a 1-hour app default will be shown; edit it if needed.", blocking: false))
        }
        if containsNegation(transcript) {
            issues.append(ValidationIssue(eventIndex: eventIndex, kind: .negation,
                message: "A “not / no” phrase was kept as ordinary text — no location or detail was invented for it.",
                blocking: false))
        }

        // --- Location: person-vs-place + drop prompt (ask, never invent).
        if let location = p.location {
            if isLikelyPerson(location: location, transcript: transcript) {
                p.location = nil
                issues.append(ValidationIssue(eventIndex: eventIndex, kind: .personNotPlace,
                    message: "“\(location)” reads as a person, not a place — left as no location.", blocking: false))
            }
        } else if hasExplicitPlaceCue(transcript) {
            issues.append(ValidationIssue(eventIndex: eventIndex, kind: .locationPrompt,
                message: "Is there a location for this?", blocking: false))
        }

        // --- Optional-but-visible gaps: surfaced, never silently complete.
        if p.location == nil && !issues.contains(where: { $0.kind == .locationPrompt }) {
            issues.append(ValidationIssue(eventIndex: eventIndex, kind: .missingLocation,
                message: "No location stated — shown as an empty slot (no invented place).", blocking: false))
        }
        if p.datePhrase == nil {
            issues.append(ValidationIssue(eventIndex: eventIndex, kind: .noDate,
                message: "No day stated — an app default (today, or tomorrow if that time has passed) will be shown; edit it if needed.", blocking: false))
        }
        if p.timePhrase == nil {
            issues.append(ValidationIssue(eventIndex: eventIndex, kind: .noTime,
                message: "No time stated — pick a start time.", blocking: true))
        }
        return ValidatedPhrases(phrases: p, originalPhrases: input, issues: issues,
                                evidenceNote: evidenceParts.joined(separator: "; ").nilIfEmpty)
    }

    // MARK: - Cue checks (documented, limited to explicit signals)

    /// Pattern-based instruction-span *heuristic signal* (regex word patterns).
    /// This is NOT structural injection safety by itself and makes no NLI /
    /// completeness guarantee: the structural defences are no-tools, output is
    /// data only, grounding nulls ungrounded fields, and every draft needs
    /// explicit confirmation. Kept honest in copy; n is small.
    public static func containsInstructionLikeSpan(_ transcript: String) -> Bool {
        let patterns = [
            "(?i)\\bignore\\s+(all\\s+)?previous\\s+instructions\\b",
            "(?i)\\bdisregard\\s+(all\\s+)?(previous|prior)\\s+instructions\\b",
            "(?i)\\bset\\s+(the\\s+)?(title|date|time)\\s+to\\b[^.]*\\bwithout\\s+asking\\b"
        ]
        return patterns.contains { transcript.range(of: $0, options: .regularExpression) != nil }
    }

    public static func containsCorrectionMarker(_ transcript: String) -> Bool {
        transcript.range(of: "(?i)\\b(actually|make it|i mean|correction|instead|changed to|change it to)\\b",
                          options: .regularExpression) != nil
    }

    public static func containsFiller(_ transcript: String) -> Bool {
        transcript.range(of: "(?i)\\b(um|uh|er|erm|like)\\b", options: .regularExpression) != nil
    }

    public static func containsNegation(_ transcript: String) -> Bool {
        transcript.range(of: "(?i)\\b(not|no|don't|never|without)\\b", options: .regularExpression) != nil
    }

    static func hasExplicitPlaceCue(_ transcript: String) -> Bool {
        // Explicit "in/at + place" cues only; absence of a cue is never treated as proof.
        let patterns = [
            "(?i)\\b(in|at|near)\\s+the\\s+(um\\s+|uh\\s+)?[a-z]",          // "at the um cafe"
            "(?i)\\b(room|hall|building|office|studio|cafe|café|restaurant)\\s+\\w+",
            "(?i)\\b(studio|cafe|café)\\b\\s*$",
            "(?i)\\bat\\s+[A-Z]"                                            // "at Sturm"
        ]
        return patterns.contains { transcript.range(of: $0, options: .regularExpression) != nil }
    }

    private static func isLikelyPerson(location: String, transcript: String) -> Bool {
        // "Lunch with Alex" — a name introduced by "with" is a person, not a place.
        let pattern = "(?i)\\bwith\\s+\(NSRegularExpression.escapedPattern(for: location))\\b"
        return transcript.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Grounding

    /// Normalisation applied to BOTH sides of the grounding comparison so that
    /// harmless surface variants of the user's own words are not rejected:
    /// "3pm" ≡ "3 pm" (digit/meridiem-unit split), "p.m." ≡ "pm",
    /// "45min"/"45 mins"/"45 min" ≡ "45 minutes", and — 0.3.22 — a SPOKEN
    /// clock ≡ its digit form ("three o'clock" ≡ "3:00 pm", "half past
    /// three" ≡ "3:30 pm"). The spoken rewrite is value-exact (hour +
    /// minute + the app's own meridiem resolution, including the
    /// owner-approved daytime inference), so a model time that asserts a
    /// DIFFERENT clock ("4:00", or "3 am" against the inferred pm) never
    /// grounds. Only digit+known-unit boundaries are otherwise split and
    /// only known unit tokens are canonicalised — every other token is
    /// untouched, so the exact-number rule and ungrounded-word rejection
    /// are preserved (see GroundingNormalizationTests).
    static func normalizedForGrounding(_ text: String) -> String {
        var lowered = text.lowercased()
        // "p.m." / "a.m." (any spacing, trailing period optional) → "pm"/"am".
        lowered = lowered.replacingOccurrences(
            of: "\\b([ap])\\.\\s*m\\.?",
            with: "$1m",
            options: .regularExpression)
        // Split a digit from a following known unit/meridiem: "3pm" → "3 pm".
        lowered = lowered.replacingOccurrences(
            of: "(\\d)(?=(?:am|pm|hrs?|mins?|hours?|minutes?|h)\\b)",
            with: "$1 ",
            options: .regularExpression)
        // Spoken clock → canonical digit form (value-exact, both sides).
        lowered = SpokenClock.rewriteToDigitEquivalent(lowered)
        return lowered
    }

    /// Canonical duration-unit token so "45min"/"45 mins" ≡ "45 minutes"
    /// and "2h"/"2 hr" ≡ "2 hours". Identity for every other token.
    private static func canonicalUnit(_ token: String) -> String {
        switch token {
        case "h", "hr", "hrs": return "hours"
        case "min", "mins": return "minutes"
        default: return token
        }
    }

    /// Token-coverage check with harmless normalisation (case/punctuation/filler/
    /// stopwords/meridiem-spacing/unit-canonicalisation).
    public static func isGrounded(_ phrase: String, in transcript: String) -> Bool {
        let stopwords: Set<String> = ["the", "a", "an", "at", "on", "in", "for", "to", "of", "and", "um", "uh", "er", "erm", "like"]
        func tokens(_ s: String) -> [String] {
            normalizedForGrounding(s)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { canonicalUnit($0) }
                .filter { !$0.isEmpty && !stopwords.contains($0) }
        }
        let phraseTokens = Set(tokens(phrase))
        guard !phraseTokens.isEmpty else { return true }
        // Numbers must match exactly; words allow any-coverage (order-free).
        let transcriptTokens = Set(tokens(transcript))
        return phraseTokens.isSubset(of: transcriptTokens)
    }

    // MARK: - Time helpers

    public static func clockComponents(in phrase: String) -> (hour: Int, minute: Int)? {
        let lowered = phrase.lowercased()
        if lowered.contains("noon") || lowered.contains("midday") { return (12, 0) }
        if lowered.contains("midnight") { return (0, 0) }
        // h:mm am/pm | h:mm 24h | h am/pm
        if let m = firstMatch("(?i)\\b(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)\\b", in: phrase) {
            let h = Int(m.0) ?? 0; let min = Int(m.1 ?? "0") ?? 0
            var hour = h % 12; if (m.2 ?? "").lowercased() == "pm" { hour += 12 }
            return (hour, min)
        }
        if let m = firstMatch("\\b([01]?\\d|2[0-3]):([0-5]\\d)\\b", in: phrase),
           let h = Int(m.0), let min = Int(m.1 ?? "") { return (h, min) }
        return nil
    }

    public static func isBareHour(_ phrase: String) -> Bool {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.contains("noon") || trimmed.contains("midnight") { return false }
        // Exact bare forms: "2", "12:30", "2:00" with no am/pm and no 24h disambiguation.
        // An hour of 13–23 (or 0) with a colon is unambiguous 24h, not bare.
        guard let comps = bareHourComponents(trimmed) else { return false }
        if comps.hasColon, comps.hour > 12 || comps.hour == 0 { return false }
        return true
    }

    public static func bareHourComponents(_ phrase: String) -> (hour: Int, minute: Int, hasColon: Bool)? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = trimmed.split(separator: ":")
        guard parts.count == 1 || parts.count == 2,
              let hour = Int(parts[0]), (0...23).contains(hour) else { return nil }
        // Must be exactly digits (and digits:dd) — reject "2pm", "noon", etc.
        guard trimmed.range(of: "^\\d{1,2}(:\\d{2})?$", options: .regularExpression) != nil else { return nil }
        let minute = parts.count == 2 ? (Int(parts[1]) ?? -1) : 0
        guard (0...59).contains(minute) else { return nil }
        return (hour, minute, trimmed.contains(":"))
    }

    /// True when the bare clock is unambiguously 24h: hour 13–23/0 with a colon,
    /// or an explicit "24 hour time" / "24-hour" phrase in the phrase or the
    /// same-event segment of the transcript. `12:30` with a colon alone is NOT
    /// 24h — it stays ambiguous without context.
    public static func isUnambiguous24Hour(timePhrase: String, transcript: String) -> Bool {
        if let comps = bareHourComponents(timePhrase), comps.hasColon, comps.hour > 12 || comps.hour == 0 {
            return true
        }
        let haystack = (timePhrase + " " + segmentScope(transcript: transcript, timePhrase: timePhrase)).lowercased()
        return haystack.contains("24 hour") || haystack.contains("24-hour") || haystack.contains("24hour")
    }

    /// The transcript segment that belongs to the event owning `timePhrase`:
    /// split on " and " (the multi-event separator) and pick the segment that
    /// mentions this time phrase verbatim; fall back to the whole transcript
    /// for a single segment. Never let a qualifier from another event bleed in.
    public static func segmentScope(transcript: String, timePhrase: String) -> String {
        let segments = transcript.components(separatedBy: " and ")
        guard segments.count > 1 else { return transcript }
        let needle = timePhrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Word-boundary match so "2" does not match inside "12:30".
        let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: needle))\\b"
        if let hit = segments.first(where: { $0.range(of: pattern, options: .regularExpression) != nil }) { return hit }
        // Time phrase not found verbatim (the model may have normalised
        // spacing, e.g. "3pm" → "3 pm"): retry with whitespace-insensitive
        // matching so the same-event scope is still located. Only this segment
        // search is widened — the grounding check is unchanged.
        let collapsedNeedle = needle.replacingOccurrences(of: " ", with: "")
        if !collapsedNeedle.isEmpty {
            for segment in segments {
                let collapsed = segment.lowercased().replacingOccurrences(of: " ", with: "")
                if collapsed.contains(collapsedNeedle) { return segment }
            }
        }
        // Still not found: only use the
        // whole transcript when there is a single distinct qualifier, checked
        // by the caller — for multi-segment transcripts, return empty so no
        // qualifier is inferred across events.
        return ""
    }

    /// Meridiem inferred from the same-event segment, or nil when there is no
    /// qualifier, or `.conflicting` when qualifiers disagree.
    public static func contextualMeridiem(transcript: String, timePhrase: String) -> ContextualMeridiem? {
        let scope = segmentScope(transcript: transcript, timePhrase: timePhrase).lowercased()
        guard !scope.isEmpty else { return nil }
        let has24 = scope.contains("24 hour") || scope.contains("24-hour") || scope.contains("24hour")
        if has24 { return .twentyFour }
        let pm = scope.range(of: "(?i)\\b(noon|midday|afternoon)\\b", options: .regularExpression) != nil
        let am = scope.range(of: "(?i)\\b(morning|midnight)\\b", options: .regularExpression) != nil
        if pm && am { return .conflicting }
        if pm { return .pm }
        if am { return .am }
        return nil
    }

    private static func containsTimeOrDurationToken(_ phrase: String) -> Bool {
        phrase.range(of: "(?i)(\\bat\\s+\\d|for\\s+\\d+\\s*(minutes?|hours?)|\\b\\d+\\s*(minutes?|hours?|minutes?|hours?)\\b)",
                     options: .regularExpression) != nil
    }

    private static func hasTwoClockTimes(_ transcript: String) -> Bool {
        let pattern = "(?i)\\b(\\d{1,2})(?::\\d{2})?\\s*(am|pm|noon|midnight)?\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let matches = regex.matches(in: transcript, range: NSRange(transcript.startIndex..., in: transcript))
        return matches.count >= 2
    }

    private static func firstMatch(_ pattern: String, in text: String) -> (String, String?, String?)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        func group(_ index: Int) -> String? {
            guard index < match.numberOfRanges else { return nil }
            let r = match.range(at: index)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return nil }
            return String(text[swiftRange])
        }
        // Group 0 fallback: for anchored bare-hour patterns the full match is the value.
        let g1 = group(1) ?? (match.range(at: 0).location != NSNotFound ? String(text[Range(match.range(at: 0), in: text)!]) : nil)
        guard let first = g1 else { return nil }
        return (first, group(2), group(3))
    }
}
