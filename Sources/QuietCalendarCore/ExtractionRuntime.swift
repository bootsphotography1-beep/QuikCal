import Foundation

/// Phrase extraction runtime. No tools are offered to the model; generated data
/// always passes the same strict schema, grounding validator, resolver, and
/// explicit confirmation gate.
public protocol PhraseExtractionRuntime: Sendable {
    var runtimeName: String { get }
    func extract(transcript: String, now: Date, calendar: Calendar) async throws -> RawPhraseOutput
}

public enum ExtractionRuntimeError: Error, Equatable, Sendable, LocalizedError {
    case unavailable(String)
    case invalidOutput(String)
    case generationFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "Apple Intelligence is unavailable — used the built-in parser. (\(detail))"
        case .invalidOutput(let detail): return "Apple Intelligence returned invalid fields (\(detail)) — used the built-in parser."
        case .generationFailed: return "Apple Intelligence could not complete extraction — used the built-in parser."
        case .cancelled: return "Extraction cancelled."
        }
    }
}
