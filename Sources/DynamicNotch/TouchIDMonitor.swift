import AppKit

/// Watches for the system's Touch ID dialog. macOS shows it in a window owned by `coreautha`.
/// Whether the fingerprint was accepted is not published anywhere, so it is inferred: the dialog
/// disappears on its own after a match, while cancelling needs a click or a key press.
enum TouchIDPrompt {
    static let ownerNames: Set<String> = ["coreautha", "LocalAuthenticationRemoteService"]

    static func isVisible(in windows: [[String: Any]]) -> Bool {
        windows.contains { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String else { return false }
            return ownerNames.contains(owner)
        }
    }
}

struct TouchIDStateMachine {
    enum Event: Equatable { case started, success, dismissed }

    private var shownSince: Date?
    /// A click or key press this close to the dialog closing means the user cancelled or typed a password.
    static let interactionWindow: TimeInterval = 1.0
    /// Shorter than this is a flicker, not a real prompt.
    static let minimumDuration: TimeInterval = 0.15

    mutating func update(visible: Bool, now: Date, lastInteraction: Date?) -> Event? {
        switch (shownSince, visible) {
        case (nil, true):
            shownSince = now
            return .started
        case (let since?, false):
            shownSince = nil
            if now.timeIntervalSince(since) < Self.minimumDuration { return .dismissed }
            if let last = lastInteraction, now.timeIntervalSince(last) <= Self.interactionWindow, last >= since.addingTimeInterval(-0.05) {
                return .dismissed
            }
            return .success
        default:
            return nil
        }
    }
}

final class TouchIDMonitor {
    var onEvent: ((TouchIDStateMachine.Event) -> Void)?

    private var machine = TouchIDStateMachine()
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastInteraction: Date?

    func start() {
        guard timer == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .keyDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.lastInteraction = Date() }) {
            monitors.append(m)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.05
    }

    private func poll() {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        if let event = machine.update(visible: TouchIDPrompt.isVisible(in: list), now: Date(), lastInteraction: lastInteraction) {
            onEvent?(event)
        }
    }
}
