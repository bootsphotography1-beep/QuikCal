import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Readiness of Apple's OS-managed, on-device generation runtime.
public enum FoundationModelsReadiness: Sendable, Equatable {
    case available
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown

    public var isAvailable: Bool { self == .available }

    public var shortLabel: String {
        switch self {
        case .available: return "Available"
        case .unsupportedOS: return "Requires macOS 26+"
        case .deviceNotEligible: return "Not supported on this Mac"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is off"
        case .modelNotReady: return "Preparing"
        case .unknown: return "Unavailable"
        }
    }

    public var userFacingText: String {
        switch self {
        case .available:
            return "Apple Foundation Models is ready. Event extraction runs on this Mac; macOS manages the model, so QuikCal has no text-model download. Every draft still needs your review and confirmation."
        case .unsupportedOS:
            return "On-device event extraction requires macOS 26 or later. QuikCal will use its built-in parser until then."
        case .deviceNotEligible:
            return "This Mac is not eligible for Apple Intelligence. QuikCal will use its built-in parser."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Turn it on in System Settings to enable on-device extraction; QuikCal will use its built-in parser until then."
        case .modelNotReady:
            return "The Apple Intelligence model is not ready yet. Try again later; QuikCal will use its built-in parser for now."
        case .unknown:
            return "Apple Intelligence is currently unavailable. QuikCal will use its built-in parser."
        }
    }

    public var onboardingSummary: String {
        switch self {
        case .available:
            return "On-device extraction is ready. macOS manages the model; review every draft."
        case .unsupportedOS:
            return "Requires macOS 26+. The built-in parser is used until then."
        case .deviceNotEligible:
            return "Not available on this Mac. The built-in parser is used."
        case .appleIntelligenceNotEnabled:
            return "Enable Apple Intelligence in System Settings; the built-in parser works meanwhile."
        case .modelNotReady:
            return "Apple Intelligence is preparing. The built-in parser works meanwhile."
        case .unknown:
            return "Unavailable right now. The built-in parser works meanwhile."
        }
    }

    /// Queries the system only; never downloads, prompts, or changes settings.
    public static var current: FoundationModelsReadiness {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceNotEnabled
            case .unavailable(.modelNotReady):
                return .modelNotReady
            @unknown default:
                return .unknown
            }
        }
        #endif
        return .unsupportedOS
    }
}

/// Framework-independent typed result. This is the narrow adapter boundary
/// exercised by unit tests; Foundation Models never returns arbitrary JSON.
public struct FoundationModelsPhraseEvent: Sendable, Equatable {
    public var title: String?
    public var datePhrase: String?
    public var timePhrase: String?
    public var durationPhrase: String?
    public var location: String?
    public var reminderPhrase: String?
    public var notes: String?

    public init(title: String? = nil, datePhrase: String? = nil, timePhrase: String? = nil,
                durationPhrase: String? = nil, location: String? = nil,
                reminderPhrase: String? = nil, notes: String? = nil) {
        self.title = title
        self.datePhrase = datePhrase
        self.timePhrase = timePhrase
        self.durationPhrase = durationPhrase
        self.location = location
        self.reminderPhrase = reminderPhrase
        self.notes = notes
    }

    public var rawPhraseEvent: RawPhraseEvent {
        RawPhraseEvent(title: title, datePhrase: datePhrase, timePhrase: timePhrase,
                       durationPhrase: durationPhrase, location: location,
                       reminderPhrase: reminderPhrase, notes: notes)
    }
}

public struct FoundationModelsPhraseResponse: Sendable, Equatable {
    public var events: [FoundationModelsPhraseEvent]

    public init(events: [FoundationModelsPhraseEvent]) {
        self.events = events
    }

    public var rawPhraseOutput: RawPhraseOutput {
        RawPhraseOutput(events: events.map(\.rawPhraseEvent))
    }
}

/// Injectable seam for deterministic tests and the system Foundation Models adapter.
public protocol FoundationModelsPhraseGenerating: Sendable {
    var readiness: FoundationModelsReadiness { get }
    func generate(transcript: String, now: Date, calendar: Calendar) async throws -> FoundationModelsPhraseResponse
}

