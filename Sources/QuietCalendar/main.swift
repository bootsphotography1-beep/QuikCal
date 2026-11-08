import AppKit
import QuietCalendarCore

// One-shot RELEASE-SAFE installed-runtime diagnostics (2026-11-07
// integration): with `--qc-runtime-diagnostics <path>` the process writes
// non-secret read-only facts (AX trust, Fn tap install attempt, EventKit
// authorization/default availability, client ID + secret PRESENCE) and
// exits BEFORE the app starts — no UI, no prompts, no duplicate running
// app, no prefs/TCC/Keychain writes.
if let dumpPath = InstalledRuntimeDiagnosticsPolicy.dumpPath(from: CommandLine.arguments) {
    do {
        try InstalledRuntimeDiagnostics.write(to: dumpPath)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("qc-runtime-diagnostics failed: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
