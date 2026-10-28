import AppKit
import SwiftUI

/// Owns the panel, keeps it glued to the notch and routes the mouse, scroll wheel and wake events.
@MainActor
final class NotchController {
    let model: NotchModel

    /// True while the notch is out of the way: a full-screen app is active, the user switched it off or no display exists.
    var isSuspended: Bool { fullscreenActive || userDisabled || screen == nil }
    private(set) var userDisabled = false
    private(set) var fullscreenActive = false
    private var hudVisible = false
    private var hudGraceUntil = Date.distantPast

    /// Whether a HUD of this kind may be shown right now. In a full-screen app only system state changes
    /// (volume, brightness, Focus, accessories) get through; the rest waits.
    func canShow(_ kind: HUDKind) -> Bool {
        guard !userDisabled, screen != nil else { return false }
        return !fullscreenActive || kind.showsInFullscreen
    }

    /// Fraction of full volume per scroll event; positive = louder.
    var onScrollVolume: ((Double) -> Void)?

    private var panel: NotchPanel!
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var collapseTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var fullscreenTimer: Timer?
    private var scrollX: CGFloat = 0
    private var lastScroll = Date.distantPast
    private var lastSwipe = Date.distantPast

    private let panelWidth: CGFloat = 560
    private let panelHeight: CGFloat = 420

    init() {
        let screen = NotchGeometry.preferredScreen()
        self.screen = screen
        model = NotchModel(geometry: screen.map(NotchGeometry.init(screen:)) ?? .fallback)
    }

    func start() {
        panel = NotchPanel(frame: panelFrame())
        let host = NSHostingView(rootView: NotchRootView(model: model))
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        panel.ignoresMouseEvents = true
        model.onHUDVisibility = { [weak self] visible in
            guard let self else { return }
            self.hudVisible = visible
            // Keep the panel up long enough for the closing animation before hiding it again.
            if !visible { self.hudGraceUntil = Date().addingTimeInterval(NotchModel.restFadeDelay + 0.5) }
            self.refreshVisibility()
        }

        installMonitors()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibility() }
            }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Displays come back a moment after the wake notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self?.screenParametersChanged() }
            }
        }
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibility() }
        }
        refreshVisibility()
    }

    func setEnabled(_ enabled: Bool) {
        userDisabled = !enabled
        if userDisabled { resetModel() }
        refreshVisibility()
    }

    // MARK: Geometry

    private func panelFrame() -> NSRect {
        let g = model.geometry
        return NSRect(x: g.centerX - panelWidth / 2, y: g.screenFrame.maxY - panelHeight,
                      width: panelWidth, height: panelHeight)
    }

    private func screenParametersChanged() {
        screen = NotchGeometry.preferredScreen()
        let geometry = screen.map(NotchGeometry.init(screen:)) ?? .fallback
        if geometry != model.geometry { model.geometry = geometry }
        panel.setFrame(panelFrame(), display: true)
        refreshVisibility()
    }

    /// Screen-space rectangle currently covered by the notch shape.
    private func hitRect() -> NSRect {
        let g = model.geometry
        let size = model.bodySize
        let width = size.width + 2 * model.topRadius
        var rect = NSRect(x: g.centerX - width / 2, y: g.screenFrame.maxY - size.height, width: width, height: size.height)
        rect = rect.insetBy(dx: -4, dy: -4)
        rect.size.height += 4 // keep the very top edge of the screen inside
        return rect
    }

    // MARK: Mouse and scroll

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        add(global: moves) { [weak self] _ in self?.mouseChanged() }
        add(local: moves) { [weak self] event in self?.mouseChanged(); return event }
        add(global: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.clickedElsewhere() }
        add(global: .scrollWheel) { [weak self] event in self?.scrolled(event) }
        add(local: .scrollWheel) { [weak self] event in self?.scrolled(event); return event }
    }

    private func add(global mask: NSEvent.EventTypeMask, _ handler: @escaping @MainActor (NSEvent) -> Void) {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { handler(event) }
        }) { monitors.append(m) }
    }

    private func add(local mask: NSEvent.EventTypeMask, _ handler: @escaping @MainActor (NSEvent) -> NSEvent?) {
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { handler(event) }
        }) { monitors.append(m) }
    }

    private func mouseChanged() {
        guard !isSuspended else { return }
        let inside = hitRect().contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        model.setHovering(inside)

        // Optional: open the player by hovering the live pill.
        if Settings.shared.expandOnHover, inside, model.presentation == .live, model.media != nil {
            if hoverTask == nil {
                hoverTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.hoverTask = nil
                    if self.hitRect().contains(NSEvent.mouseLocation), self.model.presentation == .live { self.model.expand() }
                }
            }
        } else {
            hoverTask?.cancel(); hoverTask = nil
        }

        guard model.expanded else { collapseTask?.cancel(); collapseTask = nil; return }
        if inside {
            collapseTask?.cancel(); collapseTask = nil
        } else if collapseTask == nil {
            let delay = Settings.shared.autoCollapseDelay
            collapseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.collapseTask = nil
                if !self.hitRect().contains(NSEvent.mouseLocation), !self.model.isInteracting { self.model.collapse() }
            }
        }
    }

    private func clickedElsewhere() {
        guard model.expanded, !hitRect().contains(NSEvent.mouseLocation) else { return }
        model.collapse()
    }

    /// Vertical scroll over the notch changes the volume; horizontal swipes in the player skip tracks.
    private func scrolled(_ event: NSEvent) {
        guard Settings.shared.scrollGestures, !isSuspended, hitRect().contains(NSEvent.mouseLocation) else { return }
        let now = Date()
        if now.timeIntervalSince(lastScroll) > 0.35 { scrollX = 0 }
        lastScroll = now

        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard dx.isFinite, dy.isFinite else { return }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8

        if abs(dy) > abs(dx) {
            // Swipe up = louder, whatever the natural-scrolling setting is.
            let up = event.isDirectionInvertedFromDevice ? -dy : dy
            onScrollVolume?(Double(up * scale) * 0.004)
        } else if model.expanded, model.media != nil {
            scrollX += event.isDirectionInvertedFromDevice ? -dx * scale : dx * scale
            guard now.timeIntervalSince(lastSwipe) > 0.7, abs(scrollX) > 70 else { return }
            lastSwipe = now
            model.onCommand?(scrollX > 0 ? .next : .previous)
            scrollX = 0
        }
    }

    // MARK: Visibility (full screen, user switch, no display)

    private func refreshVisibility() {
        let fullscreen = screen.map(FullscreenDetector.isFullscreenActive(on:)) ?? false
        if fullscreen != fullscreenActive {
            fullscreenActive = fullscreen
            if fullscreen {
                // Entering full screen: drop the pill and player right away; HUDs may still come.
                resetModel()
                panel.ignoresMouseEvents = true
            }
            model.suppressPill = fullscreen
        }

        let transient = hudVisible || Date() < hudGraceUntil
        let shouldShow = !userDisabled && screen != nil && (!fullscreenActive || transient)
        if shouldShow, !panel.isVisible {
            panel.orderFrontRegardless()
        } else if !shouldShow, panel.isVisible {
            resetModel()
            panel.orderOut(nil)
        }
    }

    private func resetModel() {
        model.reset()
        hudVisible = false
        hudGraceUntil = .distantPast
    }
}
