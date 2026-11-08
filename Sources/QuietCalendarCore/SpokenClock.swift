import Foundation

/// Meridiem resolved from EXPLICIT wording only ("three pm", "in the afternoon").
/// Never guessed — an ambiguous spoken clock asks am/pm instead.
public enum SpokenClockMeridiem: Sendable, Equatable {
    case am
    case pm
}

/// One recognized spoken clock phrase and where it occurred.
public struct SpokenClockMatch: Sendable, Equatable {
    /// Clock hour as spoken, 1...12 ("three" → 3, "twelve" → 12).
    public let hour12: Int
    /// Minutes 0...59 ("thirty" → 30, "quarter to" → 45).
    public let minute: Int
    /// Explicit am/pm from the phrase itself (meridiem word, "a.m.", or an
    /// attached day part). nil = ambiguous → the caller asks, never guesses.
    public let meridiem: SpokenClockMeridiem?
    /// Full matched span in the source text (includes the leading
    /// at/by/around cue and any trailing day part when present).
    public let range: NSRange
    /// The matched text verbatim.
    public let text: String
}

/// Spoken clock-time grammar (0.3.22) — "three o'clock", "3 o’clock",
/// "three oclock", "half past three", "quarter to four", "at three thirty",
/// "three pm", "three o'clock in the afternoon", "afternoon at three".
///
/// Bounded, documented English forms only — this is a robust extension of
/// the existing time grammar, NOT a general date engine:
/// - A bare word hour ("three" in prose) is NEVER a time: a clear clock cue
///   is required — "o'clock", a meridiem, an attached day part, or an
///   at/by/around/from cue.
/// - Explicit wording always wins: "3am", "in the morning", "at night"
///   (night = 18:00–05:00, so "eight at night" → 20:00, "three at night"
///   → 03:00) resolve directly and override every heuristic.
/// - With NO explicit wording, the OWNER-APPROVED daytime rule (2026-11-08)
///   infers the unique candidate inside ordinary daytime meeting hours
///   (9:00–17:00): "three o'clock" → 3:00 pm, "ten o'clock" → 10:00 am.
///   Hours 6–8 have no unique daytime candidate and still ask am/pm.
/// - Only "half/quarter past/to" minute idioms are supported; "five past
///   three", "ten to four" etc. are a documented limitation.
/// - Units are never times: "three hours", "three minutes" never match.
public enum SpokenClock: Sendable {

    /// Clock-hour words, 1...12.
    static let hourWordPattern =
        "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"

    /// Spoken minute 1...59, one or two words ("five", "twenty five").
    static let minuteWordPattern =
        "(?:(?:one|two|three|four|five|six|seven|eight|nine)"
        + "|(?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"
        + "|(?:twenty|thirty|forty|fifty)(?:[\\s-]+(?:one|two|three|four|five|six|seven|eight|nine))?)"

    /// A clock hour as words OR ASR digits ("three" or "3"). Boundaries
    /// (review fix 2026-11-08): never a word substring ("someone" contains
    /// "one", "gone pm" is not "one pm") and never a minute/colon suffix
    /// (the "10" in "3:10 pm" is not the hour "10 pm").
    static let hourToken = "(?<![\\p{L}\\d:])(?:" + hourWordPattern + "|\\d{1,2})"

    /// "o'clock" with a straight or curly apostrophe, or none ("oclock").
    static let oclockPattern = "o['‘’]?clock|oclock"

    /// "am"/"pm" incl. "a.m."/"p m" spacing variants — never a longer word
    /// stem ("pmx" is not a meridiem).
    static let meridiemPattern = "([ap])\\.?\\s*m\\.?(?![\\p{L}])"

    /// Attached day part: "in the afternoon", "this morning", "at night".
    static let dayPartPattern =
        "(?:(?:in\\s+the\\s+|this\\s+|at\\s+)?(morning|afternoon|evening|night))"

    /// Leading scheduling cue — never a word suffix ("format" contains
    /// "at", which must never steal a span out of a longer word).
    static let cuePattern = "(?<![\\p{L}\\d])(?:at|by|around|from)\\s+"

    /// Unit words that disqualify a bare word hour from being a clock
    /// ("three hours" is a duration, never a start time).
    private static let unitDisqualifier =
        "(?!\\s*(?:hours?|hrs?|h\\b|minutes?|mins?|days?|weeks?|seconds?)\\b)"

    // MARK: - Recognized forms (most specific first)

