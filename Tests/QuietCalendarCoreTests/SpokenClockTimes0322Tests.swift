import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.22 spoken clock-time regression tests.
///
/// Owner-approved behavior (correction 2026-11-08): a spoken clock with no
/// explicit meridiem resolves via the bounded daytime rule — "Have a
/// meeting on Tuesday at three o'clock" → Tuesday 15:00, shown for normal
/// confirmation with a labelled, editable inference. Explicit wording
/// ("3am", "in the morning", "at night") always overrides the heuristic.
/// Hours 6–8 (no unique daytime candidate) keep the am/pm ask with chips.
struct SpokenClockTimes0322Tests {

    /// Fixed calendar so date resolution is deterministic (2026-11-08 is a
    /// Sunday; "Tuesday" → the coming Tuesday, Nov 10).
    private func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    private func now() -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 8
        components.hour = 10; components.minute = 0
        return fixedCalendar().date(from: components) ?? Date()
    }

    private func parser() -> EventParser {
        EventParser(calendar: fixedCalendar(), nowProvider: { now() })
    }

    private func hourMinute(_ result: ParseResult) -> (hour: Int, minute: Int)? {
        guard case .event(let draft) = result else { return nil }
        let comps = fixedCalendar().dateComponents([.hour, .minute], from: draft.start)
        return (comps.hour ?? -1, comps.minute ?? -1)
    }

    // MARK: - The screenshot case (owner-approved 3pm inference)

    @Test func screenshotCaseResolvesTuesdayThreePM() {
        let result = parser().parse("Have a meeting on Tuesday at three o'clock", now: now())
        guard case .event(let draft) = result else {
            Issue.record("Expected a resolved draft, got \(result)")
            return
        }
        let comps = fixedCalendar().dateComponents([.year, .month, .day, .hour], from: draft.start)
        #expect(comps.year == 2026)
        #expect(comps.month == 11)
        #expect(comps.day == 10)          // coming Tuesday after Sunday Nov 8
        #expect(comps.hour == 15)         // owner-approved daytime inference
        #expect(draft.title == "Have a meeting") // clock words never in the title
    }

    @Test func inferenceIsFlaggedOnTheIntent() {
        let extraction = parser().extractIntent("meeting on Tuesday at three o'clock", now: now())
        guard case .intent(let intent) = extraction else {
            Issue.record("Expected intent")
            return
        }
        #expect(intent.timeInferredDaytime == true)
        #expect(intent.timeNeedsAMPMConfirmation == false)
    }

    // MARK: - Explicit wording always overrides the heuristic

    @Test func explicitAfternoonResolves() {
        let result = parser().parse("meeting on Tuesday at three o'clock in the afternoon", now: now())
        #expect(hourMinute(result)?.hour == 15)
    }

    @Test func explicitAMResolves() {
        let result = parser().parse("meeting on Tuesday at three am", now: now())
        #expect(hourMinute(result)?.hour == 3)
    }

    @Test func explicitMorningResolves() {
        let result = parser().parse("meeting on Tuesday at three in the morning", now: now())
        #expect(hourMinute(result)?.hour == 3)
    }

    @Test func explicitNightResolvesCoherently() {
        // Night hours 18:00–05:00: "eight at night" → 20:00, "three at
        // night" → 03:00, "twelve at night" → midnight.
        #expect(hourMinute(parser().parse("meeting at eight o'clock at night", now: now()))?.hour == 20)
        #expect(hourMinute(parser().parse("meeting at three o'clock at night", now: now()))?.hour == 3)
        #expect(hourMinute(parser().parse("meeting at twelve o'clock at night", now: now()))?.hour == 0)
    }

    @Test func curlyApostropheAndOclock() {
        #expect(hourMinute(parser().parse("meeting at three o’clock", now: now()))?.hour == 15)
        #expect(hourMinute(parser().parse("meeting at three oclock", now: now()))?.hour == 15)
        #expect(hourMinute(parser().parse("meeting at 3 o'clock", now: now()))?.hour == 15)
    }

    @Test func dateAttachedDayPartOverridesDaytimeRule() {
        // "tomorrow morning at three o'clock": the user's explicit morning
        // wins over the 3pm daytime inference (the date-tail day part is
        // carried into the clock resolution).
        #expect(hourMinute(parser().parse("meeting tomorrow morning at three o'clock", now: now()))?.hour == 3)
        #expect(hourMinute(parser().parse("meeting Tuesday afternoon at three o'clock", now: now()))?.hour == 15)
        #expect(hourMinute(parser().parse("meeting tonight at three o'clock", now: now()))?.hour == 3)
        #expect(hourMinute(parser().parse("meeting tonight at eight o'clock", now: now()))?.hour == 20)
    }

    @Test func tonightEarlyMorningUsesNextDateButTodayDoesNotRoll() {
        let result = parser().parse("meeting tonight at three o'clock", now: now())
        guard case .event(let draft) = result else {
            Issue.record("Expected tonight's early-morning clock to resolve on the coming night, got \(result)")
            return
        }
        let components = fixedCalendar().dateComponents([.year, .month, .day, .hour, .minute], from: draft.start)
        #expect(components.year == 2026)
        #expect(components.month == 11)
        #expect(components.day == 9)
        #expect(components.hour == 3)
        #expect(components.minute == 0)

        // An explicit "today" is never silently moved to tomorrow.
        guard case .needsClarification = parser().parse("meeting today at three o'clock at night", now: now()) else {
            Issue.record("Explicit today at a past early-morning time must ask instead of rolling")
            return
        }
    }

    // MARK: - The bounded daytime rule itself

    @Test func daytimeRulePicksUniqueCandidate() {
        // 1–5 infer pm (13:00–17:00); 9–12 infer am/noon (9:00–12:00).
        #expect(SpokenClock.daytimeInferredMeridiem(hour12: 3) == .pm)
        #expect(SpokenClock.daytimeInferredMeridiem(hour12: 5) == .pm)
        #expect(SpokenClock.daytimeInferredMeridiem(hour12: 9) == .am)
        #expect(SpokenClock.daytimeInferredMeridiem(hour12: 12) == .pm)
        // 6–8: no unique daytime candidate → nil → the am/pm ask.
        #expect(SpokenClock.daytimeInferredMeridiem(hour12: 6) == nil)
        #expect(SpokenClock.daytimeInferredMeridiem(hour12: 7) == nil)
        #expect(SpokenClock.daytimeInferredMeridiem(hour12: 8) == nil)
    }

    @Test func genuinelyAmbiguousHoursStillAsk() {
        let result = parser().parse("meeting on Tuesday at seven o'clock", now: now())
        guard case .needsClarification(let message) = result else {
            Issue.record("Expected an am/pm clarification for seven o'clock")
            return
        }
        #expect(message.contains("7:00am"))
        #expect(message.contains("7:00pm"))
    }

    @Test func ambiguousAskCarriesRealCandidates() {
        // The note-screen chips derive from DateResolver.ampmCandidates —
        // spoken phrases now yield real digit candidates.
        let candidates = DateResolver(calendar: fixedCalendar()).ampmCandidates(for: "7:00")
        #expect(candidates == ["7:00 am", "7:00 pm"])
        let spoken = DateResolver(calendar: fixedCalendar()).ampmCandidates(for: "seven o'clock")
        #expect(spoken == ["7:00 am", "7:00 pm"])
    }

    @Test func chipReparseForcesMeridiem() {
        let result = parser().parse("meeting on Tuesday at seven o'clock", now: now(), forcingPM: true)
        #expect(hourMinute(result)?.hour == 19)
        let amResult = parser().parse("meeting on Tuesday at seven o'clock", now: now(), forcingPM: false)
        #expect(hourMinute(amResult)?.hour == 7)
    }

    // MARK: - Spoken minute idioms

    @Test func halfPastAndQuarterTo() {
        #expect(hourMinute(parser().parse("meeting at half past three", now: now()))?.hour == 15)
        #expect(hourMinute(parser().parse("meeting at half past three", now: now()))?.minute == 30)
        #expect(hourMinute(parser().parse("meeting at quarter past three", now: now()))?.hour == 15)
        #expect(hourMinute(parser().parse("meeting at quarter past three", now: now()))?.minute == 15)
        #expect(hourMinute(parser().parse("meeting at quarter to four", now: now()))?.hour == 15)
        #expect(hourMinute(parser().parse("meeting at quarter to four", now: now()))?.minute == 45)
    }

    @Test func spokenHourMinute() {
        guard let match = SpokenClock.firstMatch(in: "meeting at twelve oh five pm") else {
            Issue.record("Expected the complete spoken hour-minute phrase to match")
            return
        }
        #expect(match.hour12 == 12)
        #expect(match.minute == 5)
        #expect(match.meridiem == .pm)
        #expect(match.text.lowercased() == "at twelve oh five pm")

        #expect(hourMinute(parser().parse("meeting at three thirty", now: now()))?.hour == 15)
        #expect(hourMinute(parser().parse("meeting at three thirty", now: now()))?.minute == 30)
        #expect(hourMinute(parser().parse("meeting at twelve oh five pm", now: now()))?.hour == 12)
        #expect(hourMinute(parser().parse("meeting at twelve oh five pm", now: now()))?.minute == 5)
    }

    @Test func numericBareHourNeedsEvidenceButExplicitDayPartResolves() {
        guard case .needsClarification = parser().parse("meeting today at 2", now: now()) else {
            Issue.record("A bare digit-only hour must remain am/pm ambiguous")
            return
        }
        let explicit = parser().parse("meeting today at 2 in the afternoon", now: now())
        guard case .event(let draft) = explicit else {
            Issue.record("Explicit afternoon context should resolve the numeric hour, got \(explicit)")
            return
        }
        #expect(fixedCalendar().component(.hour, from: draft.start) == 14)
    }

    // MARK: - Clock vs duration/reminder/names (never a 3am start)

    @Test func reminderHoursAreNotAStart() {
        let extraction = parser().extractIntent("meeting on Tuesday at three o'clock, remind me three hours before", now: now())
        guard case .intent(let intent) = extraction else {
            Issue.record("Expected intent")
            return
        }
        #expect(intent.reminderLeadMinutes == 180)
        #expect(intent.time?.hour == 15)
    }

    @Test func durationHoursAreNotAStart() {
        let extraction = parser().extractIntent("meeting for three hours on Tuesday at three o'clock", now: now())
        guard case .intent(let intent) = extraction else {
            Issue.record("Expected intent")
            return
        }
        #expect(intent.durationSeconds == 3 * 3600)
        #expect(intent.time?.hour == 15)
    }

    @Test func explicitNameKeepsClockWordsOut() {
        let extraction = parser().extractIntent("an event called Three Oclock Club on Friday", now: now())
        guard case .intent(let intent) = extraction else {
            Issue.record("Expected intent")
            return
        }
        #expect(intent.title == "Three Oclock Club")
        #expect(intent.time == nil) // the name's clock words are not a start
    }

    @Test func quotedNameKeepsClockWordsOut() {
        let extraction = parser().extractIntent("\"Three Oclock Club\" on Friday", now: now())
        guard case .intent(let intent) = extraction else {
            Issue.record("Expected intent")
            return
        }
        #expect(intent.time == nil)
    }

    @Test func proseThreeIsNotATime() {
        // No clock cue (no at/o'clock/meridiem/unit): "three" stays prose.
        let extraction = parser().extractIntent("chapter three review on Friday at 2pm", now: now())
        guard case .intent(let intent) = extraction else {
            Issue.record("Expected intent")
            return
        }
        #expect(intent.title.lowercased().contains("three"))
        #expect(intent.time?.hour == 14)
    }

    // MARK: - Existing behavior preserved

    @Test func digitTimesUnchanged() {
        #expect(hourMinute(parser().parse("meeting at 2pm", now: now()))?.hour == 14)
        #expect(hourMinute(parser().parse("meeting at 14:00", now: now()))?.hour == 14)
        #expect(hourMinute(parser().parse("meeting at noon", now: now()))?.hour == 12)
        #expect(hourMinute(parser().parse("meeting at midnight", now: now()))?.hour == 0)
        // Bare digit clocks still ask (existing policy, now with chips).
        guard case .needsClarification = parser().parse("meeting at 3:00", now: now()) else {
            Issue.record("Expected bare 3:00 to still ask am/pm")
            return
        }
    }

    // MARK: - Grounding equivalence (model path)

    @Test func groundingAllowsSemanticallyConsistentInference() {
        let transcript = "have a meeting on tuesday at three o'clock"
        // Model normalizes to digits with the app-consistent pm → grounded.
        #expect(PhraseValidator.isGrounded("3:00 pm", in: transcript))
        #expect(PhraseValidator.isGrounded("three o'clock", in: transcript))
        // A DIFFERENT clock, or an inference inconsistent with the app's
        // own rule, never grounds.
        #expect(!PhraseValidator.isGrounded("4:00 pm", in: transcript))
        #expect(!PhraseValidator.isGrounded("3:00 am", in: transcript))
    }

    @Test func groundingKeepsExplicitNightConsistent() {
        let transcript = "meeting at three o'clock at night"
        #expect(PhraseValidator.isGrounded("3:00 am", in: transcript))
        #expect(!PhraseValidator.isGrounded("3:00 pm", in: transcript))
    }

    // MARK: - Review-fix regressions (parent static review, 2026-11-08)

    @Test func rewriteNeverReparsesGeneratedText() {
        // Numeric clocks pass through WHOLE — the minute field is never
        // re-matched as an hour ("3:10 pm" must not become "3:10:00 pm").
        #expect(SpokenClock.rewriteToDigitEquivalent("call me at 3:10 pm") == "call me at 3:10 pm")
        // Spoken clocks rewrite ONCE from the original span ("at three oh
        // five" → "3:05 pm", never re-matched into "3:5:00 pm").
        #expect(SpokenClock.rewriteToDigitEquivalent("meeting at three oh five") == "meeting at 3:05 pm")
        #expect(SpokenClock.rewriteToDigitEquivalent("meeting at three oh five").contains("3:5:00") == false)
        // Spoken and numeric minute clocks stay equivalent.
        #expect(PhraseValidator.isGrounded("3:10 pm", in: "see you at three ten pm"))
    }

    @Test func rewriteHandlesQuarterPastTo() {
        #expect(SpokenClock.rewriteToDigitEquivalent("quarter past three") == "3:15 pm")
        #expect(SpokenClock.rewriteToDigitEquivalent("quarter to four") == "3:45 pm")
    }

    @Test func canonical24hEquivalentToInferredDaytimeOnly() {
        // "15:00" ≡ the app's owner-approved inferred "3:00 pm" (same exact
        // resolved clock — the documented 24h grounding gap, closed).
        #expect(PhraseValidator.isGrounded("15:00", in: "have a meeting on tuesday at three o'clock"))
        #expect(PhraseValidator.isGrounded("3:00 pm", in: "have a meeting on tuesday at three o'clock"))
        // ...but NEVER against an explicit morning source (canonical retains
        // the source's own day-part evidence: 3:00 am ≠ 15:00).
        #expect(!PhraseValidator.isGrounded("15:00", in: "meeting at three o'clock in the morning"))
        #expect(!PhraseValidator.isGrounded("15:10", in: "meeting at three ten in the morning"))
        #expect(!PhraseValidator.isGrounded("03:10", in: "meeting at three ten in the afternoon"))
        #expect(!PhraseValidator.isGrounded("4:00 pm", in: "have a meeting on tuesday at three o'clock"))
        #expect(!PhraseValidator.isGrounded("3:00 am", in: "have a meeting on tuesday at three o'clock"))
        // 24h with minutes keeps its minutes.
        #expect(SpokenClock.rewriteToDigitEquivalent("flight at 15:10") == "flight at 3:10 pm")
    }

    @Test func rewriteCapturesValid24HourBoundsAndPreservesMinutes() {
        #expect(SpokenClock.rewriteToDigitEquivalent("flight at 00:10") == "flight at 12:10 am")
        #expect(SpokenClock.rewriteToDigitEquivalent("flight at 09:10") == "flight at 9:10 am")
        #expect(SpokenClock.rewriteToDigitEquivalent("flight at 13:10") == "flight at 1:10 pm")
        #expect(SpokenClock.rewriteToDigitEquivalent("flight at 23:10") == "flight at 11:10 pm")
        #expect(SpokenClock.rewriteToDigitEquivalent("flight at 24:00") == "flight at 24:00")
        #expect(SpokenClock.rewriteToDigitEquivalent("flight at 09:60") == "flight at 09:60")
    }

    @Test func boundariesRejectSubstrings() {
        // Cue/hour/meridiem boundaries: no "at" inside "format", no "one"
        // inside "someone"/"gone", no bare-meridiem word stems.
        #expect(SpokenClock.firstMatch(in: "reformat the slides") == nil)
        #expect(SpokenClock.firstMatch(in: "someone pm") == nil)
        #expect(SpokenClock.firstMatch(in: "gone pm") == nil)
        // A REAL spoken clock still matches with the boundaries in place.
        #expect(SpokenClock.firstMatch(in: "see you at one o'clock") != nil)
    }

    // MARK: - Model-path resolver (phrases)

    @Test func resolverInfersDaytimeForSpokenPhrase() {
        let resolver = DateResolver(calendar: fixedCalendar())
        let phrases = EventPhrases(
            title: "Meeting", datePhrase: "Tuesday", timePhrase: "three o'clock")
        let provenance = DraftProvenance(
            source: .builtInParser, transcript: "meeting on Tuesday at three o'clock",
            referenceNowISO: "2026-11-08T10:00:00Z", timeZoneID: "America/New_York")
        guard case .resolved(let draft) = resolver.resolve(
            phrases, transcript: "meeting on Tuesday at three o'clock",
            now: now(), provenance: provenance) else {
            Issue.record("Expected resolver to infer 3pm for the spoken clock")
            return
        }
        let comps = fixedCalendar().dateComponents([.hour], from: draft.start)
        #expect(comps.hour == 15)
        #expect(draft.defaultsApplied.contains { $0.contains("daytime") })
    }

    @Test func resolverAsksForGenuinelyAmbiguousSpokenPhrase() {
        let resolver = DateResolver(calendar: fixedCalendar())
        let phrases = EventPhrases(
            title: "Meeting", datePhrase: "Tuesday", timePhrase: "seven o'clock")
        let provenance = DraftProvenance(
            source: .builtInParser, transcript: "meeting on Tuesday at seven o'clock",
            referenceNowISO: "2026-11-08T10:00:00Z", timeZoneID: "America/New_York")
        guard case .clarification(_, ampmCandidates: let candidates) = resolver.resolve(
            phrases, transcript: "meeting on Tuesday at seven o'clock",
            now: now(), provenance: provenance) else {
            Issue.record("Expected an am/pm ask for seven o'clock")
            return
        }
        #expect(candidates == ["7:00 am", "7:00 pm"])
    }

    @Test func resolverKeepsFullSpokenMinuteAndMeridiem() {
        let resolver = DateResolver(calendar: fixedCalendar())
        let transcript = "meeting on Tuesday at twelve oh five pm"
        let phrases = EventPhrases(title: "Meeting", datePhrase: "Tuesday", timePhrase: "twelve oh five pm")
        let provenance = DraftProvenance(
            source: .builtInParser, transcript: transcript,
            referenceNowISO: "2026-11-08T10:00:00Z", timeZoneID: "America/New_York")
        guard case .resolved(let draft) = resolver.resolve(
            phrases, transcript: transcript, now: now(), provenance: provenance) else {
            Issue.record("Expected model phrase resolution to preserve 12:05 pm")
            return
        }
        let components = fixedCalendar().dateComponents([.hour, .minute], from: draft.start)
        #expect(components.hour == 12)
        #expect(components.minute == 5)
    }

    @Test func resolverRollsTonightEarlyMorningButNotToday() {
        let resolver = DateResolver(calendar: fixedCalendar())
        let transcript = "meeting tonight at three o'clock"
        let phrases = EventPhrases(title: "Meeting", datePhrase: "tonight", timePhrase: "three o'clock")
        let provenance = DraftProvenance(
            source: .builtInParser, transcript: transcript,
            referenceNowISO: "2026-11-08T10:00:00Z", timeZoneID: "America/New_York")
        guard case .resolved(let draft) = resolver.resolve(
            phrases, transcript: transcript, now: now(), provenance: provenance) else {
            Issue.record("Expected model phrase resolution for tonight's 3 a.m. to roll forward")
            return
        }
        let components = fixedCalendar().dateComponents([.year, .month, .day, .hour, .minute], from: draft.start)
        #expect(components.year == 2026)
        #expect(components.month == 11)
        #expect(components.day == 9)
        #expect(components.hour == 3)
        #expect(components.minute == 0)

        let todayTranscript = "meeting today at 3am"
        let todayPhrases = EventPhrases(title: "Meeting", datePhrase: "today", timePhrase: "3am")
        guard case .clarification = resolver.resolve(
            todayPhrases, transcript: todayTranscript, now: now(), provenance: provenance) else {
            Issue.record("Explicit today at a past time must not roll to tomorrow")
            return
        }
    }

    @Test func resolverKeepsNumericHourAmbiguousUnlessDayPartIsExplicit() {
        let resolver = DateResolver(calendar: fixedCalendar())
        let provenance = DraftProvenance(
            source: .builtInParser, transcript: "meeting today at 2",
            referenceNowISO: "2026-11-08T10:00:00Z", timeZoneID: "America/New_York")
        let ambiguous = EventPhrases(title: "Meeting", datePhrase: "today", timePhrase: "2")
        guard case .clarification = resolver.resolve(
            ambiguous, transcript: "meeting today at 2", now: now(), provenance: provenance) else {
            Issue.record("Model phrase resolver must not infer 2 p.m. from a bare numeric hour")
            return
        }

        let explicit = EventPhrases(title: "Meeting", datePhrase: "today", timePhrase: "2")
        let explicitTranscript = "meeting today at 2 in the afternoon"
        guard case .resolved(let draft) = resolver.resolve(
            explicit, transcript: explicitTranscript, now: now(), provenance: provenance) else {
            Issue.record("Explicit day-part context should resolve a numeric hour")
            return
        }
        #expect(fixedCalendar().component(.hour, from: draft.start) == 14)
    }
}
