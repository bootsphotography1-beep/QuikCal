import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuietCalendarCore

/// AppKit glue for the drag guide. Read-only: it only ever exports
/// `Bundle.main.bundleURL` (verified against `com.quietcalendar.app` by the
/// core payload). It never moves, copies, or deletes the app, never edits
/// TCC, and never grants Accessibility.

enum AccessibilityDragGuideInfo: Sendable {
    /// The real running-app payload. System APIs are read-only here.
    static func current(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleID: String? = Bundle.main.bundleIdentifier,
        displayName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? AccessibilityDragGuidePolicy.expectedDisplayName
    ) -> AccessibilityDragPayload {
        AccessibilityDragPayload(
            bundlePath: bundleURL.path,
            bundleID: bundleID ?? "",
            displayName: displayName
        )
    }

    /// DEBUG QA fixture only: label a location for screenshots without
    /// changing the exported app path. The payload still points at the real
    /// running bundle, so no fixture can masquerade as an installed app.
    static func fixture(location raw: String, realBundleURL: URL) -> AccessibilityDragPayload {
        let override: AccessibilityAppLocation?
        switch raw {
        case "installed": override = .installedApplications
        case "dev": override = .developerBuild
        case "dmg": override = .mountedDiskImage
        case "translocated": override = .appTranslocation
        default: override = nil
        }
        return AccessibilityDragPayload(
            bundlePath: realBundleURL.path,
            bundleID: AccessibilityDragGuidePolicy.expectedBundleID,
            displayName: AccessibilityDragGuidePolicy.expectedDisplayName,
            locationOverride: override
        )
    }

    static func appIcon(for payload: AccessibilityDragPayload, realBundleURL: URL) -> NSImage {
        // Real bundle icon when the fixture path does not exist on disk.
        let path = FileManager.default.fileExists(atPath: payload.bundlePath)
            ? payload.bundlePath : realBundleURL.path
        return NSWorkspace.shared.icon(forFile: path)
    }

    /// Native file drag: `public.file-url` payload for the app bundle.
    /// Wrapping the bundle `NSURL` registers the file-URL representation —
    /// the destination receives the URL itself (no copying/moving of the
    /// app, no delete-on-drop semantics).
    static func itemProvider(for payload: AccessibilityDragPayload) -> NSItemProvider {
        NSItemProvider(object: payload.fileURL as NSURL)
    }

    static func revealInFinder(_ payload: AccessibilityDragPayload) {
        NSWorkspace.shared.activateFileViewerSelecting([payload.fileURL])
    }
}

private enum GuideTone {
    /// Same soft sage as the onboarding palette (kept local: the palette
    /// enum in OnboardingWindowController is file-private).
    static let accent = Color(red: 0.45, green: 0.62, blue: 0.52)
}

/// Three short numbered steps. Product copy only — the technical details
/// live in `AccessibilityGuideDetails`.
struct AccessibilityStepsList: View {
    var steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GuideTone.accent)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(GuideTone.accent.opacity(0.16)))
                        .accessibilityHidden(true)
                    Text(step)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.primary.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1). \(step)")
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
    }
}

/// Compact, prominent draggable tile (56 pt icon). Only the tile drags —
/// the rest of the window stays a normal movable window.
///
/// 2026-11-07 owner correction: `onDragStarted` lets the hosting
/// Accessibility step enter its bounded waiting/checking window when a
/// drag begins. A drag START (or end) never implies the grant — success
/// is claimed only from a real trusted probe; the drop itself is not
/// observable from this side and is never inferred.
struct DraggableAppIconTile: View {
    var payload: AccessibilityDragPayload
    var icon: NSImage
    var isQAFixture: Bool = false
    /// Fired when a drag session begins (the tile was lifted). Optional.
    var onDragStarted: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(AccessibilityDragGuideCopy.tileDragLabel)
                    .font(.system(size: 15, weight: .semibold))
                Text(AccessibilityDragGuideCopy.appFileName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                if payload.isDeveloperBuildCopy {
                    // Concise label; the actual path lives in Details.
                    Text(AccessibilityDragGuideCopy.developerBuildNote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if isQAFixture {
                Text("QA fixture")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
            Image(systemName: "hand.draw")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 480, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .onDrag {
            // Drag START only begins the step's waiting/checking window —
            // it never grants, and no drop callback is interpreted as
            // success (the real AX probe is the only authority).
            onDragStarted?()
            return AccessibilityDragGuideInfo.itemProvider(for: payload)
        }
        .help(AccessibilityDragGuideCopy.tileTooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AccessibilityDragGuideCopy.tileAccessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Drag the QuikCal app file into the Accessibility list in System Settings. Keyboard alternative: Reveal App, then add it with the normal Add button.")
    }
}

/// Install-first warning for mounted-DMG / translocated copies. No drag
/// tile is offered here — exporting a transient path would strand the
/// Accessibility entry. The single Reveal App button lives in the parent
/// action row, so it is never duplicated inside this card.
struct InstallFirstWarning: View {
    var payload: AccessibilityDragPayload
    var isQAFixture: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(AccessibilityDragGuideCopy.installFirstTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                    if isQAFixture {
                        Text("QA fixture")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.12)))
                    }
                }
                Text(payload.location == .appTranslocation
                     ? AccessibilityDragGuideCopy.translocationBody
                     : AccessibilityDragGuideCopy.installFirstBody)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
    }
}

/// Bounded advanced details: manual path, pane-name variation,
/// authentication, why membership is unknowable, Mic/Calendar prompts,
/// Input Monitoring caveat, and the real running app path. The body page
/// never repeats this copy.
struct AccessibilityGuideDetails: View {
    var payload: AccessibilityDragPayload
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    detailParagraph(AccessibilityDragGuideCopy.detailsMembership)
                    detailParagraph(AccessibilityDragGuideCopy.detailsManualPath)
                    detailParagraph(AccessibilityDragGuideCopy.detailsAuthentication)
                    detailParagraph(AccessibilityDragGuideCopy.detailsMicCalendar)
                    detailParagraph(AccessibilityDragGuideCopy.detailsInputMonitoring)
                    Text(AccessibilityDragGuideCopy.detailsAppLocation)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(payload.bundlePath)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 6)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Bounded so expanding Details can never push the primary
            // buttons off the page; the indicator stays visible.
            .frame(maxHeight: 96)
            .scrollIndicators(.visible)
        } label: {
            Text(AccessibilityDragGuideCopy.detailsTitle)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 480, alignment: .leading)
        .accessibilityHint("Shows the manual path, macOS pane-name differences, authentication, microphone and calendar prompts, Input Monitoring, and the app location.")
    }

    private func detailParagraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