    /// P1: [cue] hour o'clock [day part] — "at three o'clock in the afternoon".
    static let formOClock =
        "(?:" + cuePattern + ")?(" + hourToken + ")\\s*(" + oclockPattern + ")"
        + "(?:\\s+" + dayPartPattern + ")?"

    /// P2: [cue] (half|quarter) (past|to) hour [meridiem] — "half past three pm".
    static let formHalfQuarter =
        "(?:" + cuePattern + ")?(half|quarter)\\s+(past|to)\\s+(" + hourToken + ")"
        + "(?:\\s*" + meridiemPattern + ")?"

    /// P3: [cue] hour meridiem — "three pm", "at three a.m.".
    static let formMeridiem =
        "(?:" + cuePattern + ")?(" + hourToken + ")\\s*" + meridiemPattern

    /// P4: [cue] hour day part — "at three in the morning", "three this afternoon".
    static let formDayPart =
        "(?:" + cuePattern + ")?(" + hourToken + ")\\s+" + dayPartPattern

    /// P5: [cue] hour [oh] minute [meridiem] — "at three thirty", "at three oh five".
    /// The cue is REQUIRED: bare "three thirty" in prose is not a clock.
    static let formHourMinuteCore =
        "(" + hourToken + ")"
        + "(?:\\s+(?:oh\\s+)?(" + minuteWordPattern + "|\\d{2}))"
        + "(?:\\s*" + meridiemPattern + ")?"
        + "(?:\\s+" + dayPartPattern + ")?"

    static let formHourMinute = cuePattern + formHourMinuteCore

    /// P6: day part + cue + hour [minute] — "afternoon at three", "in the morning at nine".
    static let formDayPartFirst =
        "(?:(?:in\\s+the\\s+|this\\s+)?(morning|afternoon|evening|night))"
        + "\\s+(?:at|by|around)\\s+(" + hourToken + ")"
        + "(?:\\s+(?:oh\\s+)?(" + minuteWordPattern + "|\\d{2}))?"

    /// P7: cue bare hour — "at three" (digits "at 3" parity with the
    /// existing digit arm). Cue required; unit words, a following colon
    /// clock ("at 3:00"), a meridiem ("at 3pm" — P3 wins first) and
    /// o'clock wording all disqualify, so digit forms are never split.
    static let formCuedHour =
        cuePattern + "(" + hourToken + ")" + unitDisqualifier
        + "(?![\\s:]*\\d)(?!\\s*(?:a\\.?m\\.?|p\\.?m\\.?)\\b)"

    static let formPatterns: [String] = [
        formOClock, formHalfQuarter, formHourMinute, formMeridiem,
        formDayPart, formDayPartFirst, formCuedHour
    ]

    // MARK: - Matching

    /// First spoken clock phrase in `text`, or nil when there is none.
    /// More specific forms win over the bare cued hour (P7).
    public static func firstMatch(in text: String) -> SpokenClockMatch? {
        for pattern in formPatterns {
            if let match = match(pattern, in: text) {
                return match
            }
        }
        return nil
    }

    /// Parse an ISOLATED time phrase ("three o'clock", "at half past three")
    /// into its clock value. Returns nil when the phrase is not a spoken clock.
    public static func components(inPhrase phrase: String) -> SpokenClockMatch? {
        // Model extraction commonly returns a cue-less field ("twelve oh
        // five pm"). Allow a full-field hour-minute match here without
        // weakening the cue requirement for matching clocks in free prose.
        if let isolated = matchWhole(formHourMinuteCore, in: phrase) {
            return isolated
        }
        return firstMatch(in: phrase)
    }

