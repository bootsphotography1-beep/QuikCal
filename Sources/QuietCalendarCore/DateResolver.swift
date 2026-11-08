import Foundation

/// Provenance that travels with every draft to the confirmation surface.
public enum DraftSource: String, Sendable, Equatable, Codable {
    /// Retained only so previously serialized research provenance still decodes;
    /// no production runtime or user setting selects this source.
    case builtInParser, localModelQwen35_4B, localModelFallback, appDefaulted
    case appleFoundationModels, foundationModelsFallback
}

public struct DraftProvenance: Sendable, Equatable, Codable {
    public var source: DraftSource
    public var modelTag: String?
    public var transcript: String
    public var referenceNowISO: String
    public var timeZoneID: String
    public var note: String?

    public init(source: DraftSource, modelTag: String? = nil, transcript: String,
                referenceNowISO: String, timeZoneID: String, note: String? = nil) {
        self.source = source; self.modelTag = modelTag; self.transcript = transcript
        self.referenceNowISO = referenceNowISO; self.timeZoneID = timeZoneID; self.note = note
    }
}

public enum Resolution: Sendable, Equatable {
    case resolved(ResolvedDraft)
    case clarification(String, ampmCandidates: [String] = [])
}

public struct ResolvedDraft: Sendable, Equatable, Codable {
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    /// User-provided description/notes (0.3.17), carried from the validated
    /// phrases to the confirmation draft. nil = none stated.
    public var notes: String?
    public var provenance: DraftProvenance
    public var defaultsApplied: [String]
    /// Reminder lead minutes before the start, when the note asked for one.
    public var reminderLeadMinutes: Int?

    public init(title: String, start: Date, end: Date, location: String?, notes: String? = nil,
                provenance: DraftProvenance, defaultsApplied: [String] = [],
                reminderLeadMinutes: Int? = nil) {
        self.title = title; self.start = start; self.end = end; self.location = location
        self.notes = notes
        self.provenance = provenance; self.defaultsApplied = defaultsApplied
        self.reminderLeadMinutes = reminderLeadMinutes
    }
}

