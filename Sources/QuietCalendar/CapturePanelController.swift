import AppKit
import SwiftUI
import QuietCalendarCore

/// Borderless floating capture panel — Spotlight-inspired overlay over foreground apps.
///
/// Presentation policy lives in `CapturePanelPresentationPolicy` (unit-tested).
/// Does not use screen-saver / shield window levels, Accessibility to modify other apps,
/// or claim lock-screen / secure-desktop coverage.
@MainActor
final class CapturePanelController: NSObject, NSWindowDelegate {
    private(set) var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private let defaults: UserDefaults
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    var onEscape: (() -> Void)?
    /// Outside click (local or global) while visible — draft preserved; no calendar write.
    var onOutsideClick: (() -> Void)?
    /// Fired after the panel is key so the SwiftUI field can take first responder.
    var onDidPresent: (() -> Void)?
    var isVisible: Bool { panel?.isVisible == true }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func attach<Content: View>(rootView: Content) {
        // Single panel for the process lifetime — never spawn duplicates.
        if panel != nil {
            updateRootView(rootView)
            return
        }
        let panel = makePanel()
        let host = NSHostingView(rootView: AnyView(rootView))
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView(frame: .zero)
        guard let content = panel.contentView else { return }
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        self.panel = panel
        self.hosting = host
        panel.delegate = self
    }

    func updateRootView<Content: View>(_ rootView: Content) {
        hosting?.rootView = AnyView(rootView)
    }

    func toggle(animate: Bool = true) {
        guard let panel else { return }
        if panel.isVisible {
            dismiss(animate: animate, reason: .toggleClosed)
        } else {
            present(animate: animate)
        }
    }

    func present(animate: Bool = true) {
        guard let panel else { return }
        precondition(CapturePanelPresentationPolicy.preferredLevelIsAllowed)
        precondition(!CapturePanelPresentationPolicy.claimsSecureDesktopOrLockScreenOverlay)
        precondition(!CapturePanelPresentationPolicy.usesAccessibilityToModifyOtherApps)

        applyPresentationPolicy(to: panel)

        if CapturePanelPresentationPolicy.centerOnActiveDisplayEachInvocation {
            topAnchorOnActiveDisplay()
        }

        // Order above the frontmost app first, then take key for the text field.
        if CapturePanelPresentationPolicy.orderFrontRegardlessOnPresent {
            panel.orderFrontRegardless()
        }
        panel.makeKeyAndOrderFront(nil)
        if CapturePanelPresentationPolicy.mayActivateAppForKeyFocus {
            NSApp.activate(ignoringOtherApps: true)
        }

        if animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }

        installOutsideClickMonitors()