    /// A numeric, cue-attached bare hour is still am/pm ambiguous. Word-form
    /// hours may use the established labelled daytime inference, but digits
    /// such as "at 2" must not silently become 2 p.m.
    static func isBareNumericCuedHour(_ match: SpokenClockMatch) -> Bool {
        match.text.range(
            of: "^(?:at|by|around|from)\\s+\\d{1,2}$",
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// True when `phrase` is exactly a spoken clock phrase (used by the
    /// resolver/validator to route spoken phrases like bare clocks).
    public static func isSpokenClockPhrase(_ phrase: String) -> Bool {
        components(inPhrase: phrase) != nil
    }

    /// Canonical DIGIT text for a spoken clock match, e.g. "three o'clock"
    /// → "3:00 pm", "half past three pm" → "3:30 pm". Used ONLY for grounding
    /// equivalence: the model may normalize the user's spoken clock to
    /// digits, and the SAME clock (hour + minute + meridiem) must remain
    /// traceable to the user's words. For a meridiem-ambiguous clock the
    /// OWNER-APPROVED daytime inference (see `daytimeInferredMeridiem`) is
    /// included, so a semantically consistent model inference ("3 pm" for
    /// "three o'clock") stays grounded — while a DIFFERENT time ("4:00",
    /// or "3 am" against the inferred pm) never grounds.
    public static func digitEquivalent(_ match: SpokenClockMatch) -> String {
        let base = "\(match.hour12):\(String(format: "%02d", match.minute))"
        let meridiem = match.meridiem ?? daytimeInferredMeridiem(hour12: match.hour12)
        switch meridiem {
        case .am: return base + " am"
        case .pm: return base + " pm"
        case nil: return base
        }
    }

    /// Rewrites every spoken clock phrase in `text` to its digit equivalent
    /// (see `digitEquivalent`), plus 24h colon clocks to their 12h+meridiem
    /// form ("15:00" → "3:00 pm"). Applied to BOTH sides of the grounding
    /// comparison, so identical wording rewrites identically and only the
    /// spoken↔digit equivalences are added.
    ///
    /// Review fix (2026-11-08): all spans are collected from the ORIGINAL
    /// text in ONE pass and replaced back-to-front — generated canonical
    /// strings are never re-scanned. The previous iterative rewrite
    /// reparsed its own output and corrupted numeric clocks ("3:10 pm"
    /// → "3:10:00 pm"; "at three oh five" → "3:05 pm" → "3:5:00 pm").
    /// Non-overlapping is enforced most-specific-form-first, so "at three
    /// o'clock" keeps its full P1 span and the shorter cued-hour subset is
    /// dropped. Bare 1–12 colon clocks ("3:00") are deliberately untouched:
    /// the app asks am/pm for them, so there is no meridiem evidence to
    /// retain — a bare "3:00" never masquerades as the inferred "3:00 pm".
    public static func rewriteToDigitEquivalent(_ text: String) -> String {
        if let isolated = matchWhole(formHourMinuteCore, in: text) {
            return digitEquivalent(isolated)
        }
        let full = NSRange(text.startIndex..., in: text)
        var kept: [(range: NSRange, replacement: String)] = []
        func keepIfFree(_ range: NSRange, _ replacement: String) {
            guard !kept.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
            kept.append((range, replacement))
        }
        // Spoken forms, most specific first: a later form's match that
        // overlaps an already-kept span is dropped, never merged.
        for pattern in formPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for hit in regex.matches(in: text, options: [], range: full) {
                guard !kept.contains(where: { NSIntersectionRange($0.range, hit.range).length > 0 }) else { continue }
                guard let parsed = parse(match: hit, in: text) else { continue }
                let cuePrefix: String
                if let range = parsed.text.range(
                    of: "^(?:at|by|around|from)\\s+",
                    options: [.regularExpression, .caseInsensitive]) {
                    cuePrefix = String(parsed.text[range])
                } else {
                    cuePrefix = ""
                }
                keepIfFree(hit.range, cuePrefix + digitEquivalent(parsed))
            }
        }
        // 24h colon clocks with unambiguous hours (13–23, 0–09) — the
        // documented grounding gap fix: a model that normalizes the user's
        // spoken clock to 24h digits ("15:00" for "three o'clock") stays
        // grounded when — and only when — it is the SAME resolved clock
        // the app itself infers ("15:00" ≡ inferred "3:00 pm"; "15:00"
        // vs "three o'clock in the morning" → 3:00 am ≠, rejected).
        let twentyFour = "(?<![\\p{L}\\d:])((?:1[3-9]|2[0-3]|0\\d?)):([0-5]\\d)(?![\\d:])"
        if let regex = try? NSRegularExpression(pattern: twentyFour) {
            for hit in regex.matches(in: text, options: [], range: full) {
                guard !kept.contains(where: { NSIntersectionRange($0.range, hit.range).length > 0 }) else { continue }
                guard hit.numberOfRanges > 2,
                      let hourRange = Range(hit.range(at: 1), in: text),
                      let minuteRange = Range(hit.range(at: 2), in: text),
                      let hour24 = Int(String(text[hourRange])),
                      let minute = Int(String(text[minuteRange])) else { continue }
                let meridiem: SpokenClockMeridiem = hour24 >= 12 ? .pm : .am
                var hour12 = hour24 % 12
                if hour12 == 0 { hour12 = 12 }
                keepIfFree(hit.range,
                           "\(hour12):\(String(format: "%02d", minute)) \(meridiem == .pm ? "pm" : "am")")
            }
        }
        // Replace back-to-front so ORIGINAL indices stay valid throughout.
        var out = text
        for (range, replacement) in kept.sorted(by: { $0.range.location > $1.range.location }) {
            guard let swiftRange = Range(range, in: out) else { continue }
            out.replaceSubrange(swiftRange, with: replacement)
        }
        return out
    }

    // MARK: - Internals

    private static func match(_ pattern: String, in text: String) -> SpokenClockMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let hit = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return parse(match: hit, in: text)
    }

