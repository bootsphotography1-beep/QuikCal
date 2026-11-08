import Foundation

/// Deterministic parser result retained for explicit AM/PM clarification
/// resolution. Generative event extraction is handled by PhrasePipeline.
public struct ParseOutcome: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case builtIn
    }

    public var result: ParseResult
    public var source: Source?
    public var note: String?
    public var ampmCandidates: [String]

    public init(result: ParseResult, source: Source? = nil, note: String? = nil,
                ampmCandidates: [String] = []) {
        self.result = result
        self.source = source
        self.note = note
        self.ampmCandidates = ampmCandidates
    }
}

/// Runs only the deterministic parser. Explicit ambiguities stay clarifications;
/// they are never overwritten by a generative runtime.
@MainActor
public struct ParsingPipeline {
    public let parser: EventParser
    public let calendar: Calendar

    public init(parser: EventParser, calendar: Calendar) {
        self.parser = parser
        self.calendar = calendar
    }

    public func parse(_ text: String, now: Date = Date(), forcingPM: Bool? = nil) async -> ParseOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParseOutcome(result: .failed("Type something to add to your calendar."))
        }

        switch parser.extractIntent(trimmed, now: now, forcingPM: forcingPM) {
        case .needsClarification(let message):
            return ParseOutcome(result: .needsClarification(message), source: .builtIn)
        case .failed(let message):
            return ParseOutcome(result: .failed(message))
        case .intent(let intent):
            let deterministic = EventDraftResolver(calendar: calendar).resolve(intent, now: now)
            if case .event = deterministic {
                if intent.timeInferredDaytime {
                    return ParseOutcome(
                        result: deterministic,
                        source: .builtIn,
                        note: "Start time inferred from the spoken clock using ordinary daytime meeting hours (9–5) — check and edit it if needed.")
                }
                return ParseOutcome(result: deterministic, source: .builtIn)
            }
            if intent.timeNeedsAMPMConfirmation,
               let time = intent.time, let hour = time.hour, let minute = time.minute {
                let phrase = EventDraftResolver.ampmAskPhrase(hour: hour, minute: minute)
                return ParseOutcome(
                    result: deterministic,
                    source: .builtIn,
                    ampmCandidates: DateResolver(calendar: calendar).ampmCandidates(for: phrase))
            }
            return ParseOutcome(result: deterministic, source: .builtIn)
        }
    }
}
