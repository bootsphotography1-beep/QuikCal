import Foundation

/// User-facing product branding. Internal identifiers (bundle id
/// `com.quietcalendar.app`, Keychain service `com.quietcalendar.app.google-oauth`,
/// Application Support paths, defaults keys, Swift module names) intentionally
/// stay unchanged — see GOOGLE-CALENDAR-INTEGRATION.md.
public enum AppBranding: Sendable {
    /// Exact user-facing name (owner-approved 2026-11-06).
    public static let displayName = "QuikCal"
    /// Historical name, shown only where legacy data continuity is explained.
    public static let legacyName = "Quiet Calendar"
}
