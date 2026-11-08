import Foundation

/// A writable calendar as exposed by macOS (EventKit). No provider is assumed:
/// whatever the configured macOS accounts expose is what the user can pick.
public struct CalendarChoice: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var sourceTitle: String

    public init(id: String, title: String, sourceTitle: String) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
    }

    public var displayName: String {
        sourceTitle.isEmpty ? title : "\(sourceTitle) — \(title)"
    }
}

public enum CalendarSelectionState: Equatable, Sendable {
    /// Nothing stored yet (first run, or user cleared the destination).
    case noneSelected
    /// Stored identifier still resolves to a writable calendar.
    case valid(CalendarChoice)
    /// Stored identifier no longer exists or is no longer writable (deleted, revoked, read-only).
    case missing(storedID: String)

    public var choice: CalendarChoice? {
        if case .valid(let choice) = self { return choice }
        return nil
    }

    public var needsAttention: Bool {
        switch self {
        case .valid: return false
        case .noneSelected, .missing: return true
        }
    }
}

/// Pure resolution of the persisted destination identifier against the calendars macOS exposes.
/// Kept out of the EventKit layer so it can be tested without any calendar permission.
public enum CalendarSelection {
    public static func resolve(storedID: String?, choices: [CalendarChoice]) -> CalendarSelectionState {
        guard let storedID, !storedID.isEmpty else { return .noneSelected }
        if let match = choices.first(where: { $0.id == storedID }) {
            return .valid(match)
        }
        return .missing(storedID: storedID)
    }
}
