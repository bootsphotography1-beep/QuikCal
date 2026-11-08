import Foundation

// MARK: - Shared title/notes normalizer (0.3.20)
//
// ONE implementation of conversational-cleanup at the STRUCTURED EXTRACTION
// BOUNDARY, used by BOTH extraction paths:
//  - the deterministic parser (`EventParser.extractTitleAndNotes`), and
//  - the local-model phrase pipeline (`PhrasePipeline.compose` normalizes
//    the model's raw `title`/`notes` fields before validation).
// It never runs on rendered UI, saved output, or user edits made on the
// confirmation card — manual edits are never re-normalized.
//
// Honesty rules:
//  - Only CONVERSATIONAL COMMAND WRAPPER and SCHEDULING phrases are
//    stripped; the user's actual subject keeps its own words.
//  - A cue-attached time-of-day phrase ("due morning", "in the evening")
//    is scheduling context, NOT a clock time: it is consumed so it never
//    pollutes the title, and it is NEVER resolved to an invented start.
//    The existing resolver clarification / default-marker policy still
//    applies when no clock time was stated.
//  - A time-of-day word that is part of a meaningful name ("Morning Pages",
//    "Movie night") has no scheduling cue and is preserved.
//  - An explicit user-quoted/called title is preserved VERBATIM.
//  - Notes keep only useful user-supplied event context: correction
//    scaffolding ("9 a.m. instead of …") is dropped, and the missing
//    correction target is never inferred (date/time fields are untouched).
//  - If cleaning leaves an empty title, the caller keeps nil so the
//    validator asks "What is this event called?" — never a hallucinated
//    substitute.

public enum TitleNotesNormalizer: Sendable {

    // MARK: - Request boilerplate (command wrapper)

