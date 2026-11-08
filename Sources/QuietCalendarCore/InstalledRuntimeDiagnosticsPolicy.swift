import Foundation

/// Pure routing policy for the one-shot RELEASE-SAFE installed-runtime
/// diagnostics dump (2026-11-07 integration). The collector lives in the
/// app target (`InstalledRuntimeDiagnostics`); this policy is the
/// unit-testable part: flag recognition and dump-path extraction.
///
/// The dump is explicitly opt-in via
/// `--qc-runtime-diagnostics <path>`: without the flag the app starts
/// normally; with it the process writes non-secret read-only facts and
/// exits BEFORE any UI is shown (no duplicate running app).
public enum InstalledRuntimeDiagnosticsPolicy: Sendable {
    public static let flag = "--qc-runtime-diagnostics"

    /// Extracts the dump path from a raw argument list. Nil when the flag
    /// is absent, has no following value, or the value is empty.
    public static func dumpPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else { return nil }
        let path = arguments[index + 1]
        return path.isEmpty ? nil : path
    }
}
