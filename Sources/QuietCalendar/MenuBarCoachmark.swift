import AppKit
import SwiftUI
import QuietCalendarCore

/// Real AppKit coachmark anchored to the **actual** `NSStatusItem.button`
/// frame (converted to screen coordinates — never a hardcoded pixel position,
/// never screenshot matching, never private API). See
/// `MenuBarCoachmarkGeometry` (QuietCalendarCore) for the pure, unit-tested
/// layout policy; this class only renders + owns dismissal.
///
/// 0.3.5: the target is validated against the **full** screen frame
/// (`NSScreen.frame`, menu bar included) — `visibleFrame` only places the
/// callout. The overlay is a transparent, click-through drawing surface
/// (ring + arrow only, no dim, no fullscreen mask) at `.floating` level —
///
/// - Renders a restrained sage ring around the real target + an arrow from
///   the card to the target centre + a compact card: a left-click opens
///   capture; right-click / Control-click opens Settings. An accessible
///   "Open Settings" button opens configuration directly.
/// - No TCC / ScreenCapture / Accessibility permission needed: only our own
///   window geometry. No other app is inspected or masked, no key
///   interception beyond local Escape handling for this card.
/// - Overlay ignores mouse events — clicks on the menu-bar target pass
///   through. Escape / Got It / Open Settings dismiss it; opening capture
///   or quitting also dismisses it (see AppDelegate). No auto-close timer.
/// - Dismissing the hint never touches `onboardingCompleted`.
/// - Reduced motion: static (no fade/scale animation). Re-anchors on display
///   changes while visible. Fallback card (no ring) when the frame is
///   unavailable, hidden, non-finite, zero-size, or offscreen.
@MainActor
final class MenuBarCoachmarkPresenter: NSObject {
    static let shared = MenuBarCoachmarkPresenter()

    /// Sage accent shared with the product theme (GradientOptionSelector).
    static let sage = NSColor(srgbRed: 0.45, green: 0.62, blue: 0.52, alpha: 1)

    private var overlayPanel: NSPanel?
    private var cardPanel: NSPanel?
    private var escapeMonitor: Any?
    private var screenChangeObserver: NSObjectProtocol?
    private(set) var isVisible = false

    private var targetButtonProvider: (() -> NSButton?)?
    private var onOpenSettings: (() -> Void)?
    private var lastFullFrame: NSRect = .zero
    private var lastVisibleFrame: NSRect = .zero
    private var lastLayout: MenuBarCoachmarkLayout?

    /// Bounded callout: ~340 pt wide; height fitted to content (see render).
    private let cardWidth: Double = 340
    private let cardHeightEstimate: Double = 196

    #if DEBUG
    /// DEBUG QA host only: the card window for `screencapture -l` (own window).
    var qaDebugWindow: NSWindow? { cardPanel }
    /// DEBUG QA host only: overlay window (ring + arrow surface).
    var qaDebugOverlayWindow: NSWindow? { overlayPanel }
    /// DEBUG QA host only: last layout + real target frame actually used.
    var qaDebugLayout: MenuBarCoachmarkLayout? { lastLayout }
    var qaDebugFullFrame: NSRect { lastFullFrame }
    var qaDebugVisibleFrame: NSRect { lastVisibleFrame }
    var qaDebugTargetFrame: NSRect? {
        guard lastLayout?.targetCenter != nil else { return nil }
        // The status-item window's frame IS the item's screen frame (the
        // documented anchor for status-item popovers). Converting the
        // button bounds to nil yields a bogus (0,0) rect for status items.
        guard let button = targetButtonProvider?(), let window = button.window else { return nil }
        return window.frame
    }
    #endif