    /// Leading conversational command wrapper and trailing calendar-target
    /// tails. General phrasing, case-insensitive; safe to re-run (idempotent).
    ///
    /// Leading: any mix of polite lead-ins ("please", "can/could/would you",
    /// "kindly", "go ahead and"), an optional intent phrase ("I need/want/
    /// 'd/would like to"), the command verb (add/schedule/create/make/book/
    /// put/set up/plan/remind me to), and a possessive "my" that only wraps
    /// the command ("add my X" = "add X to my calendar" — a possessive
    /// elsewhere, e.g. "water MY plants", is NOT touched).
    /// Trailing: "on/to/in my calendar/schedule/agenda", "please", "thanks".
    public static func stripRequestBoilerplate(_ text: String) -> String {
        var out = text
        let leading = "^(?:please\\s+|can\\s+you\\s+|could\\s+you\\s+|would\\s+you\\s+|kindly\\s+|go\\s+ahead\\s+and\\s+)*"
            + "(?:i\\s+(?:need|want|would\\s+like|'d\\s+like)\\s+to\\s+)?"
            + "(?:add|schedule|create|make|book|put|set\\s+up|plan|remind\\s+me\\s+to)\\s+"
            + "(?:my\\s+)?"
        if let regex = try? NSRegularExpression(pattern: leading, options: [.caseInsensitive]) {
            out = regex.stringByReplacingMatches(
                in: out, options: [], range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        let trailing = "(?:[,\\s]*(?:on|to|in)\\s+(?:my|the|our)\\s+(?:calendar|cal|schedule|agenda))"
            + "(?:[,\\s]*(?:please|thanks|thank\\s+you))?[\\s.,!]*$"
            + "|[,\\s]*(?:please|thanks|thank\\s+you)[\\s.,!]*$"
        if let regex = try? NSRegularExpression(pattern: trailing, options: [.caseInsensitive]) {
            out = regex.stringByReplacingMatches(
                in: out, options: [], range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Scheduling time-of-day phrases

    /// Time-of-day words that belong to SCHEDULING, not to the event's
    /// name: a day part attached to a cue ("due morning", "at night", "in
    /// the evening", "by afternoon") is consumed so it never lands in the
    /// title. It is deliberately NOT converted to a clock time — "morning"
    /// alone is ambiguous and no calendar start is ever invented from it.
    /// A time-of-day word WITHOUT a cue ("Morning Pages", "Movie night",
    /// "morning run") is meaningful user wording and is preserved.
    public static func stripSchedulingTimeOfDayPhrases(_ text: String) -> String {
        var out = text
        let patterns = [
            "\\b(?:due|at|by|around|during)\\s+(?:the\\s+)?(?:morning|afternoon|evening|night)\\b",
            "\\bin\\s+the\\s+(?:morning|afternoon|evening|night)\\b"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                out = regex.stringByReplacingMatches(
                    in: out, options: [], range: NSRange(out.startIndex..., in: out), withTemplate: " ")
            }
        }
        return out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Notes cleanup

    /// Drops CORRECTION SCAFFOLDING clauses from notes: a comma/semicolon
    /// clause that contains BOTH a correction marker ("instead",
    /// "actually", "make it", "i mean", "correction", "changed to") AND a
    /// clock token ("9 a.m.", "12:30", "noon") is time-correction wording,
    /// not event context. Real user detail that merely contains "instead"
    /// ("bring the report instead of the slides") has no clock token and
    /// is kept. The missing correction target is never inferred —
    /// date/time fields are untouched by this cleanup.
    public static func stripCorrectionScaffolding(_ notes: String) -> String {
        let clockToken = "\\b\\d{1,2}(?::\\d{2})?\\s*(?:a\\.?m\\.?|p\\.?m\\.?)\\b"
            + "|\\b\\d{1,2}:\\d{2}\\b|\\b(?:noon|midnight)\\b"
        let correctionMarker = "\\b(?:actually|make\\s+it|i\\s+mean|correction|instead|changed\\s+to|change\\s+it\\s+to)\\b"
        let kept = notes
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { clause in
                guard !clause.isEmpty else { return false }
                let hasClock = clause.range(of: clockToken, options: .regularExpression) != nil
                let hasMarker = clause.range(of: correctionMarker, options: [.regularExpression, .caseInsensitive]) != nil
                return !(hasClock && hasMarker)
            }
        return kept.joined(separator: " ")
    }

    // MARK: - Tidy

    /// Strips leading/trailing filler and preposition words from a clause.
    /// "due" is a trailing filler: after the date phrase was extracted,
    /// a dangling "due" ("homework due tomorrow" → "homework due") is
    /// scheduling scaffolding, not the subject.
    public static func stripEdgeFillers(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        let leadingFillers: Set<String> = ["just", "at", "on", "in", "for", "by", "around", "from", "the", "a", "an", "to", "about"]
        let trailingFillers: Set<String> = ["at", "on", "in", "for", "by", "around", "from", "to", "about", "due"]
        while let first = words.first, leadingFillers.contains(first.lowercased()) {
            words.removeFirst()
        }
        while let last = words.last, trailingFillers.contains(last.lowercased()) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// Cleans a user phrase for display: collapses whitespace, strips edge
    /// fillers/punctuation, capitalizes the first letter. Never truncates.
    public static func tidy(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = stripEdgeFillers(text)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
        guard let first = text.first else { return text }
        return String(first).uppercased() + String(text.dropFirst())
    }

    // MARK: - Model-path normalization (structured extraction boundary)

    /// Normalizes a MODEL-extracted title against the transcript.
    /// - An explicit user-quoted/called title is preserved VERBATIM.
    /// - Otherwise the conversational command wrapper and cue-attached
    ///   scheduling phrases are stripped, then tidied.
    /// - Returns nil when nothing subject-like remains — the caller keeps
    ///   the title empty so the validator asks honestly (never invents).
    public static func normalizedModelTitle(_ title: String, transcript: String) -> String? {
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if isExplicitlyNamed(raw, in: transcript) {
            return raw
        }
        var cleaned = stripRequestBoilerplate(raw)
        cleaned = stripSchedulingTimeOfDayPhrases(cleaned)
        cleaned = tidy(cleaned)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Normalizes MODEL-extracted notes: only useful user-supplied event
    /// context survives. Correction scaffolding clauses are dropped, a
    /// leading command wrapper is stripped, and a notes value that merely
    /// duplicates the cleaned title (a raw-request dump) is dropped too.
    /// Returns nil when no useful detail remains — never invented filler.
    public static func normalizedModelNotes(_ notes: String?, transcript: String, cleanedTitle: String?) -> String? {
        guard let raw = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        var cleaned = stripCorrectionScaffolding(raw)
        cleaned = stripRequestBoilerplate(cleaned)
        cleaned = tidy(cleaned)
        guard !cleaned.isEmpty else { return nil }
        if let title = cleanedTitle, !title.isEmpty,
           cleaned.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return nil
        }
        return cleaned
    }

    /// Normalizes a whole raw model output in place (title + notes per
    /// event) at the structured extraction boundary, before validation.
    public static func normalize(_ raw: RawPhraseOutput, transcript: String) -> RawPhraseOutput {
        RawPhraseOutput(events: raw.events.map { event in
            var e = event
            let cleanedTitle = e.title.flatMap { normalizedModelTitle($0, transcript: transcript) }
            // A title that cleans to empty stays empty: the validator's
            // honest missing-title ask takes over — no hallucinated name.
            e.title = cleanedTitle
            e.notes = normalizedModelNotes(e.notes, transcript: transcript, cleanedTitle: cleanedTitle)
            return e
        })
    }

    // MARK: - Explicit-title detection

    /// True when the transcript explicitly names this title ("an event
    /// called X", "titled X", "named X") or quotes it ("X" / “X”) — the
    /// user's intentional text must survive cleanup VERBATIM.
    private static func isExplicitlyNamed(_ title: String, in transcript: String) -> Bool {
        // "called/titled/named X" — X runs until a scheduling cue or punctuation.
        let cue = "(?i)\\b(?:titled|called|named)\\s+([^,.;!?]+)"
        guard let regex = try? NSRegularExpression(pattern: cue) else { return false }
        let range = NSRange(transcript.startIndex..., in: transcript)
        for match in regex.matches(in: transcript, options: [], range: range) {
            guard match.numberOfRanges > 1 else { continue }
            let group = match.range(at: 1)
            guard group.location != NSNotFound, let swiftRange = Range(group, in: transcript) else { continue }
            let captured = String(transcript[swiftRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \u{201C}\u{201D}\"'`,.;:-"))
            // Keep a title that itself matches the full captured phrase. If
            // the model returned just the named subject, remove the complete
            // scheduling tail beginning at its first date/time cue (e.g.
            // "Morning Pages tomorrow at 9am on Tuesday"), not just its final
            // fragment. The captured title itself is never rewritten, and
            // ordinary name text such as "at Home" is not a recognized tail.
            if !captured.isEmpty, sameName(captured, title) {
                return true
            }
            let schedulingTail = "(?i)\\s+(?:today|tomorrow|tonight|(?:on|next|this|coming)\\s+\\w+|at\\s+\\d{1,2}(?::\\d{2})?\\s*(?:a\\.?m\\.?|p\\.?m\\.?)?).*$"
            let named = captured.replacingOccurrences(
                of: schedulingTail, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \u{201C}\u{201D}\"'`,.;:-"))
            if !named.isEmpty, sameName(named, title) {
                return true
            }
        }
        // Quoted anywhere in the transcript: "my 'Japanese homework' …".
        let escaped = NSRegularExpression.escapedPattern(for: title)
        let quote = "(?i)[\"“‘']\\s*\(escaped)\\s*[\"”’']"
        if title.rangeOfCharacter(from: CharacterSet(charactersIn: "\"“”‘’,.;")) == nil,
           transcript.range(of: quote, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Case/punctuation-insensitive name equality.
    private static func sameName(_ a: String, _ b: String) -> Bool {
        let cleaned: (String) -> String = { text in
            text.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: " \u{201C}\u{201D}\"'`,.;:-"))
        }
        return cleaned(a) == cleaned(b)
    }
}
