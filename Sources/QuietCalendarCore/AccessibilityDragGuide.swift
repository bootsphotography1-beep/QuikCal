import Foundation

/// 0.3.6 — draggable Accessibility guide + onboarding pop policy.
///
/// Pure, AppKit-free helpers so the safety-critical facts (which file is
/// dragged, where it lives, what the copy may / may not claim) are
/// unit-testable without a display. The SwiftUI tile itself lives in the
/// QuietCalendar target and uses `Bundle.main` + `NSWorkspace` only.

public enum AccessibilityDragGuidePolicy: Sendable {
    /// The only bundle identity this guide may ever export.
    public static let expectedBundleID = "com.quietcalendar.app"
    public static let expectedDisplayName = "QuikCal"
    /// Pasteboard / item-provider type for a file URL drag.
    public static let pasteboardTypeFileURL = "public.file-url"
    /// Tile icon edge (pt). Spec: proper 32–64 pt tile.
    public static let tileIconPoints: Double = 56
}

/// Where the running app bundle physically lives. Exporting a transient
/// location (mounted DMG / translocation) would create a stale Accessibility
/// entry, so those locations get install-first advice instead of a drag.
public enum AccessibilityAppLocation: String, Sendable, Equatable, CaseIterable {
    case installedApplications
    case developerBuild
    case mountedDiskImage
    case appTranslocation
    case other

    /// True for locations that must be copied to /Applications first.
    public var requiresInstallFirst: Bool {
        self == .mountedDiskImage || self == .appTranslocation
    }

    public static func classify(bundlePath: String) -> AccessibilityAppLocation {
        if bundlePath.contains("AppTranslocation") { return .appTranslocation }
        if bundlePath.hasPrefix("/Volumes/") { return .mountedDiskImage }
        if bundlePath.hasPrefix("/Applications/") { return .installedApplications }
        // Developer / QA build trees live under a `build/` (or `.build/`) dir.
        if bundlePath.contains("/build/") || bundlePath.contains("/.build/") {
            return .developerBuild
        }
        return .other
    }
}

/// Validated drag payload for the running app bundle.
public struct AccessibilityDragPayload: Sendable, Equatable {
    public var bundlePath: String
    public var bundleID: String
    public var displayName: String
    public var location: AccessibilityAppLocation

    public init(
        bundlePath: String,
        bundleID: String,
        displayName: String = AccessibilityDragGuidePolicy.expectedDisplayName,
        /// DEBUG QA fixtures only: label a location without rewriting the
        /// real running-bundle path. Production always classifies from the
        /// actual path, so no fixture can fake an install.
        locationOverride: AccessibilityAppLocation? = nil
    ) {
        self.bundlePath = bundlePath
        self.bundleID = bundleID
        self.displayName = displayName
        self.location = locationOverride ?? AccessibilityAppLocation.classify(bundlePath: bundlePath)
    }

    public var fileURL: URL { URL(fileURLWithPath: bundlePath) }
    public var pasteboardType: String { AccessibilityDragGuidePolicy.pasteboardTypeFileURL }

    /// Exports only the real running-app bundle: right bundle ID, `.app`
    /// extension, non-empty path. Never a helper, model, or other app.
    public var isValidExport: Bool {
        bundleID == AccessibilityDragGuidePolicy.expectedBundleID
            && !bundlePath.isEmpty
            && (bundlePath as NSString).pathExtension == "app"
    }

    /// A drag tile may be offered only for a valid export that does not
    /// require install-first. Mounted/translocated copies show the
    /// install-first warning instead (never a transient broken entry).
    public var offersDragTile: Bool { isValidExport && !location.requiresInstallFirst }

    public var isDeveloperBuildCopy: Bool { location == .developerBuild }
}

/// Copy for the drag step. Deliberately conditional: `AXIsProcessTrusted`
/// says whether *this process* is trusted; it does **not** reveal whether
/// QuikCal is already in the Accessibility list, so the copy never
/// claims list membership.
///
/// 0.3.7: the default page is product copy — three short steps, one tile,
/// two buttons. Manual paths, pane-name variation, authentication, list
/// membership, Mic/Calendar, and Input Monitoring live in the Details
/// disclosure only, never repeated in the body.
public enum AccessibilityDragGuideCopy: Sendable {
    // Default (visible) copy — keep this list short.
    public static let guideTitle = "Enable hold-to-talk"
    public static let guideSubtitle = "Allow QuikCal to use your shortcut."
    public static let steps: [String] = [
        "Open Accessibility settings.",
        "Drag QuikCal into the list if it’s missing.",
        "Turn on QuikCal, then return here."
    ]
    public static let tileDragLabel = "Drag to Accessibility"
    public static let appFileName = "QuikCal.app"
    public static let alreadyListedHint =
        "Already listed? Just turn on its switch."
    public static let dragDoesNotGrantShort =
        "Dragging the file doesn’t turn on Accessibility."
    public static let approveNote =
        "You’ll approve this in System Settings."
    public static let manualNextNote =
        "Next never advances on its own."
    public static let openSettings = "Open Settings"
    public static let revealApp = "Reveal App"
    public static let detailsTitle = "Details"