        // Defer focus until after AppKit finishes key-window transfer.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            if CapturePanelPresentationPolicy.orderFrontRegardlessOnPresent {
                panel.orderFrontRegardless()
            }
            panel.makeKeyAndOrderFront(nil)
            self.onDidPresent?()
        }
    }

    func dismiss(animate: Bool = true, reason: CapturePanelDismissReason = .toggleClosed) {
        guard let panel, panel.isVisible else { return }
        precondition(CapturePanelPresentationPolicy.preservesDraft(on: reason))
        precondition(!CapturePanelPresentationPolicy.writesCalendar(on: reason))

        removeOutsideClickMonitors()

        let finish = {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
        if animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                }
            })
        } else {
            finish()
        }
    }

    /// Anchors the panel top-center, 12 pt below the target display's safe
    /// visible area — the approved voice/glass placement. The capture panel
    /// is the successor surface to the listening bar, so it keeps the SAME
    /// top+center anchor (grows downward, never re-centered) instead of
    /// the old vertical centering. Callers may still drag the panel; the
    /// next summon re-anchors.
    func topAnchorOnActiveDisplay() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let mouseIndex = screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) }
        guard let index = CapturePanelPresentationPolicy.activeDisplayIndex(
            mouseScreenIndex: mouseIndex,
            screenCount: screens.count
        ) else { return }
        let screen = screens[index]
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let width = size.width
        let x = visible.minX + max(0, (visible.width - width) / 2)
        let y = visible.maxY - size.height - QuietDesign.Voice.Metric.topInset
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        defaults.set(true, forKey: AppPreferenceKey.panelDidCenterOnce)
    }

    /// Centers on the display under the mouse (else primary). Called on every summon.
    func centerOnActiveDisplay() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let mouseIndex = screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) }
        guard let index = CapturePanelPresentationPolicy.activeDisplayIndex(
            mouseScreenIndex: mouseIndex,
            screenCount: screens.count
        ) else { return }
        let screen = screens[index]
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let centered = CapturePanelPresentationPolicy.centeredOrigin(
            visibleFrameMinX: visible.minX,
            visibleFrameMinY: visible.minY,
            visibleFrameWidth: visible.width,
            visibleFrameHeight: visible.height,
            panelWidth: size.width,
            panelHeight: size.height
        )
        panel.setFrameOrigin(NSPoint(x: centered.x, y: centered.y))
        // Legacy key: still stamped so older prefs readers see “has been placed”.
        defaults.set(true, forKey: AppPreferenceKey.panelDidCenterOnce)
    }

    /// Compatibility shim — onboarding finish still calls this; always re-centers.
    func centerOnActiveScreenIfNeeded(force: Bool = false) {
        _ = force
        centerOnActiveDisplay()
    }

    private func applyPresentationPolicy(to panel: NSPanel) {
        let flags = CapturePanelPresentationPolicy.collectionBehavior
        precondition(
            flags.isValidPerAppleSpacesExclusivity,
            "canJoinAllSpaces and moveToActiveSpace are mutually exclusive (Apple Spaces collection behaviors)"
        )
        panel.isFloatingPanel = true
        panel.level = nsWindowLevel(for: CapturePanelPresentationPolicy.preferredWindowLevel)
        panel.collectionBehavior = nsCollectionBehavior(flags)
        panel.hidesOnDeactivate = CapturePanelPresentationPolicy.hidesOnDeactivate
        panel.isMovableByWindowBackground = CapturePanelPresentationPolicy.isMovableByWindowBackground
        panel.becomesKeyOnlyIfNeeded = false
    }

    private func makePanel() -> NSPanel {
        let style: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
        let panel = KeyablePanel(
            // 0.3.21 Spotlight capsule: single-line capture bar default
            // (640×64); the view's measured requests grow it downward.
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 64),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        applyPresentationPolicy(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.sharingType = .readWrite
        panel.animationBehavior = .utilityWindow
        return panel
    }

    private func nsWindowLevel(for choice: CapturePanelWindowLevelChoice) -> NSWindow.Level {
        switch choice {
        case .floating:
            return .floating
        case .normal:
            return .normal
        case .modalPanel:
            return .modalPanel
        case .statusBar:
            return .statusBar
        case .screenSaver:
            // Mapped only so tests can assert we never select this path at runtime.
            return .screenSaver
        }
    }

    private func nsCollectionBehavior(
        _ flags: CapturePanelPresentationPolicy.CollectionBehaviorFlags
    ) -> NSWindow.CollectionBehavior {
        var behavior = NSWindow.CollectionBehavior()
        if flags.canJoinAllSpaces { behavior.insert(.canJoinAllSpaces) }
        if flags.fullScreenAuxiliary { behavior.insert(.fullScreenAuxiliary) }
        if flags.moveToActiveSpace { behavior.insert(.moveToActiveSpace) }
        return behavior
    }

    // MARK: Outside-click dismiss (draft-safe)

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handlePotentialOutsideClick()
            return event
        }
        // Global mouse monitors do not require Accessibility; they cannot swallow the click.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.handlePotentialOutsideClick()
        }
    }

    private func removeOutsideClickMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func handlePotentialOutsideClick() {
        guard let panel, panel.isVisible else { return }
        let point = NSEvent.mouseLocation
        if panel.frame.contains(point) { return }
        // Ignore the menu-bar / status-item strip so left-click toggle does not
        // race: mouseDown dismisses then mouseUp re-presents.
        if isPointInMenuBarStrip(point) { return }
        // Clicks on our own non-capture windows (Settings / onboarding) should not
        // wipe the overlay via outside-click — those windows take key deliberately.
        if let key = NSApp.keyWindow, key !== panel, key.isVisible {
            return
        }
        onOutsideClick?()
    }

    private func isPointInMenuBarStrip(_ point: NSPoint) -> Bool {
        for screen in NSScreen.screens where NSMouseInRect(point, screen.frame, false) {
            // Area above `visibleFrame` is menu bar (and notch region on some displays).
            if point.y > screen.visibleFrame.maxY {
                return true
            }
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onDidPresent?()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Escape / outside-click own dismiss. Do not dismiss solely because Settings
        // became key. If another app activates, treat as outside (Spotlight-like).
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if panel.isKeyWindow { return }
            if NSApp.keyWindow != nil { return }
            if NSApp.isActive { return }
            self.onOutsideClick?()
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeOutsideClickMonitors()
    }

}

/// NSPanel that can become key for text input / Escape.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { CapturePanelPresentationPolicy.becomesKeyForTextInput }
    override var canBecomeMain: Bool { CapturePanelPresentationPolicy.canBecomeMainWindow }

    override func cancelOperation(_ sender: Any?) {
        if let controller = delegate as? CapturePanelController {
            controller.onEscape?()
        } else {
            orderOut(nil)
        }
    }
}
