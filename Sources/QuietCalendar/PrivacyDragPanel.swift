import AppKit
import SwiftUI
import Combine
import QuietCalendarCore

// MARK: - Compact floating drag-assist panel (0.3.16, Hex reference)
//
// A SMALL dark rounded floating panel that appears alongside/below the
// System Settings window while the user adds QuikCal to the CORRECT
// privacy pane for their shortcut (Fn → Input Monitoring; other keys →
// Accessibility). Per the owner's Hex reference:
// - arrow-up instruction: "Drag QuikCal into the [pane] list above"
// - ONE inset draggable app-icon + name row (real file URL of the
//   running bundle — /Applications when installed)
// - NOT a giant embedded guide; it never positions itself over System
//   Settings' list controls and never hijacks focus (nonactivating panel)
// - short lifecycle: shown only from an explicit Open Settings action,
//   hidden on completion (real probe says granted), Close, or app
//   termination — never an always-on global overlay
// - dragging never grants anything: the caption says so, and the real
//   per-app probe remains the only authority.

@MainActor
final class PrivacyDragPanelPresenter: NSObject {
    static let shared = PrivacyDragPanelPresenter()

    private var panel: NSPanel?
    private var requiredCapability: HoldToTalkCapability = .accessibility
    private var cancellables: Set<AnyCancellable> = []
    private(set) var isVisible = false

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    /// Present the drag-assist panel for the capability that actually
    /// gates the current shortcut. No-op for install-first copies (a
    /// transient bundle path must never be dragged into a privacy list —
    /// those surfaces show the install-first warning instead).
    func present(for capability: HoldToTalkCapability, monitor: HoldToTalkMonitor) {
        let payload = AccessibilityDragGuideInfo.current()
        guard payload.offersDragTile else { return }
        dismiss()
        requiredCapability = capability

        // Completion = the REAL per-app probe says granted (never a drag
        // callback). Auto-hide the moment the required capability lands.
        monitor.$accessibilityTrusted
            .combineLatest(monitor.$inputMonitoringAllowed)
            .receive(on: RunLoop.main)
            .sink { [weak self] axTrusted, inputMonitoring in
                guard let self, self.isVisible else { return }
                switch self.requiredCapability {
                case .accessibility:
                    if axTrusted { self.dismiss() }
                case .inputMonitoring:
                    if inputMonitoring { self.dismiss() }
                }
            }
            .store(in: &cancellables)

        let paneKind: PrivacyPaneKind = capability == .inputMonitoring ? .inputMonitoring : .accessibility
        let content = PrivacyDragPanelContent(
            paneName: paneKind.paneDisplayName,
            payload: payload,
            icon: AccessibilityDragGuideInfo.appIcon(for: payload, realBundleURL: Bundle.main.bundleURL),
            onClose: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingController(rootView: content)
        hosting.view.layoutSubtreeIfNeeded()
        let fitted = hosting.view.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: PrivacyDragPanelLayout.panelWidth,
                height: max(fitted.height, PrivacyDragPanelLayout.minPanelHeight)
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setFrame(
            PrivacyDragPanelLayout.placement(
                panelSize: panel.frame.size,
                mouseLocation: NSEvent.mouseLocation
            ),
            display: false
        )
        self.panel = panel
        isVisible = true
        // Nonactivating: orderFrontRegardless keeps System Settings key —
        // the panel never steals focus from the pane the user is using.
        panel.orderFrontRegardless()
    }

    func dismiss() {
        cancellables.removeAll()
        if let panel {
            panel.orderOut(nil)
            panel.contentViewController = nil
        }
        panel = nil
        isVisible = false
    }
}

/// Pure placement policy for the drag panel: bottom-center of the screen
/// containing the mouse (the user just clicked Open…, so that is the
/// screen with System Settings), clamped to that screen's visible frame
/// and inset above the bottom edge — never over the Settings list.
enum PrivacyDragPanelLayout {
    static let panelWidth: Double = 300
    static let minPanelHeight: Double = 120
    static let bottomInset: Double = 24

    /// Bottom-center of the mouse's screen, clamped to its visible frame.
    static func placement(panelSize: NSSize, mouseLocation: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else {
            return NSRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height)
        }
        let visible = screen.visibleFrame
        let width = min(panelSize.width, visible.width)
        let height = min(panelSize.height, visible.height)
        let x = visible.midX - width / 2
        let y = visible.minY + bottomInset
        // Clamp fully inside the visible frame (multi-display safe).
        let clampedX = min(max(x, visible.minX), visible.maxX - width)
        let clampedY = min(max(y, visible.minY), visible.maxY - height)
        return NSRect(x: clampedX, y: clampedY, width: width, height: height)
    }
}

/// The panel's SwiftUI content: dark matte rounded card, arrow-up
/// instruction naming the correct pane, one inset draggable app row, an
/// honest no-grant caption, and a close control.
private struct PrivacyDragPanelContent: View {
    var paneName: String
    var payload: AccessibilityDragPayload
    var icon: NSImage
    var onClose: () -> Void

    private enum PanelTone {
        static let matte = Color(red: 0.11, green: 0.11, blue: 0.12)
        static let inset = Color.white.opacity(0.08)
        static let stroke = Color.white.opacity(0.10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .accessibilityHidden(true)
                Text("Drag QuikCal into the \(paneName) list above")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close drag helper")
            }
            HStack(spacing: 10) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(payload.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(AccessibilityDragGuideCopy.appFileName)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                Spacer(minLength: 4)
                Image(systemName: "hand.draw")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .accessibilityHidden(true)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PanelTone.inset)
            )
            .onDrag {
                // Real file URL of the running bundle only — no copying,
                // no moving, no grant. The drop itself is never treated as
                // permission; the live probe is the only authority.
                AccessibilityDragGuideInfo.itemProvider(for: payload)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("QuikCal app file")
            .accessibilityHint("Drag this app file into the \(paneName) list in System Settings if QuikCal is missing. Dragging does not grant permission.")
            Text("Dragging only adds the file — turn on its switch yourself. QuikCal checks the real permission when you return.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: PrivacyDragPanelLayout.panelWidth)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanelTone.matte)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PanelTone.stroke, lineWidth: 1)
        )
    }
}
