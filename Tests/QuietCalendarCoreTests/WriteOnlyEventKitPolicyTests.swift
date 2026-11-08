import Testing
import Foundation
@testable import QuietCalendarCore

/// 2026-11-07 independent-review integration: honest EventKit WRITE-ONLY
/// semantics. Under write-only EventKit permits no event reads, and the
/// write path must resolve the actual default calendar at write time with
/// identifier safety. Duplicate detection under write-only must never be
/// presented as a verified "no duplicate".
struct WriteOnlyEventKitPolicyTests {

    // MARK: - Duplicate-detection capability honesty

    @Test func duplicateCheckCapabilityTracksReadPermission() {
        #expect(WriteOnlyEventKitPolicy.duplicateCheckCapability(canReadEvents: true) == .verified)
        #expect(WriteOnlyEventKitPolicy.duplicateCheckCapability(canReadEvents: false) == .unverifiable)
    }

    @Test func unverifiableNeverMeansVerifiedNoDuplicate() {
        // The whole point of the capability split: a probe that cannot read
        // is UNVERIFIABLE — it must never be reported as "verified no
        // duplicate" just because it returned false.
        let capability = WriteOnlyEventKitPolicy.duplicateCheckCapability(canReadEvents: false)
        #expect(capability == .unverifiable)
        #expect(capability != .verified)
    }

    // MARK: - Write-time default-calendar fallback (identifier safety)

    @Test func fallbackAcceptedOnlyWhenIdentifiersMatch() {
        // Matching identifier + writable default → safe fallback.
        #expect(WriteOnlyEventKitPolicy.defaultCalendarFallbackIsSafe(
            defaultCalendarID: "cal-abc",
            chosenCalendarID: "cal-abc",
            defaultCalendarIsWritable: true
        ))
        // A DIFFERENT default calendar is refused — never silently write
        // to a calendar the user didn't choose.
        #expect(!WriteOnlyEventKitPolicy.defaultCalendarFallbackIsSafe(
            defaultCalendarID: "cal-other",
            chosenCalendarID: "cal-abc",
            defaultCalendarIsWritable: true
        ))
    }

    @Test func fallbackRefusedWhenDefaultMissingOrReadOnly() {
        // No default calendar at write time → refuse.
        #expect(!WriteOnlyEventKitPolicy.defaultCalendarFallbackIsSafe(
            defaultCalendarID: nil,
            chosenCalendarID: "cal-abc",
            defaultCalendarIsWritable: true
        ))
        // Read-only default → refuse (never write into a read-only calendar).
        #expect(!WriteOnlyEventKitPolicy.defaultCalendarFallbackIsSafe(
            defaultCalendarID: "cal-abc",
            chosenCalendarID: "cal-abc",
            defaultCalendarIsWritable: false
        ))
        // Both problems at once → refuse.
        #expect(!WriteOnlyEventKitPolicy.defaultCalendarFallbackIsSafe(
            defaultCalendarID: nil,
            chosenCalendarID: "cal-abc",
            defaultCalendarIsWritable: false
        ))
    }
}
