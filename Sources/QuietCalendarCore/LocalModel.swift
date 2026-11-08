import Foundation
import CoreFoundation

/// Parse failure for the retained strict legacy JSON validator. This validator
/// is not a runtime; production extraction uses native Foundation Models types.
public enum LocalModelFailure: Error, Equatable, Sendable {
    case invalidOutput(String)
}

/// Strict schema validation for model output. Anything not exactly in the expected
/// shape is rejected so malformed output can never reach EventKit.
public enum StrictIntentJSON {
    public static let allowedKeys: Set<String> = [
        "title", "date", "start_time", "duration_minutes", "location"
    ]
    public static let minimumDurationMinutes = 5
    public static let maximumDurationMinutes = 720
    public static let maximumHorizonYears = 10

    public static func intent(fromJSONText text: String, now: Date, calendar: Calendar) throws -> EventIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalModelFailure.invalidOutput("empty output")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        } catch {
            throw LocalModelFailure.invalidOutput("not valid JSON")
        }
        guard let dictionary = object as? [String: Any] else {
            throw LocalModelFailure.invalidOutput("expected a JSON object")
        }

        if let extra = Set(dictionary.keys).subtracting(allowedKeys).sorted().first {
            throw LocalModelFailure.invalidOutput("unexpected field “\(extra)”")
        }
        guard dictionary.keys.contains("title") else {
            throw LocalModelFailure.invalidOutput("missing title")
        }

        let title = try string(dictionary["title"], field: "title", maximum: 200, allowEmpty: false)

        var dateComponents: DateComponents?
        if let raw = dictionary["date"], !(raw is NSNull) {
            guard let value = raw as? String else {
                throw LocalModelFailure.invalidOutput("date must be a string or null")
            }
            guard let components = parseISODate(value) else {
                throw LocalModelFailure.invalidOutput("date must be YYYY-MM-DD")
            }
            guard let resolved = calendar.date(from: components),
                  calendar.component(.year, from: resolved) == components.year,
                  calendar.component(.month, from: resolved) == components.month,
                  calendar.component(.day, from: resolved) == components.day
            else {
                throw LocalModelFailure.invalidOutput("date does not exist")
            }
            let years = abs(calendar.dateComponents([.year], from: now, to: resolved).year ?? 0)
            guard years <= maximumHorizonYears else {
                throw LocalModelFailure.invalidOutput("date is too far away")
            }
            dateComponents = components
        }

        var timeComponents: DateComponents?
        if let raw = dictionary["start_time"], !(raw is NSNull) {
            guard let value = raw as? String, let parsed = parseTime(value) else {
                throw LocalModelFailure.invalidOutput("start_time must be HH:MM or null")
            }
            var components = DateComponents()
            components.hour = parsed.hour
            components.minute = parsed.minute
            components.second = 0
            timeComponents = components
        }

        var durationMinutes: Int?
        if let raw = dictionary["duration_minutes"], !(raw is NSNull) {
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw LocalModelFailure.invalidOutput("duration_minutes must be an integer or null")
            }
            let value = number.doubleValue
            guard value == value.rounded() else {
                throw LocalModelFailure.invalidOutput("duration_minutes must be a whole number")
            }
            guard value >= Double(minimumDurationMinutes), value <= Double(maximumDurationMinutes) else {
                throw LocalModelFailure.invalidOutput("duration_minutes must be between \(minimumDurationMinutes) and \(maximumDurationMinutes)")
            }
            durationMinutes = Int(value)
        }

        var location: String?
        if let raw = dictionary["location"], !(raw is NSNull) {
            location = try string(raw, field: "location", maximum: 200, allowEmpty: true)
        }

        return EventIntent(
            title: title,
            date: dateComponents,
            time: timeComponents,
            durationSeconds: durationMinutes.map { $0 * 60 },
            location: location
        )
    }

    private static func string(_ raw: Any?, field: String, maximum: Int, allowEmpty: Bool) throws -> String {
        guard let value = raw as? String else {
            throw LocalModelFailure.invalidOutput("\(field) must be a string")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !allowEmpty && trimmed.isEmpty {
            throw LocalModelFailure.invalidOutput("\(field) must not be empty")
        }
        guard trimmed.count <= maximum else {
            throw LocalModelFailure.invalidOutput("\(field) is too long")
        }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw LocalModelFailure.invalidOutput("\(field) contains control characters")
        }
        return trimmed
    }

    static func parseISODate(_ value: String) -> DateComponents? {
        guard value.count == 10 else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return components
    }

    static func parseTime(_ value: String) -> (hour: Int, minute: Int)? {
        guard value.count == 5 else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return (hour, minute)
    }
}