    private static func matchWhole(_ pattern: String, in text: String) -> SpokenClockMatch? {
        guard let regex = try? NSRegularExpression(
            pattern: "^\\s*(?:" + pattern + ")\\s*$", options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let hit = regex.firstMatch(in: text, options: [], range: range),
              hit.range == range else { return nil }
        return parse(match: hit, in: text)
    }

    /// Extracts the clock value from a raw regex hit of ANY known form.
    /// Group layout differs per form; this maps them by form id.
    private static func parse(match hit: NSTextCheckingResult, in text: String) -> SpokenClockMatch? {
        func group(_ i: Int) -> String? {
            guard i < hit.numberOfRanges else { return nil }
            let r = hit.range(at: i)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return nil }
            return String(text[swiftRange])
        }
        let full = group(0) ?? ""
        let lowered = full.lowercased()

        // P1 o'clock: (hour) (o'clock) (dayPart?)
        if lowered.contains("clock"), let hourRaw = group(1),
           let hour12 = hourValue(hourRaw) {
            let minute = 0
            return SpokenClockMatch(hour12: hour12, minute: minute,
                                    meridiem: dayPartMeridiem(in: full, hour12: hour12),
                                    range: hit.range, text: full)
        }
        // P2 half/quarter past/to: 1=(half|quarter) 2=(past|to) 3=(hour) 4=(meridiem?)
        if let amount = group(1), amount.lowercased() == "half" || amount.lowercased() == "quarter",
           let direction = group(2), let hourRaw = group(3),
           let hour = hourValue(hourRaw) {
            let isTo = direction.lowercased() == "to"
            let spokenMinute = amount.lowercased() == "half" ? 30 : 15
            if isTo {
                // "quarter to four" → 3:45. "to one" wraps to 12:45.
                let effectiveHour = hour == 1 ? 12 : hour - 1
                let minute = 60 - spokenMinute
                return SpokenClockMatch(hour12: effectiveHour, minute: minute,
                                        meridiem: group(4).flatMap(meridiemValue)
                                            ?? dayPartMeridiem(in: full, hour12: effectiveHour),
                                        range: hit.range, text: full)
            }
            return SpokenClockMatch(hour12: hour, minute: spokenMinute,
                                    meridiem: group(4).flatMap(meridiemValue)
                                        ?? dayPartMeridiem(in: full, hour12: hour),
                                    range: hit.range, text: full)
        }
        // P3 meridiem: (hour) (a|m)
        if let hourRaw = group(1), let hour12 = hourValue(hourRaw),
           let marker = group(2), let meridiem = meridiemValue(marker) {
            return SpokenClockMatch(hour12: hour12, minute: 0,
                                    meridiem: meridiem, range: hit.range, text: full)
        }
        // P4 day part after hour: (hour) (dayPart)
        if let hourRaw = group(1), let hour12 = hourValue(hourRaw),
           let dayWord = group(2), isDayPartWord(dayWord) {
            return SpokenClockMatch(hour12: hour12, minute: 0,
                                    meridiem: dayPartMeridiem(in: full, hour12: hour12),
                                    range: hit.range, text: full)
        }
        // P5 cued hour+minute: (hour) (minute) (meridiem?)
        if let hourRaw = group(1), let hour12 = hourValue(hourRaw),
           let minuteRaw = group(2), let minute = minuteValue(minuteRaw) {
            return SpokenClockMatch(hour12: hour12, minute: minute,
                                    meridiem: group(3).flatMap(meridiemValue)
                                        ?? dayPartMeridiem(in: full, hour12: hour12),
                                    range: hit.range, text: full)
        }
        // P6 day part first: (dayPart) (hour) (minute?)
        if let dayWord = group(1), isDayPartWord(dayWord),
           let hourRaw = group(2), let hour12 = hourValue(hourRaw) {
            let minute = group(3).flatMap(minuteValue) ?? 0
            return SpokenClockMatch(hour12: hour12, minute: minute,
                                    meridiem: dayPartMeridiem(in: full, hour12: hour12),
                                    range: hit.range, text: full)
        }
        // P7 cued bare hour: (hour)
        if let hourRaw = group(1), let hour12 = hourValue(hourRaw) {
            return SpokenClockMatch(hour12: hour12, minute: 0,
                                    meridiem: nil, range: hit.range, text: full)
        }
        return nil
    }

