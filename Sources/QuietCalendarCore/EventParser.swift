import Foundation

/// The result of pulling structured fields out of free text, before defaults are applied.
public enum IntentExtraction: Sendable, Equatable {
    case intent(EventIntent)
    case needsClarification(String)
    case failed(String)
}

/// Deterministic, offline natural-language parser for short calendar notes.
///
/// It extracts a title, an *explicit* date (never invented), an explicit clock time,
/// an optional duration and an optional location. All defaulting and validation of the
/// resulting start/end lives in `EventDraftResolver`, shared with the optional model path.
public final class EventParser {
    public let calendar: Calendar
    private let nowProvider: () -> Date

    public init(calendar: Calendar = .current, nowProvider: @escaping () -> Date = { Date() }) {
        self.calendar = calendar
        self.nowProvider = nowProvider
    }

    public var now: Date { nowProvider() }

    public func parse(_ input: String, now: Date? = nil, forcingPM: Bool? = nil) -> ParseResult {
        let instant = now ?? self.now
        switch extractIntent(input, now: instant, forcingPM: forcingPM) {
        case .intent(let intent):
            return EventDraftResolver(calendar: calendar).resolve(intent, now: instant)
        case .needsClarification(let message):
            return .needsClarification(message)
        case .failed(let message):
            return .failed(message)
        }
    }

    public func extractIntent(_ input: String, now instant: Date? = nil, forcingPM: Bool? = nil) -> IntentExtraction {
        let now = instant ?? self.now
        var working = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else {
            return .failed("Type something to add to your calendar.")
        }
        guard working.count <= 500 else {
            return .failed("That is too long for one note — keep it under 500 characters.")
        }

        if let relative = Self.relativeStartClarification(in: working) {
            return .needsClarification(relative)
        }

        // Reminder BEFORE duration: "remind me 15 minutes before" contains a
        // duration-shaped span that must not be eaten as the event duration.
        // Spoken lead times ("remind me three hours before") are equally
        // reminder wording — never a spoken CLOCK for the event start.
        let reminder = extractReminder(from: &working, cueRequired: true)
        if let clarification = reminder.clarification {
            return .needsClarification(clarification)
        }
        let duration = extractDuration(from: &working)
        let date = extractDate(from: &working, now: now)
        if let clarification = date.clarification {
            return .needsClarification(clarification)
        }
        if date.components == nil, let cue = Self.unresolvedDateCue(in: working) {
            return .needsClarification("I couldn't turn “\(cue)” into a specific day. Say a day like “tomorrow” or “Friday”.")
        }

        let time = extractTime(from: &working, forcingPM: forcingPM,
                               dayPartContext: date.consumedTimeOfDayTail)
        if let clarification = time.clarification {
            return .needsClarification(clarification)
        }

        // "Tonight at three" means 03:00 on the coming night, which is the
        // next calendar day when expressed as an early-morning clock. This
        // rollover is specific to the explicit "tonight" date cue; "today
        // at three" remains on today and is rejected as past when appropriate.
        var resolvedDate = date.components
        if date.isTonight, let hour = time.components?.hour, (0...5).contains(hour) {
            resolvedDate = dayComponents(offset: 1, from: now)
        }

        let location = extractLocation(from: &working)
        let titleNotes = extractTitleAndNotes(from: working)

        return .intent(
            EventIntent(
                title: titleNotes.title.isEmpty ? "Event" : titleNotes.title,
                date: resolvedDate,
                time: time.components,
                durationSeconds: duration,
                location: location,
                notes: titleNotes.notes,
                reminderLeadMinutes: reminder.leadMinutes,
                timeNeedsAMPMConfirmation: time.needsAMPMConfirmation,
                timeInferredDaytime: time.inferredDaytime,
                timeIsNumericBareHour: time.numericBareHour
            )
        )
    }

    // MARK: - Phrase re-parsing (for the model phrase pipeline; shares the grammar)

    /// Parses an already-extracted date *phrase* with the same grammar as above.
    public func parseDatePhrase(_ phrase: String, now: Date) -> (components: DateComponents?, clarification: String?) {
        var working = phrase
        let result = extractDate(from: &working, now: now)
        return (result.components, result.clarification)
    }

    /// Parses an already-extracted time *phrase* (noon/midnight/am-pm/24h).
    public func parseTimePhrase(_ phrase: String) -> (components: DateComponents?, clarification: String?) {
        var working = phrase
        let result = extractTime(from: &working)
        return (result.components, result.clarification)
    }

    /// Parses an already-extracted duration *phrase* ("60 minutes", "an hour"…).
    public func parseDurationPhrase(_ phrase: String) -> Int? {
        var working = phrase
        return extractDuration(from: &working)
    }

    /// Parses an already-extracted reminder *phrase* ("15 minutes before",
    /// "remind me an hour before"…). Cue-less lead phrases are accepted here
    /// because the phrase is isolated (no relative-start ambiguity with an
    /// event clock time). Returns the lead minutes, or a clarification when
    /// the phrase is malformed / unsupported / beyond provider limits.
    public func parseReminderPhrase(_ phrase: String) -> (leadMinutes: Int?, clarification: String?) {
        var working = phrase
        let result = extractReminder(from: &working, cueRequired: false)
        return (result.leadMinutes, result.clarification)
    }

    // MARK: - Regex helpers