/// Production adapter. It uses typed, guided generation and then applies the
/// existing schema limits before the shared grounding validator and resolver.
public struct FoundationModelsPhraseRuntime: PhraseExtractionRuntime, Sendable {
    public let runtimeName = "Apple Foundation Models (on-device)"
    private let generator: any FoundationModelsPhraseGenerating

    public init(generator: (any FoundationModelsPhraseGenerating)? = nil) {
        self.generator = generator ?? SystemFoundationModelsPhraseGenerator()
    }

    public var readiness: FoundationModelsReadiness { generator.readiness }

    public func extract(transcript: String, now: Date, calendar: Calendar) async throws -> RawPhraseOutput {
        try Task.checkCancellation()
        guard readiness.isAvailable else {
            throw ExtractionRuntimeError.unavailable(readiness.userFacingText)
        }
        do {
            let generated = try await generator.generate(transcript: transcript, now: now, calendar: calendar)
            try Task.checkCancellation()
            return try ExtractionSchemaV2.validate(generated.rawPhraseOutput)
        } catch is CancellationError {
            throw ExtractionRuntimeError.cancelled
        } catch let error as ExtractionDecodeError {
            throw ExtractionRuntimeError.invalidOutput(error.errorDescription ?? "schema validation failed")
        } catch let error as ExtractionRuntimeError {
            throw error
        } catch {
            throw ExtractionRuntimeError.generationFailed
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable(description: "Calendar event phrases copied from the user's note.")
private struct GeneratedPhraseResponse {
    @Guide(description: "The event phrases extracted from the note, in the order mentioned.", .maximumCount(8))
    var events: [GeneratedPhraseEvent]
}

@available(macOS 26.0, *)
@Generable(description: "One event described only with phrases supported by the user's note.")
private struct GeneratedPhraseEvent {
    @Guide(description: "A concise event name using only the user's words; omit command wording and scheduling phrases.")
    var title: String?
    @Guide(description: "The user's date wording copied verbatim, never an absolute date.")
    var date_phrase: String?
    @Guide(description: "The user's clock-time wording copied verbatim; never infer AM or PM.")
    var time_phrase: String?
    @Guide(description: "The user's duration wording copied verbatim.")
    var duration_phrase: String?
    @Guide(description: "A place stated by the user, not a person name.")
    var location: String?
    @Guide(description: "The user's requested reminder lead-time wording, copied verbatim.")
    var reminder_phrase: String?
    @Guide(description: "Extra user-provided event detail copied verbatim, excluding scheduling wording.")
    var notes: String?
}

private struct SystemFoundationModelsPhraseGenerator: FoundationModelsPhraseGenerating {
    var readiness: FoundationModelsReadiness { .current }

    func generate(transcript: String, now: Date, calendar: Calendar) async throws -> FoundationModelsPhraseResponse {
        guard readiness.isAvailable else {
            throw ExtractionRuntimeError.unavailable(readiness.userFacingText)
        }
        guard #available(macOS 26.0, *) else {
            throw ExtractionRuntimeError.unavailable(FoundationModelsReadiness.unsupportedOS.userFacingText)
        }

        let isoFormatter = ISO8601DateFormatter()
        let dayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }()
        let instructions = ExtractionSchemaV2.instructions(
            referenceNowISO: isoFormatter.string(from: now),
            timeZoneID: calendar.timeZone.identifier,
            today: dayFormatter.string(from: now))
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: transcript,
            generating: GeneratedPhraseResponse.self,
            options: GenerationOptions(temperature: 0, maximumResponseTokens: 1_500))
        return FoundationModelsPhraseResponse(events: response.content.events.map { event in
            FoundationModelsPhraseEvent(
                title: event.title,
                datePhrase: event.date_phrase,
                timePhrase: event.time_phrase,
                durationPhrase: event.duration_phrase,
                location: event.location,
                reminderPhrase: event.reminder_phrase,
                notes: event.notes)
        })
    }
}
#else
private struct SystemFoundationModelsPhraseGenerator: FoundationModelsPhraseGenerating {
    var readiness: FoundationModelsReadiness { .unsupportedOS }

    func generate(transcript: String, now: Date, calendar: Calendar) async throws -> FoundationModelsPhraseResponse {
        throw ExtractionRuntimeError.unavailable(FoundationModelsReadiness.unsupportedOS.userFacingText)
    }
}
#endif