    private static func hourValue(_ raw: String) -> Int? {
        let lowered = raw.lowercased()
        let wordHours: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
            "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12
        ]
        if let word = wordHours[lowered] { return word }
        if let digits = Int(lowered), (1...12).contains(digits) { return digits }
        return nil
    }

    private static func minuteValue(_ raw: String) -> Int? {
        let lowered = raw.lowercased()
        let small: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
            "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
            "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
        ]
        let tens: [String: Int] = [
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50
        ]
        if let digits = Int(lowered), (1...59).contains(digits) { return digits }
        let parts = lowered.components(separatedBy: CharacterSet(charactersIn: " -"))
        if parts.count == 2, let t = tens[parts[0]], let o = small[parts[1]] {
            let value = t + o
            return (1...59).contains(value) ? value : nil
        }
        return small[lowered] ?? tens[lowered]
    }

    /// "a"/"p" marker group (from `meridiemPattern`) → meridiem.
    private static func meridiemValue(_ raw: String) -> SpokenClockMeridiem? {
        let lowered = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lowered {
        case "a", "am", "a.m.": return .am
        case "p", "pm", "p.m.": return .pm
        default: return nil
        }
    }

    private static func isDayPartWord(_ raw: String) -> Bool {
        ["morning", "afternoon", "evening", "night"].contains(raw.lowercased())
    }

    /// Day-part word inside the matched span → meridiem. "at night" is
    /// EXPLICIT user wording (owner, 2026-11-08): it resolves via the
    /// coherent night-hours rule (18:00–05:00) instead of asking —
    /// "eight at night" → 20:00, "three at night" → 03:00, "twelve at
    /// night" → midnight.
    private static func dayPartMeridiem(in spanText: String, hour12: Int) -> SpokenClockMeridiem? {
        let lowered = spanText.lowercased()
        if lowered.contains("morning") { return .am }
        if lowered.contains("afternoon") || lowered.contains("noon") { return .pm }
        if lowered.contains("evening") { return .pm }
        if lowered.contains("night") { return nightMeridiem(hour12: hour12) }
        return nil
    }

    /// Meridiem for an EXPLICIT day-part word the user attached to the
    /// date ("tomorrow morning", "tonight") — public wrapper over the same
    /// rule the in-phrase day parts use, so date-tail context and phrase
    /// context can never disagree. Returns nil for a non-day-part word.
    public static func meridiem(forDayPart word: String, hour12: Int) -> SpokenClockMeridiem? {
        guard isDayPartWord(word) else { return nil }
        return dayPartMeridiem(in: word, hour12: hour12)
    }

    /// Night-hours rule: night is 18:00–05:00; the candidate that falls
    /// there wins. Hours 6–11 → pm (18:00–23:00); hours 12 and 1–5 → am
    /// (midnight–05:00).
    static func nightMeridiem(hour12: Int) -> SpokenClockMeridiem {
        let pm = hour12 % 12 + 12
        return pm >= 18 ? .pm : .am
    }

    /// OWNER-APPROVED bounded daytime rule (2026-11-08): for a spoken clock
    /// with NO explicit meridiem and no day-part context, infer the unique
    /// candidate that falls in ordinary daytime meeting hours (9:00–17:00).
    /// "three o'clock" → 3:00 pm, "ten o'clock" → 10:00 am, "twelve
    /// o'clock" → noon. Hours where NEITHER candidate is in the window
    /// (six, seven, eight o'clock) are genuinely ambiguous → ask am/pm.
    /// This is a coherent meeting-daytime rule — not a blanket +12 and not
    /// a hardcoded utterance match.
    public static func daytimeInferredMeridiem(hour12: Int) -> SpokenClockMeridiem? {
        let am = hour12 % 12
        let pm = hour12 % 12 + 12
        let daytime = { (hour: Int) in (9...17).contains(hour) }
        switch (daytime(am), daytime(pm)) {
        case (true, false): return .am
        case (false, true): return .pm
        default: return nil
        }
    }
}