    /// Present anchored to `button` (real frame). If `button` is nil, the
    /// fallback card is shown at the top of the main screen's visible frame.
    /// `fullFrame` must be the hosting screen's full frame (menu bar
    /// included) for the anchored branch; `visibleFrame` places the card.
    func present(
        anchoredTo button: NSButton?,
        visibleFrame: NSRect,
        fullFrame: NSRect? = nil,
        onOpenSettings: @escaping () -> Void
    ) {
        dismiss()
        targetButtonProvider = { [weak button] in button }
        self.onOpenSettings = onOpenSettings
        let full = fullFrame ?? visibleFrame
        lastFullFrame = full
        lastVisibleFrame = visibleFrame

        let targetFrame: ScreenRect? = button.flatMap { btn in
            // Use the status-item WINDOW frame (screen coords, menu bar
            // included). `btn.convert(btn.bounds, to: nil)` returns a bogus
            // (0,0) rect for status-item buttons — their window is not a
            // normal on-screen window in that coordinate path.
            guard let window = btn.window, window.frame.size.width > 0, window.frame.size.height > 0 else { return nil }
            let r = window.frame
            guard r.size.width > 0, r.size.height > 0,
                  r.origin.x.isFinite, r.origin.y.isFinite,
                  r.size.width.isFinite, r.size.height.isFinite else { return nil }
            return ScreenRect(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.size.width), height: Double(r.size.height))
        }
        // Two-pass: layout with the estimate to learn anchored/fallback,
        // build the SwiftUI card, measure its fitted height, then re-layout
        // with the real height so the arrow base meets the actual card top.
        let prelim = MenuBarCoachmarkGeometry.layout(
            targetScreenFrame: targetFrame,
            visibleFrame: MenuBarCoachmarkPresenter.screenRect(of: visibleFrame),
            fullFrame: MenuBarCoachmarkPresenter.screenRect(of: full),
            cardSize: ScreenSize(width: cardWidth, height: cardHeightEstimate)
        )
        let hosting = makeCardHosting(anchored: prelim.isAnchored)
        hosting.view.layoutSubtreeIfNeeded()
        // +18: preferredContentSize under-reports the SwiftUI card by the
        // panel's fitting delta (measured: 96 reported vs 114 rendered).
        let fittedHeight = max(hosting.preferredContentSize.height + 18, 114)
        let layout: MenuBarCoachmarkLayout
        if abs(fittedHeight - cardHeightEstimate) > 2 {
            layout = MenuBarCoachmarkGeometry.layout(
                targetScreenFrame: targetFrame,
                visibleFrame: MenuBarCoachmarkPresenter.screenRect(of: visibleFrame),
                fullFrame: MenuBarCoachmarkPresenter.screenRect(of: full),
                cardSize: ScreenSize(width: cardWidth, height: fittedHeight)
            )
        } else {
            layout = prelim
        }
        lastLayout = layout
        render(layout: layout, visibleFrame: visibleFrame, fullFrame: full, hosting: hosting)
        registerDismissalObservers()
    }

    private func makeCardHosting(anchored: Bool) -> NSHostingController<CoachmarkCardView> {
        let cardView = CoachmarkCardView(
            anchored: anchored,
            onOpenSettings: { [weak self] in self?.openSettingsTapped() },
            onGotIt: { [weak self] in self?.gotItTapped() }
        )
        let hosting = NSHostingController(rootView: cardView)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        return hosting
    }

    private func render(layout: MenuBarCoachmarkLayout, visibleFrame: NSRect, fullFrame: NSRect, hosting: NSHostingController<CoachmarkCardView>) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Transparent click-through drawing surface over the FULL frame
        // (menu bar included) — ring + arrow only. No dim, no mask.
        let overlay = NSPanel(
            contentRect: NSRect(origin: fullFrame.origin, size: fullFrame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlay.level = .floating
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isFloatingPanel = true
        overlay.hidesOnDeactivate = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlay.orderFrontRegardless()

        let ringView = CoachmarkRingView(frame: NSRect(origin: .zero, size: fullFrame.size))
        ringView.ringRect = layout.ringRect.map {
            NSRect(x: $0.x - Double(fullFrame.origin.x), y: $0.y - Double(fullFrame.origin.y), width: $0.width, height: $0.height)
        }
        if let tip = layout.arrowTip, let base = layout.arrowBaseCenter {
            ringView.arrowTip = NSPoint(x: tip.x - Double(fullFrame.origin.x), y: tip.y - Double(fullFrame.origin.y))
            ringView.arrowBaseCenter = NSPoint(x: base.x - Double(fullFrame.origin.x), y: base.y - Double(fullFrame.origin.y))
        }
        ringView.anchored = layout.isAnchored
        overlay.contentView = ringView

        // Card panel (interactive), bounded ~340 pt wide, fitted height.
        let card = NSPanel(
            contentRect: NSRect(x: layout.cardOrigin.x, y: layout.cardOrigin.y, width: layout.cardSize.width, height: layout.cardSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        card.level = .floating
        card.isFloatingPanel = true
        card.hasShadow = true
        card.isOpaque = false
        card.backgroundColor = .clear
        card.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        card.contentViewController = hosting

        overlayPanel = overlay
        cardPanel = card
        isVisible = true

        if reduceMotion {
            card.orderFrontRegardless()
        } else {
            card.alphaValue = 0
            card.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                card.animator().alphaValue = 1
            }
        }
    }

    private func registerDismissalObservers() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.dismiss() }
            return nil
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible else { return }
                // Re-anchor once from the live button frame (safe one-shot refresh).
                if let button = self.targetButtonProvider?(),
                   let screen = button.window?.screen ?? NSScreen.main {
                    let full = screen.frame
                    let visible = screen.visibleFrame
                    self.present(
                        anchoredTo: button,
                        visibleFrame: visible,
                        fullFrame: full,
                        onOpenSettings: self.onOpenSettings ?? {}
                    )
                }
            }
        }
    }

    static func screenRect(of rect: NSRect) -> ScreenRect {
        ScreenRect(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.size.width), height: Double(rect.size.height))
    }

    @objc private func openSettingsTapped() {
        let action = onOpenSettings
        dismiss()
        action?()
    }

    @objc private func gotItTapped() {
        dismiss()
    }

    func dismiss() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
        overlayPanel?.orderOut(nil)
        cardPanel?.orderOut(nil)
        overlayPanel = nil
        cardPanel = nil
        targetButtonProvider = nil
        onOpenSettings = nil
        isVisible = false
    }
}

