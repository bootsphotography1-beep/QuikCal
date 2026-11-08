// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuietCalendar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuietCalendarCore", targets: ["QuietCalendarCore"]),
        .executable(name: "QuietCalendar", targets: ["QuietCalendar"])
    ],
    dependencies: [
        // Sparkle 2 in-app updates (owner-approved 2026-11-08): manual
        // "Check for Updates…" from the GitHub Releases appcast; automatic
        // checks stay opt-in via Sparkle's own second-launch consent prompt;
        // never silent download/install.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .target(name: "QuietCalendarCore"),
        .executableTarget(
            name: "QuietCalendar",
            dependencies: [
                "QuietCalendarCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "QuietCalendarCoreTests",
            dependencies: ["QuietCalendarCore"],
            // Read on disk via #filePath (not bundled); keep SPM from treating as unhandled.
            exclude: ["Fixtures"]
        )
    ]
)