    // Status row.
    public static let enabledCheck = "Enabled"
    public static let notYetCheck = "Not yet"
    public static let checkAgain = "Check again"
    public static let trustedNextStep = "Enabled — you can continue."

    // Developer / install-first labels.
    public static let developerBuildNote = "Using a development copy"
    public static let installFirstTitle = "Install to Applications first."
    public static let installFirstBody =
        "Move QuikCal to Applications, then reopen it from there."
    public static let translocationBody =
        "This copy is running from a temporary location. Move QuikCal to Applications, then reopen it from there."

    // Details disclosure only — never rendered in the body.
    public static let detailsMembership =
        "QuikCal can’t see the Accessibility list, so it can’t tell whether the app is already listed. That’s why this page asks you to check."
    public static let detailsManualPath =
        "Prefer not to drag? Apple menu → System Settings → Privacy & Security → Accessibility, then add QuikCal with the list’s + button. Pane names vary slightly by macOS version."
    public static let detailsAuthentication =
        "macOS may ask you to authenticate before the switch turns on."
    public static let detailsMicCalendar =
        "Microphone and Calendar use their own normal prompts. No drag, and nothing is granted from this page."
    public static let detailsInputMonitoring =
        "Input Monitoring is required for the Fn shortcut (the listen-only key tap) and is an alternative to Accessibility for the other shortcut keys."
    public static let detailsAppLocation = "App location"

    // Drag affordance help (VoiceOver / tooltip) — still no grant claim.
    public static let tileInstruction =
        "Drag the QuikCal app file into the Accessibility list if it is missing."
    public static let tileAccessibilityLabel =
        "QuikCal app file. Drag this app file into the Accessibility list in System Settings if QuikCal is missing from the list. Dragging does not turn on Accessibility."
    public static let tileTooltip =
        "Drag the QuikCal app file into the Accessibility list if it is missing. This does not grant permission."
    public static let dragDoesNotGrant =
        "Dragging the app file does not turn on Accessibility — you still turn on the switch yourself."

    /// Word count of the default visible body copy (title through the
    /// approval note). Details disclosure and buttons are excluded.
    public static var defaultInstructionalWordCount: Int {
        let parts = [guideTitle, guideSubtitle] + steps + [
            tileDragLabel, appFileName, alreadyListedHint, dragDoesNotGrantShort,
            approveNote, manualNextNote, detailsTitle
        ]
        return parts
            .flatMap { $0.split(whereSeparator: { $0.isWhitespace }) }
            .count
    }

    /// What to show for a given trust + location state.
    public static func statusLine(
        accessibilityTrusted: Bool,
        location: AccessibilityAppLocation
    ) -> String {
        if accessibilityTrusted { return trustedNextStep }
        if location.requiresInstallFirst { return installFirstBody }
        return manualNextNote
    }
}

/// 0.3.6 onboarding root pop: once per window presentation, subtle but
/// visibly popping. Reduce Motion collapses it to a short fade.
public struct OnboardingPopAnimationSpec: Sendable, Equatable {
    public var initialScale: Double
    public var finalScale: Double
    public var durationSeconds: Double
    public var fadeOnly: Bool
    public var gentleOvershoot: Bool

    public init(initialScale: Double, finalScale: Double, durationSeconds: Double, fadeOnly: Bool, gentleOvershoot: Bool) {
        self.initialScale = initialScale
        self.finalScale = finalScale
        self.durationSeconds = durationSeconds
        self.fadeOnly = fadeOnly
        self.gentleOvershoot = gentleOvershoot
    }

    public static func spec(reduceMotion: Bool) -> OnboardingPopAnimationSpec {
        if reduceMotion {
            return OnboardingPopAnimationSpec(
                initialScale: 1.0, finalScale: 1.0,
                durationSeconds: 0.12, fadeOnly: true, gentleOvershoot: false
            )
        }
        return OnboardingPopAnimationSpec(
            initialScale: 0.94, finalScale: 1.0,
            durationSeconds: 0.28, fadeOnly: false, gentleOvershoot: true
        )
    }
}

/// One presentation identity per onboarding window presentation. Downloads,
/// focus returns, and step changes must not restart the pop: they reuse the
/// current identity. Only a genuinely new presentation (cold launch, resume
/// open, or manual Replay) gets a fresh identity.
public struct OnboardingPresentationTracker: Sendable, Equatable {
    public private(set) var presentationID: UUID

    public init(presentationID: UUID = UUID()) {
        self.presentationID = presentationID
    }

    /// Begin a new window presentation (manual Replay / fresh open).
    public mutating func newPresentation() -> UUID {
        presentationID = UUID()
        return presentationID
    }

    /// Step/download/focus updates call this and must keep the identity.
    public func refreshedWithoutReanimating() -> UUID { presentationID }
}
