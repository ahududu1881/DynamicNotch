import AppKit

enum HotkeyAction { case playPause, next, previous, volumeUp, volumeDown, togglePlayer }

/// Global shortcuts (Control + Option + key). Works through the Accessibility permission.
///   Space: play/pause   ← →: previous / next   ↑ ↓: volume   N: open or close the player
final class HotkeyMonitor {
    var handler: ((HotkeyAction) -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Settings.shared.hotkeys, !event.isARepeat || Self.action(for: event).map({ [.volumeUp, .volumeDown].contains($0) }) == true,
                  let action = Self.action(for: event) else { return }
            DispatchQueue.main.async { self?.handler?(action) }
        }
    }

    static func action(for event: NSEvent) -> HotkeyAction? {
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        guard flags == [.control, .option] else { return nil }
        switch event.keyCode {
        case 49: return .playPause      // space
        case 124: return .next          // →
        case 123: return .previous      // ←
        case 126: return .volumeUp      // ↑
        case 125: return .volumeDown    // ↓
        case 45: return .togglePlayer   // N
        default: return nil
        }
    }
}