/// Draws the ring + arrow around the real status-item frame (overlay-local
/// coords, origin = full-frame origin). Restrained sage, no flash/animation.
final class CoachmarkRingView: NSView {
    var ringRect: NSRect?
    var arrowTip: NSPoint?
    var arrowBaseCenter: NSPoint?
    var anchored = false

    override func draw(_ dirtyRect: NSRect) {
        guard anchored, let ringRect, ringRect.width > 0, ringRect.height > 0 else { return }
        let sage = MenuBarCoachmarkPresenter.sage
        // Soft halo first, then the crisp ring.
        let halo = NSBezierPath(roundedRect: ringRect.insetBy(dx: -4, dy: -4), xRadius: 13, yRadius: 13)
        sage.withAlphaComponent(0.18).setStroke()
        halo.lineWidth = 7
        halo.stroke()
        let path = NSBezierPath(roundedRect: ringRect, xRadius: 10, yRadius: 10)
        sage.withAlphaComponent(0.95).setStroke()
        path.lineWidth = 2.5
        path.stroke()
        // Arrow: filled triangle from card edge (base) to ring edge (tip),
        // pointing at the real target centre.
        if let tip = arrowTip, let base = arrowBaseCenter {
            let dx = base.x - tip.x
            let dy = base.y - tip.y
            let len = max(hypot(dx, dy), 1)
            let ux = dx / len, uy = dy / len
            let px = -uy, py = ux
            let halfBase: CGFloat = 6
            let arrow = NSBezierPath()
            arrow.move(to: tip)
            arrow.line(to: NSPoint(x: base.x + px * halfBase, y: base.y + py * halfBase))
            arrow.line(to: NSPoint(x: base.x - px * halfBase, y: base.y - py * halfBase))
            arrow.close()
            sage.withAlphaComponent(0.95).setFill()
            arrow.fill()
        }
    }
}

/// Compact SwiftUI callout card — charcoal surface, sage accent, bounded
/// width, generous padding. Same card used for anchored and fallback;
/// fallback adds one short "how to find it" line.
struct CoachmarkCardView: View {
    var anchored: Bool
    var onOpenSettings: () -> Void
    var onGotIt: () -> Void

    @ScaledMetric private var titleSize: CGFloat = 17
    @ScaledMetric private var bodySize: CGFloat = 13.5
    @ScaledMetric private var fallbackSize: CGFloat = 12.5

    private var sage: Color { Color(red: 0.45, green: 0.62, blue: 0.52) }

    var body: some View {
#if DEBUG
        // DEBUG-only larger-text QA fixture (0.3.5) — compiled out of Release.
        cardContent
            .dynamicTypeSize(qaTextSize)
#else
        cardContent
#endif
    }

#if DEBUG
    private var qaTextSize: DynamicTypeSize {
        if let qa = QAHostRouter.parse(arguments: ProcessInfo.processInfo.arguments),
           let ts = qa.textSize {
            switch ts {
            case "xxxlarge": return .accessibility1
            case "large": return .large
            default: return .large
            }
        }
        return .large
    }
#endif

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(anchored ? "Your QuikCal is here" : "Find QuikCal in the menu bar")
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Click to add an event. Right-click for Settings.")
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !anchored {
                Text("If the menu bar is hidden, open Settings below — you can also find QuikCal under System Settings → Control Center → Menu Bar.")
                    .font(.system(size: fallbackSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(CoachmarkPrimaryPillStyle())
                    .accessibilityLabel("Open Settings")
                Button("Got it", action: onGotIt)
                    .buttonStyle(CoachmarkSecondaryPillStyle())
                    .accessibilityLabel("Dismiss menu bar hint")
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.16, green: 0.17, blue: 0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(sage.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

/// Sage pill buttons matching the onboarding controls (same capsule shape,
/// same sage fill / quiet secondary surface) — replaces the stock
/// `.borderedProminent` / `.bordered` styles that read as raw grey controls.
private struct CoachmarkPrimaryPillStyle: ButtonStyle {
    private var sage: Color { Color(red: 0.45, green: 0.62, blue: 0.52) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.85 : 1))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(sage.opacity(configuration.isPressed ? 0.75 : 1))
            )
    }
}

private struct CoachmarkSecondaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08))
            )
    }
}
