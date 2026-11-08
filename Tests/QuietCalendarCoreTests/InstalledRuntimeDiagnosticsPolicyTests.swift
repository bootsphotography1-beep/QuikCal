import Testing
import Foundation
@testable import QuietCalendarCore

/// 2026-11-07 integration: the release-safe installed-runtime diagnostics
/// dump is STRICTLY opt-in — the flag routes to a one-shot read-only dump
/// and never disturbs a normal launch.
struct InstalledRuntimeDiagnosticsPolicyTests {

    @Test func absentFlagMeansNormalLaunch() {
        #expect(InstalledRuntimeDiagnosticsPolicy.dumpPath(from: ["QuietCalendar"]) == nil)
        #expect(InstalledRuntimeDiagnosticsPolicy.dumpPath(from: []) == nil)
    }

    @Test func flagWithFollowingPathIsExtracted() {
        #expect(InstalledRuntimeDiagnosticsPolicy.dumpPath(
            from: ["QuietCalendar", "--qc-runtime-diagnostics", "/tmp/dump.txt"]
        ) == "/tmp/dump.txt")
        // The flag is recognized anywhere in the argument list.
        #expect(InstalledRuntimeDiagnosticsPolicy.dumpPath(
            from: ["QuietCalendar", "--other", "--qc-runtime-diagnostics", "/tmp/dump.txt"]
        ) == "/tmp/dump.txt")
    }

    @Test func flagWithoutValueOrWithEmptyValueIsRejected() {
        // Flag with nothing after it → nil (never crashes, never dumps).
        #expect(InstalledRuntimeDiagnosticsPolicy.dumpPath(
            from: ["QuietCalendar", "--qc-runtime-diagnostics"]
        ) == nil)
        // Empty path → nil.
        #expect(InstalledRuntimeDiagnosticsPolicy.dumpPath(
            from: ["QuietCalendar", "--qc-runtime-diagnostics", ""]
        ) == nil)
    }

    @Test func flagNameIsStable() {
        #expect(InstalledRuntimeDiagnosticsPolicy.flag == "--qc-runtime-diagnostics")
    }
}
