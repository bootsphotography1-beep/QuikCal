import Foundation

/// Prevents writing the same confirmed event to both EventKit and Google in one Add.
public enum EventWriteDestination: Sendable, Equatable {
    case eventKit(calendarID: String)
    case google(accountID: String, calendarID: String)
}

public enum DestinationPolicy: Sendable {
    public static func resolve(
        kind: CalendarDestinationKind,
        eventKitCalendarID: String?,
        googleAccountID: String?,
        googleCalendarID: String?
    ) -> EventWriteDestination? {
        switch kind {
        case .eventKit:
            guard let eventKitCalendarID, !eventKitCalendarID.isEmpty else { return nil }
            return .eventKit(calendarID: eventKitCalendarID)
        case .google:
            guard let googleAccountID, !googleAccountID.isEmpty,
                  let googleCalendarID, !googleCalendarID.isEmpty else { return nil }
            return .google(accountID: googleAccountID, calendarID: googleCalendarID)
        }
    }

    /// Sign-in is not sync; sync is not Add. Confirmation still required for writes.
    public static func canAttemptWrite(
        destination: EventWriteDestination?,
        confirmationArmed: Bool
    ) -> Bool {
        destination != nil && confirmationArmed
    }
}

/// Capture panel presentation phases for expand/crossfade (not a dashboard).
public enum CapturePresentationPhase: String, Sendable, Equatable {
    case note
    case listening
    case parsing
    case confirmation
    case daySchedule
}