/// Deterministic resolver: phrases → concrete start/end. The model is never
/// consulted for arithmetic; every `Calendar.date(from:)` is round-trip checked
/// so nonexistent times and Calendar normalisation surprises are caught.
public struct DateResolver: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    private var parser: EventParser { EventParser(calendar: calendar, nowProvider: { Date() }) }

    public func resolve(_ phrases: EventPhrases, transcript: String, now: Date,
                        provenance: DraftProvenance) -> Resolution {
        let resolver = EventDraftResolver(calendar: calendar)

        guard let title = phrases.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return .clarification("What is this event called?")
        }

        // --- Date.
        var defaultsApplied: [String] = []
        var dayComponents: DateComponents?
        var dateWasExplicit = false
        var dateIsTonight = false
        if let datePhrase = phrases.datePhrase?.trimmingCharacters(in: .whitespacesAndNewlines),
           !datePhrase.isEmpty {
            dateIsTonight = datePhrase.range(
                of: "\\btonight\\b", options: [.regularExpression, .caseInsensitive]) != nil
            let parsed = parser.parseDatePhrase(datePhrase, now: now)
            if let clarification = parsed.clarification {
                return .clarification(clarification)
            }
            guard let comps = parsed.components else {
                return .clarification("I couldn't turn “\(datePhrase)” into a specific day. Say a day like “tomorrow” or “Friday”.")
            }
            dayComponents = comps
            dateWasExplicit = true
        }

        // --- Time (never guessed).
        guard let timePhrase = phrases.timePhrase?.trimmingCharacters(in: .whitespacesAndNewlines),
              !timePhrase.isEmpty else {
            return .clarification("Please include a time (e.g. 2pm, 14:00, noon).")
        }
        if PhraseValidator.timeOfDayWords.contains(timePhrase.lowercased()) {
            return .clarification("“\(timePhrase.capitalized)” is not a clock time — what time should this start?")
        }
        // Bare clock ("12:30", "2") resolution order:
        // 1) unambiguous 24h (13–23/0 with colon, or explicit "24 hour time")
        // 2) same-event noon/afternoon/morning/midnight context → inferred
        //    meridiem, labelled non-blocking ("inferred pm from noon context")
        // 3) conflicting qualifiers → ask; 4) otherwise ask with real candidates.
        // A colon alone never makes 12:30 into 24h.
        var inferredNote: String? = nil
        var effectiveTimePhrase = timePhrase
        var directTimeComps: DateComponents? = nil
        if PhraseValidator.isBareHour(timePhrase), let comps = PhraseValidator.bareHourComponents(timePhrase) {
            if PhraseValidator.isUnambiguous24Hour(timePhrase: timePhrase, transcript: transcript) {
                // 13–23/0 with a colon, or explicit "24 hour time": hour as written.
                var c = DateComponents(); c.hour = comps.hour; c.minute = comps.minute; c.second = 0
                directTimeComps = c
            } else if let nightMeridiem = nightMeridiemIfTonight(
                        transcript: transcript, timePhrase: timePhrase, hour12: comps.hour) {
                let hour24 = nightMeridiem == .pm ? comps.hour % 12 + 12 : comps.hour % 12
                var c = DateComponents(); c.hour = hour24; c.minute = comps.minute; c.second = 0
                directTimeComps = c
                inferredNote = "Inferred \(nightMeridiem == .pm ? "pm" : "am") from tonight — confirm the start time."
            } else if let ctx = PhraseValidator.contextualMeridiem(transcript: transcript, timePhrase: timePhrase),
                      ctx != .conflicting {
                if ctx == .twentyFour {
                    var c = DateComponents(); c.hour = comps.hour; c.minute = comps.minute; c.second = 0
                    directTimeComps = c
                } else {
                    var c = DateComponents(); c.hour = ctx.hour24(forBareHour: comps.hour); c.minute = comps.minute; c.second = 0
                    directTimeComps = c
                    inferredNote = "Inferred \(ctx == .pm ? "pm" : "am") from \(ctx.label) context — confirm the start time."
                }
            } else {
                return .clarification("Did you mean \(timePhrase)am or \(timePhrase)pm? Pick one.",
                                      ampmCandidates: ampmCandidates(for: timePhrase))
            }
        }
        // Spoken clock phrases (0.3.22): "three o'clock", "half past three",
        // "three pm", "three o'clock in the afternoon" — same resolution
        // order as bare clocks: explicit meridiem, then same-event context
        // (labelled), then ask with real candidates. Never silently am/pm.
        if directTimeComps == nil, let spoken = SpokenClock.components(inPhrase: timePhrase) {
            if let meridiem = spoken.meridiem {
                let hour24 = meridiem == .pm ? spoken.hour12 % 12 + 12 : spoken.hour12 % 12
                var c = DateComponents(); c.hour = hour24; c.minute = spoken.minute; c.second = 0
                directTimeComps = c
            } else if let nightMeridiem = nightMeridiemIfTonight(
                        transcript: transcript, timePhrase: timePhrase, hour12: spoken.hour12) {
                // "tonight at three o'clock" — explicit night wording in the
                // same event segment (the deterministic path carries it as
                // date-tail context; both paths must agree).
                let hour24 = nightMeridiem == .pm ? spoken.hour12 % 12 + 12 : spoken.hour12 % 12
                var c = DateComponents(); c.hour = hour24; c.minute = spoken.minute; c.second = 0
                directTimeComps = c
                inferredNote = "Inferred \(nightMeridiem == .pm ? "pm" : "am") from tonight — confirm the start time."
            } else if let ctx = PhraseValidator.contextualMeridiem(transcript: transcript, timePhrase: timePhrase),
                      ctx != .conflicting {
                var c = DateComponents()
                c.hour = ctx.hour24(forBareHour: spoken.hour12)
                c.minute = spoken.minute; c.second = 0
                directTimeComps = c
                if ctx != .twentyFour {
                    inferredNote = "Inferred \(ctx == .pm ? "pm" : "am") from \(ctx.label) context — confirm the start time."
                }
            } else if SpokenClock.isBareNumericCuedHour(spoken) {
                let ask = EventDraftResolver.ampmAskPhrase(hour: spoken.hour12, minute: spoken.minute)
                return .clarification("Did you mean \(ask)am or \(ask)pm? Pick one.",
                                      ampmCandidates: ampmCandidates(for: timePhrase))
            } else if let inferred = SpokenClock.daytimeInferredMeridiem(hour12: spoken.hour12) {
                // Owner-approved daytime rule (2026-11-08): unique candidate
                // inside ordinary daytime meeting hours — labelled, editable.
                let hour24 = inferred == .pm ? spoken.hour12 % 12 + 12 : spoken.hour12 % 12
                var c = DateComponents(); c.hour = hour24; c.minute = spoken.minute; c.second = 0
                directTimeComps = c
                inferredNote = "Inferred \(inferred == .pm ? "pm" : "am") from ordinary daytime meeting hours (9–5) — confirm the start time."
            } else {
                let phrase = EventDraftResolver.ampmAskPhrase(hour: spoken.hour12, minute: spoken.minute)
                return .clarification("Did you mean \(phrase)am or \(phrase)pm? Pick one.",
                                      ampmCandidates: ampmCandidates(for: timePhrase))
            }
        }
        let parsedTime = directTimeComps.map { (components: $0, clarification: nil as String?) }
            ?? parser.parseTimePhrase(effectiveTimePhrase)
        if let clarification = parsedTime.clarification {
            // Offer low-friction chips: split "12:30" into am/pm candidates.
            let candidates = ampmCandidates(for: timePhrase)
            return .clarification(clarification, ampmCandidates: candidates)
        }
        guard let timeComps = parsedTime.components,
              let hour = timeComps.hour, let minute = timeComps.minute else {
            // Bare 24h-style "12:30" / hour without am-pm → ask with chips.
            if PhraseValidator.isBareHour(timePhrase) {
                let candidates = ampmCandidates(for: timePhrase)
                return .clarification("Did you mean \(timePhrase)am or \(timePhrase)pm? Pick one.", ampmCandidates: candidates)
            }
            return .clarification("That time is not valid. Use a time like 2pm, 14:00 or noon.")
        }

        // For an explicitly extracted "tonight" date, early-morning night
        // hours fall on the next calendar day. Explicit "today" is untouched.
        if dateIsTonight, (0...5).contains(hour), let explicitDay = dayComponents {
            guard let base = calendar.date(from: explicitDay),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: base) else {
                return .clarification("Could not resolve the night date.")
            }
            dayComponents = calendar.dateComponents([.year, .month, .day], from: nextDay)
        }

        // --- Build start with strict round-trip validation.
        let start: Date
        if let day = dayComponents {
            guard let candidate = strictDate(from: day, hour: hour, minute: minute) else {
                return .clarification("That date/time combination does not exist (it may fall in a daylight-saving gap). Choose a different time.")
            }
            if dateWasExplicit, candidate < now.addingTimeInterval(-EventDraftResolver.pastGraceSeconds) {
                return .clarification("That date and time have already passed. Choose a future date or time.")
            }
            start = candidate
        } else {
            // Missing date → owner app default, labelled (today if still ahead, else tomorrow).
            var comps = calendar.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour; comps.minute = minute; comps.second = 0
            guard var candidate = calendar.date(from: comps) else {
                return .clarification("Could not construct a date from that time.")
            }
            if candidate < now {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate)
                    ?? candidate
            }
            defaultsApplied.append("Date defaulted by app policy (today, or tomorrow if that time has passed) — editable")
            start = candidate
        }

        // --- Duration.
        var durationSeconds = EventDraftResolver.defaultDurationSeconds
        if let durationPhrase = phrases.durationPhrase?.trimmingCharacters(in: .whitespacesAndNewlines),
           !durationPhrase.isEmpty {
            if let parsed = parser.parseDurationPhrase(durationPhrase) {
                durationSeconds = EventDraftResolver.normalizedDuration(parsed)
            } else {
                defaultsApplied.append("Duration phrase “\(durationPhrase)” was not understood — 1-hour app default shown; edit it if needed")
            }
        } else {
            defaultsApplied.append("Duration 1 hour (app default, editable)")
        }
        guard let end = calendar.date(byAdding: .second, value: durationSeconds, to: start) else {
            return .clarification("Could not construct the event end time.")
        }

        if let inferredNote { defaultsApplied.append(inferredNote) }
        var prov = provenance
        if let inferredNote {
            prov.note = ((prov.note ?? "") + " " + inferredNote).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let location = phrases.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        // --- Reminder lead time (auxiliary: a bad reminder phrase never
        // blocks the event; it is labelled honestly and left unset).
        var reminderLeadMinutes: Int? = nil
        if let reminderPhrase = phrases.reminderPhrase?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reminderPhrase.isEmpty {
            let parsed = parser.parseReminderPhrase(reminderPhrase)
            if let lead = parsed.leadMinutes {
                reminderLeadMinutes = lead
            } else {
                defaultsApplied.append("Reminder phrase “\(reminderPhrase)” could not be used — no reminder will be set; edit it if needed")
            }
        }
        return .resolved(ResolvedDraft(title: title, start: start, end: end, location: location,
                                       notes: phrases.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                                       provenance: prov, defaultsApplied: defaultsApplied,
                                       reminderLeadMinutes: reminderLeadMinutes))
    }

    /// Resolve with an explicit am/pm disambiguation (the confirmation chips call this).
    public func resolveWithAMPM(_ phrases: EventPhrases, transcript: String, now: Date,
                                provenance: DraftProvenance, isPM: Bool) -> Resolution {
        var adjusted = phrases
        if let timePhrase = phrases.timePhrase {
            let base = timePhrase.replacingOccurrences(of: "(?i)(am|pm)", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            adjusted.timePhrase = "\(base) \(isPM ? "pm" : "am")"
        }
        var prov = provenance
        prov.note = ((prov.note ?? "") + " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return resolve(adjusted, transcript: transcript, now: now, provenance: prov)
    }

    private func nightMeridiemIfTonight(transcript: String, timePhrase: String,
                                        hour12: Int) -> SpokenClockMeridiem? {
        let scope = PhraseValidator.segmentScope(transcript: transcript, timePhrase: timePhrase)
        guard scope.range(of: "\\btonight\\b", options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        return SpokenClock.meridiem(forDayPart: "night", hour12: hour12)
    }

    // MARK: - Strict calendar construction

    /// Builds a date and verifies the components round-trip exactly.
    /// `Calendar.date(from:)` silently normalises nonexistent times (e.g. the
    /// spring-forward gap) into shifted instants; this rejects those instead.
    public func strictDate(from day: DateComponents, hour: Int, minute: Int) -> Date? {
        guard let year = day.year, let month = day.month, let dayOfMonth = day.day,
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = dayOfMonth
        comps.hour = hour; comps.minute = minute; comps.second = 0
        comps.timeZone = calendar.timeZone
        guard let candidate = calendar.date(from: comps) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: candidate)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == dayOfMonth,
              roundTrip.hour == hour, roundTrip.minute == minute else { return nil }
        return candidate
    }

    /// Detects a repeated local time (DST fall-back): the same wall-clock time
    /// maps to two distinct instants. Returns true when disambiguation is needed.
    public func isRepeatedWallTime(_ date: Date) -> Bool {
        // Check whether adding one hour lands on the same wall-clock hour.
        guard let next = calendar.date(byAdding: .hour, value: 1, to: date) else { return false }
        return calendar.component(.hour, from: next) == calendar.component(.hour, from: date)
            && calendar.component(.minute, from: next) == calendar.component(.minute, from: date)
    }

    /// Actual candidates for this bare clock, derived from its hour/minute.
    /// "noon" is only offered when the hour is 12 (it denotes 12:00, a
    /// distinct action — never a synonym for "pm"). "midnight" likewise.
    /// Spoken phrases ("three o'clock") derive the same digit candidates.
    public func ampmCandidates(for timePhrase: String) -> [String] {
        let trimmed = timePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        var h = Int(trimmed.split(separator: ":").first ?? "") ?? 0
        var minute: Int = trimmed.contains(":")
            ? (Int(trimmed.split(separator: ":").last.flatMap { $0.prefix(2) } ?? "0") ?? 0)
            : 0
        if h == 0, let spoken = SpokenClock.components(inPhrase: trimmed) {
            h = spoken.hour12
            minute = spoken.minute
        }
        guard (1...12).contains(h) else { return [trimmed] }
        let base = "\(h):\(String(format: "%02d", minute))"
        var out = ["\(base) am", "\(base) pm"]
        if h == 12 { out.append("noon"); out.append("midnight") }
        return out
    }

    /// Resolve with an explicit candidate string from the confirmation chips
    /// ("12:30 am", "12:30 pm", "noon", "midnight"). The candidate REPLACES
    /// the time phrase; everything else (title/date/duration/location and the
    /// original transcript in provenance) is unchanged.
    public func resolveWithCandidate(_ phrases: EventPhrases, transcript: String, now: Date,
                                     provenance: DraftProvenance, candidate: String) -> Resolution {
        var adjusted = phrases
        let lowered = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "noon" || lowered == "midnight" {
            adjusted.timePhrase = candidate
            // "noon"/"midnight" as a time phrase must not be re-read as a bare
            // clock: resolve() treats them via the parser's noon/midnight arms.
            // To avoid the resolver's time-of-day guard, map to explicit clock:
            adjusted.timePhrase = lowered == "noon" ? "12:00 pm" : "12:00 am"
        } else {
            adjusted.timePhrase = candidate
        }
        return resolve(adjusted, transcript: transcript, now: now, provenance: provenance)
    }
}