    private func match(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        return regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text))
    }

    private func capture(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private func remove(_ match: NSTextCheckingResult, from text: inout String) {
        guard let range = Range(match.range, in: text) else { return }
        text.replaceSubrange(range, with: " ")
    }

    /// Removes an arbitrary matched range (spoken-clock spans carry their
    /// own NSRange, not an NSTextCheckingResult).
    private func removeRange(_ range: NSRange, from text: inout String) {
        guard let swiftRange = Range(range, in: text) else { return }
        text.replaceSubrange(swiftRange, with: " ")
    }

    /// True when the spoken-clock match lies inside an explicit user-named
    /// title ("an event called Three Oclock Club", "meeting titled Three
    /// O’Clock Club") or a double/curly-quoted span — the words are the
    /// event's NAME there, not a clock time. The named span is trimmed at
    /// the first trailing scheduling cue (on/at/by/around/from/in/to/for/
    /// next/tomorrow…) so a REAL clock after the name still parses.
    private static func spokenClockLiesInsideExplicitTitle(_ spoken: SpokenClockMatch, in text: String) -> Bool {
        let nsText = text as NSString

        // Quoted spans (straight + curly double quotes; single quotes are
        // skipped on purpose — apostrophes collide with "o'clock").
        let quotePairs: [(open: String, close: String)] = [
            ("\"", "\""), ("\u{201C}", "\u{201D}")
        ]
        for pair in quotePairs {
            let pattern = NSRegularExpression.escapedPattern(for: pair.open)
                + "[^" + NSRegularExpression.escapedPattern(for: pair.open)
                + NSRegularExpression.escapedPattern(for: pair.close) + "]+"
                + NSRegularExpression.escapedPattern(for: pair.close)
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for hit in regex.matches(in: text, options: [], range: range) {
                if NSIntersectionRange(hit.range, spoken.range).length > 0 { return true }
            }
        }

        // Explicit-name spans: "(titled|called|named) X" where X runs to
        // punctuation, trimmed at a trailing scheduling cue.
        let namedPattern = "(?i)\\b(?:titled|called|named)\\s+([^,.;!?]+)"
        guard let regex = try? NSRegularExpression(pattern: namedPattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        for hit in regex.matches(in: text, options: [], range: range) where hit.numberOfRanges > 1 {
            let captured = hit.range(at: 1)
            guard captured.location != NSNotFound else { continue }
            let original = nsText.substring(with: captured)
            var named = original
            // Trim the first trailing scheduling cue so "called X on
            // Tuesday at three" keeps "at three" a REAL clock.
            if let cueRegex = try? NSRegularExpression(
                pattern: "(?i)\\s+(?:on|at|by|around|from|in|to|for|next|tomorrow|today|tonight)\\b.*$") {
                let namedRange = NSRange(named.startIndex..., in: named)
                named = cueRegex.stringByReplacingMatches(
                    in: named, options: [], range: namedRange, withTemplate: "")
            }
            let trimmed = named.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // The cue trim only removes a suffix, so the trimmed name still
            // starts at the captured span's first non-whitespace character.
            let leadingSpaces = original.prefix(while: { $0 == " " }).utf16.count
            let namedSpan = NSRange(
                location: captured.location + leadingSpaces,
                length: trimmed.utf16.count)
            if NSIntersectionRange(namedSpan, spoken.range).length > 0 { return true }
        }
        return false
    }

    /// Removes a matched DATE phrase plus ONE time-of-day word directly
    /// following it ("tomorrow morning", "Friday night", "today evening")
    /// — the day part is date-scoped scheduling context and must never land
    /// in the title (0.3.20). It is NEVER resolved to a clock time by
    /// itself; the resolver's existing no-clock policy (clarification /
    /// labelled default) still applies. Returns the consumed day-part word
    /// so a later clock in the same note can honor it ("tomorrow morning
    /// at three o'clock" → the user's explicit morning wins).
    @discardableResult
    private func removeDatePhraseWithTimeOfDayTail(_ match: NSTextCheckingResult, from text: inout String) -> String? {
        let tailPattern = "\\s*(morning|afternoon|evening|night)\\b"
        guard let regex = try? NSRegularExpression(pattern: tailPattern, options: [.caseInsensitive]) else {
            remove(match, from: &text)
            return nil
        }
        let searchStart = NSMaxRange(match.range)
        guard searchStart <= text.utf16.count else {
            remove(match, from: &text)
            return nil
        }
        if let tail = regex.firstMatch(
            in: text, options: [.anchored],
            range: NSRange(location: searchStart, length: text.utf16.count - searchStart)) {
            // Capture the day-part word BEFORE the replacement shifts indices.
            var tailWord: String? = nil
            if tail.numberOfRanges > 1, let tailWordRange = Range(tail.range(at: 1), in: text) {
                tailWord = String(text[tailWordRange])
            }
            if let full = Range(NSUnionRange(match.range, tail.range), in: text) {
                text.replaceSubrange(full, with: " ")
            } else {
                remove(match, from: &text)
            }
            return tailWord
        }
        remove(match, from: &text)
        return nil
    }

    private static func firstMatchString(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    // MARK: - Unsupported relative phrasing

    private static func relativeStartClarification(in text: String) -> String? {
        let pattern = "\\bin\\s+(?:a|an|one|two|three|four|five|\\d+)\\s+(?:minutes?|mins?|hours?|hrs?|days?|weeks?)\\b"
        guard let phrase = firstMatchString(pattern, in: text) else { return nil }
        return "Relative times like “\(phrase)” aren't supported yet — use a clock time like 3pm."
    }

    private static func unresolvedDateCue(in text: String) -> String? {
        let patterns = [
            "\\bnext\\s+(?:week|month|year)\\b",
            "\\bweekend\\b",
            "\\bend\\s+of\\s+(?:the\\s+)?(?:week|month)\\b",
            "\\bthe\\s+\\d{1,2}(?:st|nd|rd|th)\\b"
        ]
        for pattern in patterns {
            if let phrase = firstMatchString(pattern, in: text) { return phrase }
        }
        return nil
    }

    // MARK: - Reminder lead time

    private struct ReminderExtraction {
        var leadMinutes: Int?
        var clarification: String?
    }

    /// Reminder cue words. Required in the full-transcript path so a bare
    /// "15 minutes before 3pm" (a relative START, which the parser does not
    /// support) is never mistaken for a reminder; optional for isolated
    /// reminder phrases from the model path.
    private static let reminderCue = "(?:remind\\s+me|alert\\s+me|with\\s+(?:an?\\s+)?reminder|a\\s+reminder|reminder)"

    /// Spoken numbers ("five", "twenty", "forty five", "a hundred").
    private static let numberWordPattern =
        "((?:an?|one)\\s+hundred|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|"
        + "fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"
        + "(?:[\\s-]+(one|two|three|four|five|six|seven|eight|nine))?"

    private static func numberWordsValue(_ first: String, _ second: String?) -> Int? {
        let smallNumbers: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
            "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
            "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
        ]
        let tens: [String: Int] = [
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
            "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
        ]
        let firstValue = first.lowercased()
        if firstValue.hasSuffix("hundred") { return 100 }
        if let second {
            guard let tensValue = tens[firstValue],
                  let onesValue = smallNumbers[second.lowercased()] else { return nil }
            return tensValue + onesValue
        }
        return smallNumbers[firstValue] ?? tens[firstValue]
    }

    /// Extracts ONE reminder lead time ("remind me N minutes/hours before")
    /// and removes the phrase so it never pollutes the title or duration.
    ///
    /// Honest semantics: one explicit reminder per event (the draft model
    /// carries one lead time). Multiple DISTINCT stated lead times are
    /// ambiguous and ask rather than silently picking one; repeated equal
    /// values are fine. Unsupported units (days), malformed/negative
    /// numbers, and values beyond the provider limit (4 weeks) ask too —
    /// nothing is silently clamped or dropped.
    private func extractReminder(from text: inout String, cueRequired: Bool) -> ReminderExtraction {
        let cue = cueRequired ? Self.reminderCue + "\\s+" : "(?:" + Self.reminderCue + "\\s+)?"
        let maxLead = EventDraftResolver.maximumReminderLeadMinutes

        // Unsupported units: days/weeks are not reminder lead units.
        if let m = match("\\b" + cue + "(?:(?:an?|one|two|three|\\d+)\\s*)?(?:days?|weeks?)\\s+before\\b", in: text) {
            remove(m, from: &text)
            return ReminderExtraction(
                leadMinutes: nil,
                clarification: "Reminders can only be set minutes or hours before an event (up to 4 weeks). Say a time like “remind me 30 minutes before”.")
            }
        // Malformed: negative sign, or a bare number with no unit.
        if let m = match("\\b" + cue + "([-−]\\s*\\d+(?:\\.\\d+)?)\\s*(?:minutes?|mins?|hours?|hrs?|m|h)?\\s*before\\b", in: text) {
            remove(m, from: &text)
            return ReminderExtraction(
                leadMinutes: nil,
                clarification: "A reminder time can’t be negative — say “remind me 15 minutes before”.")
        }
        if let m = match("\\b" + cue + "(\\d+)\\s+before\\b", in: text) {
            remove(m, from: &text)
            return ReminderExtraction(
                leadMinutes: nil,
                clarification: "Include the unit in the reminder time — for example “remind me 15 minutes before”.")
        }

        // Known lead-time phrases, most specific first. Each fully validates
        // before its match is consumed; all matches are collected so repeated
        // or conflicting reminders can be handled honestly.
        let leadPhrases: [(String, (NSTextCheckingResult, String) -> Int?)] = [
            // "an hour and a half before" / "one and a half hours before" → 90
            ("\\b" + cue + "(?:an?\\s+hour\\s+and\\s+a\\s+half|one\\s+and\\s+a\\s+half\\s+hours?)\\s+before\\b",
             { _, _ in 90 }),
            ("\\b" + cue + "1\\.5\\s*(?:hours?|hrs?|h)\\s+before\\b", { _, _ in 90 }),
            // "half an hour before" → 30
            ("\\b" + cue + "half\\s+an?\\s+hour\\s+before\\b", { _, _ in 30 }),
            // "an hour before" / "one hour before" → 60
            ("\\b" + cue + "(?:an?|one)\\s+hours?\\s+before\\b", { _, _ in 60 }),
            // "a minute before" / "one minute before" → 1
            ("\\b" + cue + "(?:a|one)\\s+minutes?\\s+before\\b", { _, _ in 1 }),
            // "N hours M minutes before" — hours converted to minutes once here.
            ("\\b" + cue + "(\\d+)\\s*(?:hours?|hrs?|h)\\s*(?:and\\s*)?(\\d+)\\s*(?:minutes?|mins?)\\s+before\\b",
             { m, text in
                 guard let h = Self.captureNumber(m, at: 1, in: text),
                       let mins = Self.captureNumber(m, at: 2, in: text) else { return nil }
                 return h * 60 + mins
             }),
            // "N[.N] hours before" — converted to minutes once, rounded.
            ("\\b" + cue + "(\\d+(?:\\.\\d+)?)\\s*(?:hours?|hrs?|h)\\s+before\\b",
             { m, text in
                 guard let h = Self.captureDouble(m, at: 1, in: text) else { return nil }
                 return Int((h * 60).rounded())
             }),
            // "N minutes before"
            ("\\b" + cue + "(\\d+)\\s*(?:minutes?|mins?|m)\\s+before\\b",
             { m, text in Self.captureNumber(m, at: 1, in: text) }),
            // Spoken numbers with hours ("five hours before").
            ("\\b" + cue + Self.numberWordPattern + "\\s*(?:hours?|hrs?)\\s+before\\b",
             { m, text in
                 guard let words = Self.captureWords(m, at: 1, secondAt: 2, in: text),
                       let value = Self.numberWordsValue(words.0, words.1) else { return nil }
                 return value * 60
             }),
            // Spoken numbers with minutes ("fifteen minutes before").
            ("\\b" + cue + Self.numberWordPattern + "\\s*(?:minutes?|mins?)\\s+before\\b",
             { m, text in
                 guard let words = Self.captureWords(m, at: 1, secondAt: 2, in: text) else { return nil }
                 return Self.numberWordsValue(words.0, words.1)
             })
        ]

        var leads: [Int] = []
        for (pattern, value) in leadPhrases {
            while let m = match(pattern, in: text) {
                guard let minutes = value(m, text) else { break }
                remove(m, from: &text)
                leads.append(minutes)
                if leads.count >= 4 { break }
            }
        }

        if leads.isEmpty { return ReminderExtraction(leadMinutes: nil, clarification: nil) }
        let distinct = Set(leads)
        if distinct.count > 1 {
            return ReminderExtraction(
                leadMinutes: nil,
                clarification: "You mentioned more than one reminder time — keep one, like “remind me 15 minutes before”.")
        }
        guard let lead = leads.first else {
            return ReminderExtraction(leadMinutes: nil, clarification: nil)
        }
        guard (0...maxLead).contains(lead) else {
            return ReminderExtraction(
                leadMinutes: nil,
                clarification: "That reminder is too far ahead — reminders can be at most 4 weeks (28 days) before an event. Try a shorter time like “remind me 2 hours before”.")
        }
        return ReminderExtraction(leadMinutes: lead, clarification: nil)
    }

    private static func captureNumber(_ match: NSTextCheckingResult, at index: Int, in text: String) -> Int? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return Int(text[swiftRange])
    }

    private static func captureDouble(_ match: NSTextCheckingResult, at index: Int, in text: String) -> Double? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return Double(text[swiftRange])
    }

    private static func captureWords(_ match: NSTextCheckingResult, at index: Int, secondAt: Int, in text: String) -> (String, String?)? {
        func word(_ i: Int) -> String? {
            guard i < match.numberOfRanges else { return nil }
            let range = match.range(at: i)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }
        guard let first = word(index) else { return nil }
        return (first, word(secondAt))
    }

    // MARK: - Duration

    private func extractDuration(from text: inout String) -> Int? {
        // Longest, most specific phrases first.
        let phrases: [(String, Int)] = [
            ("\\b(?:for\\s+)?(?:an?\\s+hour\\s+and\\s+a\\s+half|one\\s+and\\s+a\\s+half\\s+hours?)\\b", 5400),
            ("\\b(?:for\\s+)?1\\.5\\s*(?:hours?|hrs?|h)\\b", 5400),
            ("\\b(?:for\\s+)?half\\s+an?\\s+hour\\b", 1800),
            ("\\b(?:for\\s+)?(?:an?|one)\\s+hours?\\b", 3600),
            ("\\b(?:for\\s+)?(?:a|one)\\s+minute\\b", 60)
        ]
        for (pattern, seconds) in phrases {
            if let match = match(pattern, in: text) {
                remove(match, from: &text)
                return seconds
            }
        }

        // "1 hour 30 minutes"
        if let match = match("\\b(?:for\\s+)?(\\d+)\\s*(?:hours?|hrs?)\\s*(?:and\\s*)?(\\d+)\\s*(?:minutes?|mins?)\\b", in: text),
           let hours = capture(match, 1, text).flatMap(Int.init),
           let minutes = capture(match, 2, text).flatMap(Int.init) {
            remove(match, from: &text)
            return hours * 3600 + minutes * 60
        }

        if let match = match("\\b(?:for\\s+)?(\\d+(?:\\.\\d+)?)\\s*(?:hours?|hrs?|h)\\b", in: text),
           let value = capture(match, 1, text).flatMap(Double.init) {
            remove(match, from: &text)
            return Int((value * 3600).rounded())
        }

        if let match = match("\\b(?:for\\s+)?(\\d+)\\s*(?:minutes?|mins?|m)\\b", in: text),
           let minutes = capture(match, 1, text).flatMap(Int.init) {
            remove(match, from: &text)
            return minutes * 60
        }

        // Spoken durations (0.3.22): "for three hours", "twenty five
        // minutes" — the same word-number vocabulary the reminder grammar
        // already uses. A unit word always marks a DURATION, never a
        // spoken clock start ("three hours" is never 3am).
        if let match = match("\\b(?:for\\s+)?" + Self.numberWordPattern + "\\s*(?:hours?|hrs?)\\b", in: text),
           let words = Self.captureWords(match, at: 1, secondAt: 2, in: text),
           let value = Self.numberWordsValue(words.0, words.1) {
            remove(match, from: &text)
            return value * 3600
        }
        if let match = match("\\b(?:for\\s+)?" + Self.numberWordPattern + "\\s*(?:minutes?|mins?)\\b", in: text),
           let words = Self.captureWords(match, at: 1, secondAt: 2, in: text),
           let value = Self.numberWordsValue(words.0, words.1) {
            remove(match, from: &text)
            return value * 60
        }

        return nil
    }

    // MARK: - Date

    private struct DateExtraction {
        var components: DateComponents?
        var clarification: String?
        /// Day-part word attached to the consumed date phrase ("Tuesday
        /// morning") — explicit user wording that still governs the clock
        /// meridiem after the date tail was removed from the text.
        var consumedTimeOfDayTail: String? = nil
        /// Distinguishes "tonight" from an explicit "today" for the bounded
        /// early-morning night rollover after the clock has been resolved.
        var isTonight: Bool = false
    }

    private func dayComponents(offset: Int, from now: Date) -> DateComponents? {
        guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
        return calendar.dateComponents([.year, .month, .day], from: day)
    }

    private func validatedComponents(year: Int, month: Int, day: Int) -> DateComponents? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        guard let date = calendar.date(from: comps),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day
        else { return nil }
        return comps
    }

    private func extractDate(from text: inout String, now: Date) -> DateExtraction {
        if let match = match("\\b(?:the\\s+)?day\\s+after\\s+tomorrow\\b", in: text) {
            let tail = removeDatePhraseWithTimeOfDayTail(match, from: &text)
            return DateExtraction(components: dayComponents(offset: 2, from: now), consumedTimeOfDayTail: tail)
        }
        if let match = match("\\btoday\\b", in: text) {
            let tail = removeDatePhraseWithTimeOfDayTail(match, from: &text)
            return DateExtraction(components: dayComponents(offset: 0, from: now), consumedTimeOfDayTail: tail)
        }
        if let match = match("\\btonight\\b", in: text) {
            // "tonight" is explicit night wording: consumed with the date,
            // but carried as day-part context for a later clock in the note.
            remove(match, from: &text)
            return DateExtraction(components: dayComponents(offset: 0, from: now),
                                  consumedTimeOfDayTail: "night", isTonight: true)
        }
        if let match = match("\\btomorrow\\b", in: text) {
            let tail = removeDatePhraseWithTimeOfDayTail(match, from: &text)
            return DateExtraction(components: dayComponents(offset: 1, from: now), consumedTimeOfDayTail: tail)
        }
        if let match = match("\\byesterday\\b", in: text) {
            let tail = removeDatePhraseWithTimeOfDayTail(match, from: &text)
            return DateExtraction(components: dayComponents(offset: -1, from: now), consumedTimeOfDayTail: tail)
        }

        let weekdayPattern = "\\b(?:(on|next|this|coming)\\s+)?(sunday|monday|tuesday|wednesday|thursday|friday|saturday|tues|thurs|thur|sun|mon|tue|wed|thu|fri|sat)\\b"
        if let match = match(weekdayPattern, in: text),
           let name = capture(match, 2, text)?.lowercased(),
           let target = Self.weekdayNumber(name) {
            let prefix = capture(match, 1, text)?.lowercased()
            let todayWeekday = calendar.component(.weekday, from: now)
            var diff = target - todayWeekday
            if diff < 0 { diff += 7 }
            if diff == 0 && (prefix == "next" || prefix == "coming") { diff = 7 }
            let tail = removeDatePhraseWithTimeOfDayTail(match, from: &text)
            return DateExtraction(components: dayComponents(offset: diff, from: now), consumedTimeOfDayTail: tail)
        }

        if let match = match("\\b(\\d{4})-(\\d{1,2})-(\\d{1,2})\\b", in: text),
           let year = capture(match, 1, text).flatMap(Int.init),
           let month = capture(match, 2, text).flatMap(Int.init),
           let day = capture(match, 3, text).flatMap(Int.init) {
            guard let comps = validatedComponents(year: year, month: month, day: day) else {
                return DateExtraction(components: nil, clarification: "That date doesn't exist. Choose a real date.")
            }
            remove(match, from: &text)
            return DateExtraction(components: comps)
        }

        let monthDayPattern = "\\b(january|february|march|april|may|june|july|august|september|october|november|december|sept|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s*(\\d{4}))?\\b"
        if let match = match(monthDayPattern, in: text),
           let name = capture(match, 1, text)?.lowercased(),
           let month = Self.monthNumber(name),
           let day = capture(match, 2, text).flatMap(Int.init) {
            let explicitYear = capture(match, 3, text).flatMap(Int.init)
            guard let comps = resolveMonthDay(month: month, day: day, year: explicitYear, now: now) else {
                return DateExtraction(components: nil, clarification: "That date doesn't exist. Choose a real date.")
            }
            remove(match, from: &text)
            return DateExtraction(components: comps)
        }

        let dayMonthPattern = "\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?(january|february|march|april|may|june|july|august|september|october|november|december|sept|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)\\.?(?:,?\\s*(\\d{4}))?\\b"
        if let match = match(dayMonthPattern, in: text),
           let day = capture(match, 1, text).flatMap(Int.init),
           let name = capture(match, 2, text)?.lowercased(),
           let month = Self.monthNumber(name) {
            let explicitYear = capture(match, 3, text).flatMap(Int.init)
            guard let comps = resolveMonthDay(month: month, day: day, year: explicitYear, now: now) else {
                return DateExtraction(components: nil, clarification: "That date doesn't exist. Choose a real date.")
            }
            remove(match, from: &text)
            return DateExtraction(components: comps)
        }

        if let match = match("\\b(\\d{1,2})/(\\d{1,2})(?:/(\\d{2,4}))?\\b", in: text),
           let first = capture(match, 1, text).flatMap(Int.init),
           let second = capture(match, 2, text).flatMap(Int.init) {
            let month: Int
            let day: Int
            if first > 12 && second <= 12 {
                day = first; month = second
            } else if second > 12 && first <= 12 {
                month = first; day = second
            } else if first > 12 && second > 12 {
                return DateExtraction(components: nil, clarification: "Invalid date \(first)/\(second). Use YYYY-MM-DD or a month name.")
            } else {
                return DateExtraction(components: nil, clarification: "Ambiguous date \(first)/\(second). Use YYYY-MM-DD or a month name (e.g. Dec 5).")
            }
            var year = capture(match, 3, text).flatMap(Int.init)
            if let value = year, value < 100 { year = 2000 + value }
            guard let comps = resolveMonthDay(month: month, day: day, year: year, now: now) else {
                return DateExtraction(components: nil, clarification: "That date doesn't exist. Choose a real date.")
            }
            remove(match, from: &text)
            return DateExtraction(components: comps)
        }

        return DateExtraction(components: nil)
    }

    private func resolveMonthDay(month: Int, day: Int, year: Int?, now: Date) -> DateComponents? {
        if let year {
            return validatedComponents(year: year, month: month, day: day)
        }
        let currentYear = calendar.component(.year, from: now)
        guard let comps = validatedComponents(year: currentYear, month: month, day: day) else { return nil }
        if let candidate = calendar.date(from: comps),
           calendar.startOfDay(for: candidate) < calendar.startOfDay(for: now) {
            return validatedComponents(year: currentYear + 1, month: month, day: day)
        }
        return comps
    }

    private static func weekdayNumber(_ name: String) -> Int? {
        switch name {
        case "sunday", "sun": return 1
        case "monday", "mon": return 2
        case "tuesday", "tues", "tue": return 3
        case "wednesday", "wed": return 4
        case "thursday", "thurs", "thur", "thu": return 5
        case "friday", "fri": return 6
        case "saturday", "sat": return 7
        default: return nil
        }
    }

    private static func monthNumber(_ name: String) -> Int? {
        switch name {
        case "january", "jan": return 1
        case "february", "feb": return 2
        case "march", "mar": return 3
        case "april", "apr": return 4
        case "may": return 5
        case "june", "jun": return 6
        case "july", "jul": return 7
        case "august", "aug": return 8
        case "september", "sept", "sep": return 9
        case "october", "oct": return 10
        case "november", "nov": return 11
        case "december", "dec": return 12
        default: return nil
        }
    }

    // MARK: - Time

    private struct TimeExtraction {
        var components: DateComponents?
        var clarification: String?
        /// Recognized clock hour but no meridiem AND no unique daytime
        /// candidate ("six o'clock", "3:00", "at 3"): the hour is carried
        /// (1–12 as spoken) and the caller asks am/pm with real candidates.
        var needsAMPMConfirmation: Bool = false
        /// The owner-approved daytime rule inferred the meridiem
        /// ("three o'clock" → 3pm): resolved normally, but labelled so the
        /// review surface shows the inference and the user can edit it.
        var inferredDaytime: Bool = false
        /// A digit-only cued hour has no minute/meridiem and must preserve
        /// its structured am/pm clarification for the choice-chip UI.
        var numericBareHour: Bool = false
    }

    private func timeComponents(hour: Int, minute: Int) -> DateComponents {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return comps
    }

    /// Finds the last clock time in `text` (used after a correction marker)
    /// and resolves it with same-event contextual meridiem. Returns nil when
    /// there is no clock time to correct to.
    private func correctedClockTime(in text: String) -> TimeExtraction? {
        // Last am/pm clock.
        if let m = lastMatch("\\b(\\d{1,2})(?::(\\d{2}))?\\s*(a\\.?m\\.?|p\\.?m\\.?)\\b", in: text),
           let rawHour = Int(m.0) {
            let minute = Int(m.1 ?? "0") ?? 0
            let marker = (m.2 ?? "").lowercased().replacingOccurrences(of: ".", with: "")
            var hour = rawHour % 12
            if marker == "pm" { hour += 12 }
            return TimeExtraction(components: timeComponents(hour: hour, minute: minute))
        }
        // Last bare colon/hour clock.
        if let m = lastMatch("\\b([01]?\\d|2[0-3]):([0-5]\\d)\\b", in: text),
           let hour = Int(m.0), let minute = Int(m.1 ?? "") {
            let phrase = "\(hour):\(String(format: "%02d", minute))"
            if hour > 12 || hour == 0 { return TimeExtraction(components: timeComponents(hour: hour, minute: minute)) }
            if PhraseValidator.isUnambiguous24Hour(timePhrase: phrase, transcript: text) {
                return TimeExtraction(components: timeComponents(hour: hour, minute: minute))
            }
            if let ctx = PhraseValidator.contextualMeridiem(transcript: text, timePhrase: phrase), ctx != .conflicting {
                return TimeExtraction(components: timeComponents(hour: ctx.hour24(forBareHour: hour), minute: minute))
            }
            return TimeExtraction(components: nil, clarification: "Did you mean \(phrase)am or \(phrase)pm? Add am/pm.")
        }
        return nil
    }

    private func lastMatch(_ pattern: String, in text: String) -> (String, String?, String?)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, options: [], range: range).last else { return nil }
        func group(_ index: Int) -> String? {
            guard index < match.numberOfRanges else { return nil }
            let r = match.range(at: index)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return nil }
            return String(text[swiftRange])
        }
        guard let first = group(1) else { return nil }
        return (first, group(2), group(3))
    }

    private func extractTime(from text: inout String, forcingPM: Bool? = nil,
                             dayPartContext: String? = nil) -> TimeExtraction {
        // Correction ("around noon, actually make it 12:30"): the LAST clock
        // in the text wins, with its meridiem inferred from the same-event
        // noon/afternoon/morning context — never the earlier bare "noon" alone.
        if PhraseValidator.containsCorrectionMarker(text) {
            if let corrected = correctedClockTime(in: text) {
                return corrected
            }
        }
        if let match = match("\\b(?:(?:at|by|around|on)\\s+)?(?:noon|midday)\\b", in: text) {
            remove(match, from: &text)
            return TimeExtraction(components: timeComponents(hour: 12, minute: 0))
        }
        if let match = match("\\b(?:(?:at|by|around)\\s+)?midnight\\b", in: text) {
            remove(match, from: &text)
            return TimeExtraction(components: timeComponents(hour: 0, minute: 0))
        }

        // Spoken clock words (0.3.22): "three o'clock", "3 o’clock",
        // "half past three", "quarter to four", "at three thirty",
        // "three pm", "three o'clock in the afternoon". The full span
        // (leading cue + trailing day part) is removed so it never lands
        // in the title. A match inside an explicit user-named or quoted
        // title ("an event called Three Oclock Club") is the NAME, not a
        // clock — skipped. Meridiem order (owner-approved 2026-11-08):
        // 1) explicit wording ("three pm", "in the afternoon", "at night")
        // 2) an am/pm chip re-parse (forcingPM)
        // 3) same-segment day-part context (labelled)
        // 4) the bounded daytime rule — unique candidate inside ordinary
        //    daytime meeting hours 9:00–17:00 ("three o'clock" → 3pm),
        //    labelled; hours 6–8 have no unique candidate and still ask.
        if let spoken = SpokenClock.firstMatch(in: text),
           !Self.spokenClockLiesInsideExplicitTitle(spoken, in: text) {
            // Resolve BEFORE removing the span: the same-segment context
            // scan needs the phrase verbatim in the working text.
            let resolvedHour24: Int?
            var inferredDaytime = false
            if let explicit = spoken.meridiem {
                resolvedHour24 = explicit == .pm ? spoken.hour12 % 12 + 12 : spoken.hour12 % 12
            } else if let forced = forcingPM {
                resolvedHour24 = forced ? spoken.hour12 % 12 + 12 : spoken.hour12 % 12
            } else if let tail = dayPartContext,
                      let meridiem = SpokenClock.meridiem(forDayPart: tail, hour12: spoken.hour12) {
                // Day part attached to the date phrase ("tomorrow morning
                // at three o'clock") is explicit user wording — it wins
                // over the daytime heuristic.
                resolvedHour24 = meridiem == .pm ? spoken.hour12 % 12 + 12 : spoken.hour12 % 12
            } else if let ctx = PhraseValidator.contextualMeridiem(transcript: text, timePhrase: spoken.text),
                      ctx != .conflicting {
                resolvedHour24 = ctx.hour24(forBareHour: spoken.hour12)
            } else if SpokenClock.isBareNumericCuedHour(spoken) {
                // Numeric "at 2" is ambiguous without explicit day-part or
                // meridiem evidence; do not apply the word-form daytime rule.
                return TimeExtraction(
                    components: timeComponents(hour: spoken.hour12, minute: spoken.minute),
                    needsAMPMConfirmation: true,
                    numericBareHour: true)
            } else if let inferred = SpokenClock.daytimeInferredMeridiem(hour12: spoken.hour12) {
                resolvedHour24 = inferred == .pm ? spoken.hour12 % 12 + 12 : spoken.hour12 % 12
                inferredDaytime = true
            } else {
                resolvedHour24 = nil
            }
            removeRange(spoken.range, from: &text)
            if let hour24 = resolvedHour24 {
                return TimeExtraction(components: timeComponents(hour: hour24, minute: spoken.minute),
                                      inferredDaytime: inferredDaytime)
            }
            // Genuinely ambiguous (six/seven/eight o'clock, no context):
            // recognized clock (hour as spoken, 1–12) + am/pm ask.
            return TimeExtraction(
                components: timeComponents(hour: spoken.hour12, minute: spoken.minute),
                needsAMPMConfirmation: true)
        }

        // 12-hour clock, with optional minutes. Checked before 24-hour so "2:30pm" is never AM.
        let amPmPattern = "\\b(?:(?:at|by|around|from)\\s+)?(?<![\\d:])(\\d{1,2})(?::(\\d{2}))?\\s*(a\\.?m\\.?|p\\.?m\\.?)\\b"
        if let match = match(amPmPattern, in: text),
           let rawHour = capture(match, 1, text).flatMap(Int.init) {
            let minute = capture(match, 2, text).flatMap(Int.init) ?? 0
            let marker = capture(match, 3, text)?.lowercased().replacingOccurrences(of: ".", with: "") ?? ""
            guard (1...12).contains(rawHour), (0...59).contains(minute) else {
                return TimeExtraction(components: nil, clarification: "Time hour must be 1–12 with am/pm.")
            }
            var hour = rawHour % 12
            if marker == "pm" { hour += 12 }
            remove(match, from: &text)
            return TimeExtraction(components: timeComponents(hour: hour, minute: minute))
        }

        // 24-hour clock — but a colon alone does NOT make 12:30 into 24h.
        // Hour 13–23/0 with a colon is unambiguous 24h; an explicit
        // "24 hour time" phrase is too; same-event noon/afternoon/morning
        // context infers the meridiem; otherwise a bare 1–12 clock asks.
        let twentyFourPattern = "\\b(?:(?:at|by|around|from)\\s+)?(?<![\\d:])([01]?\\d|2[0-3]):([0-5]\\d)\\b(?!\\s*(?:a\\.?m\\.?|p\\.?m\\.?))"
        if let match = match(twentyFourPattern, in: text),
           let hour = capture(match, 1, text).flatMap(Int.init),
           let minute = capture(match, 2, text).flatMap(Int.init) {
            let phrase = "\(hour):\(String(format: "%02d", minute))"
            if hour > 12 || hour == 0 {
                remove(match, from: &text)
                return TimeExtraction(components: timeComponents(hour: hour, minute: minute))
            }
            if PhraseValidator.isUnambiguous24Hour(timePhrase: phrase, transcript: text) {
                remove(match, from: &text)
                return TimeExtraction(components: timeComponents(hour: hour, minute: minute))
            }
            if let ctx = PhraseValidator.contextualMeridiem(transcript: text, timePhrase: phrase),
               ctx != .conflicting {
                remove(match, from: &text)
                return TimeExtraction(components: timeComponents(hour: ctx.hour24(forBareHour: hour), minute: minute))
            }
            // Chip resolution (0.3.22): an explicit am/pm choice re-parses
            // the same note with the meridiem forced — never a silent guess.
            if let forced = forcingPM {
                remove(match, from: &text)
                let hour24 = forced ? hour % 12 + 12 : hour % 12
                return TimeExtraction(components: timeComponents(hour: hour24, minute: minute))
            }
            remove(match, from: &text)
            // Recognized clock, no meridiem: carry the hour and ask am/pm.
            return TimeExtraction(components: timeComponents(hour: hour, minute: minute),
                                  needsAMPMConfirmation: true)
        }

        // "at 14" style 24-hour hour only.
        if let match = match("\\b(?:at|by|around)\\s+(\\d{1,2})\\b", in: text),
           let hour = capture(match, 1, text).flatMap(Int.init) {
            if (13...23).contains(hour) {
                remove(match, from: &text)
                return TimeExtraction(components: timeComponents(hour: hour, minute: 0))
            }
            if (1...12).contains(hour) {
                if let forced = forcingPM {
                    remove(match, from: &text)
                    let hour24 = forced ? hour % 12 + 12 : hour % 12
                    return TimeExtraction(components: timeComponents(hour: hour24, minute: 0))
                }
                remove(match, from: &text)
                return TimeExtraction(components: timeComponents(hour: hour, minute: 0),
                                      needsAMPMConfirmation: true)
            }
        }

        return TimeExtraction(components: nil)
    }

    // MARK: - Location

    private func extractLocation(from text: inout String) -> String? {
        let patterns = ["\\s+(?:in|@)\\s+(.+)$", "\\s+at\\s+(.+)$"]
        for pattern in patterns {
            guard let match = match(pattern, in: text),
                  let candidate = capture(match, 1, text)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.isEmpty else { continue }
            if Self.isTimeOfDayPhrase(candidate) { continue }
            let cleaned = candidate
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
            guard !cleaned.isEmpty, cleaned.count <= 120 else { continue }
            if pattern.contains("in|@") && !Self.looksLikePlace(cleaned) { continue }
            remove(match, from: &text)
            return cleaned
        }
        return nil
    }

    private static func isTimeOfDayPhrase(_ text: String) -> Bool {
        let pattern = "^(?:the\\s+|this\\s+|same\\s+)?(?:morning|afternoon|evening|night|weekend|office\\s+hours|noon|midnight|am|pm|time)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func looksLikePlace(_ text: String) -> Bool {
        if text.rangeOfCharacter(from: .decimalDigits) != nil { return true }
        if let first = text.first, first.isUppercase { return true }
        let words = text.split(separator: " ")
        if words.count >= 2 && text.lowercased().hasPrefix("the ") { return true }
        return false
    }

    // MARK: - Title + description (semantic split, 0.3.17)
    //
    // Owner requirement: the calendar save must PARSE the wording and derive
    // (1) a concise, specific event name capturing the actual activity and
    // (2) a description carrying the remaining useful user detail — never
    // the raw utterance dumped into the title, never invented content, and
    // never a lossy first-X-words truncation. These rules are GENERAL
    // English phrasing patterns (request boilerplate, explicit "called X"
    // titles, clause splitting, generic event-noun reframing) — not a
    // hardcoded classifier for specific example sentences.

    private struct TitleNotes {
        var title: String
        var notes: String?
    }

    /// Extracts the concise title + user-provided description from the
    /// content that remains after date/time/duration/location/reminder
    /// phrases were removed.
    private func extractTitleAndNotes(from working: String) -> TitleNotes {
        var text = working
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Request boilerplate never belongs to the event itself: leading
        //    polite/imperative request phrasing and trailing calendar-target
        //    tails ("on my calendar", "to my schedule", "please", "thanks").
        text = Self.stripRequestBoilerplate(text)

        // 1b. Cue-attached time-of-day phrases are SCHEDULING context, not
        //     the event's name: "due morning", "in the evening", "at night"
        //     are consumed here (0.3.20). They are deliberately NOT resolved
        //     to clock times — "morning" alone never invents a calendar
        //     start; the resolver's existing clarification / default-marker
        //     policy still applies. A time-of-day word WITHOUT a cue
        //     ("Morning Pages", "Movie night") keeps the user's wording.
        text = TitleNotesNormalizer.stripSchedulingTimeOfDayPhrases(text)

        // 2. An EXPLICIT user title always wins verbatim:
        //    "an event called Budget review" → title "Budget review".
        if let explicit = Self.explicitTitle(in: text) {
            return TitleNotes(title: Self.tidy(explicit), notes: nil)
        }

        // 3. Detail clauses: the FIRST clause names the event; later
        //    clauses (after commas/semicolons) are genuine user detail and
        //    become the description. Nothing is dropped or invented — each
        //    clause keeps the user's own words. When nothing extra was said
        //    the description stays EMPTY (e.g. "just dentist tomorrow at
        //    3" → title "Dentist", no invented filler).
        var clauses = Self.splitDetailClauses(text)
        let head = clauses.removeFirst()
        var detail = clauses

        // 4. Concise, specific title from the head clause.
        let title = Self.conciseTitle(from: head)

        // 5. Description: only the user's actual extra detail.
        let notes = detail
            .map { Self.tidy($0) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .nilIfEmpty
        return TitleNotes(title: title, notes: notes)
    }

    /// First capture group of a pattern, or nil when it does not match.
    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1 else { return nil }
        let group = match.range(at: 1)
        guard group.location != NSNotFound, let swiftRange = Range(group, in: text) else { return nil }
        return String(text[swiftRange])
    }

    /// Leading request phrasing ("please schedule", "can you add", "I need
    /// to create", "go ahead and add my", "remind me to") and trailing
    /// calendar-target/boilerplate tails ("on my calendar please"). General
    /// phrasing, case-insensitive. Shared with the model phrase pipeline
    /// (0.3.20): `TitleNotesNormalizer.stripRequestBoilerplate` is the ONE
    /// implementation both extraction paths use.
    private static func stripRequestBoilerplate(_ text: String) -> String {
        TitleNotesNormalizer.stripRequestBoilerplate(text)
    }

    /// "an event/appointment/meeting (titled|called|named) X" → X. The
    /// user's own explicit name is kept exactly as stated — meaningful
    /// names and proper nouns are never reworded.
    private static func explicitTitle(in text: String) -> String? {
        let patterns = [
            "\\b(?:event|appointment|meeting|reminder)\\s+(?:titled|called|named)\\s+(.+)$",
            "^(?:titled|called|named)\\s+(.+)$"
        ]
        for pattern in patterns {
            if let named = firstCapture(pattern, in: text)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
                return named
            }
        }
        return nil
    }

    /// Splits the content into detail clauses on commas/semicolons. The
    /// first clause is the event-name clause; the rest are user detail.
    private static func splitDetailClauses(_ text: String) -> [String] {
        let parts = text
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [""] : parts
    }

    /// Concise specific title from the head clause. General patterns only:
    /// - generic event-noun reframing: "a meeting with Alex to review the
    ///   Q4 budget" → "Q4 budget review with Alex" — the generic noun is
    ///   replaced by the ACTUAL activity; a named person is never dropped.
    /// - otherwise the user's own cleaned wording (first letter
    ///   capitalized), never truncated and never degraded to a generic
    ///   "Event"/"Meeting" when the note names the real activity.
    private static func conciseTitle(from head: String) -> String {
        let text = stripEdgeFillers(head)
        let article = "(?:a\\s+|an\\s+|the\\s+)?"
        let noun = "(?:meeting|appointment|call|chat|sync|session|stand[\\s-]?up|catch[\\s-]?up)"
        // "(a) meeting with PERSON to ACTIVITY"
        if let person = firstCapture("^" + article + noun + "\\s+with\\s+(.+?)\\s+to\\s+.+$", in: text),
           let activity = firstCapture("^" + article + noun + "\\s+with\\s+.+?\\s+to\\s+(.+)$", in: text) {
            let personName = stripEdgeFillers(person)
            if let reframed = reframeActivity(activity) {
                return tidy(reframed + " with " + personName)
            }
            // Unknown activity verb: keep the user's own wording for the
            // activity — never a guessed reframe — with the person attached.
            return tidy(activity + " with " + personName)
        }
        // "(a) meeting to ACTIVITY" (no person named)
        if let activity = firstCapture("^" + article + noun + "\\s+to\\s+(.+)$", in: text) {
            if let reframed = reframeActivity(activity) { return tidy(reframed) }
            return tidy(activity)
        }
        // Everything else — including a bare "meeting with Alex" (the noun
        // IS the event there; no purpose was stated to reframe into) —
        // keeps the user's wording, tidied.
        return tidy(text)
    }

    /// Common activity verb → noun reframe with the object moved first:
    /// "review the Q4 budget" → "Q4 budget review". A small documented
    /// map; verbs outside it return nil so the caller keeps the user's
    /// original wording (never a guessed rephrase).
    private static func reframeActivity(_ activity: String) -> String? {
        let verbNouns: [(verb: String, noun: String)] = [
            ("(?:go\\s+over|review)", "review"),
            ("discuss", "discussion"),
            ("talk\\s+about", "discussion"),
            ("walk\\s+through|walk\\s+me\\s+through", "walkthrough"),
            ("catch\\s+up\\s+on", "catch-up"),
            ("plan", "planning"),
            ("prep(?:are)?\\s+for", "prep")
        ]
        for (verb, noun) in verbNouns {
            let pattern = "^" + verb + "\\s+(?:the\\s+|my\\s+|our\\s+|a\\s+|an\\s+)?(.+)$"
            if let object = firstCapture(pattern, in: activity) {
                let cleaned = stripEdgeFillers(object)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
                guard !cleaned.isEmpty else { return nil }
                return cleaned + " " + noun
            }
        }
        return nil
    }

    /// Strips leading/trailing filler and preposition words from a clause.
    /// Shared implementation (0.3.20) with the model phrase pipeline.
    private static func stripEdgeFillers(_ text: String) -> String {
        TitleNotesNormalizer.stripEdgeFillers(text)
    }

    /// Cleans a user phrase for display: collapses whitespace, strips edge
    /// fillers/punctuation, capitalizes the first letter. Never truncates.
    /// Shared implementation (0.3.20) with the model phrase pipeline.
    private static func tidy(_ raw: String) -> String {
        TitleNotesNormalizer.tidy(raw)
    }
}
