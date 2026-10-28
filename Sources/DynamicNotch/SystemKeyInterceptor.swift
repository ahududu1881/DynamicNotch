import AppKit

/// NX_KEYTYPE_* codes carried by system-defined events.
enum SystemKey: Int {
    case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    case play = 16, next = 17, previous = 18, fast = 19, rewind = 20
}

/// Session event tap for volume / brightness / media keys. Returning true from the handler
/// swallows the event, which is what stops macOS from drawing its own toast.
/// Needs the Accessibility permission.
final class SystemKeyInterceptor {
    /// (key, isDown, isRepeat, modifiers) -> swallow?
    var handler: ((SystemKey, Bool, Bool, NSEvent.ModifierFlags) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<SystemKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// Re-enables the tap if the system disabled it, and drops it if the permission was revoked.
    func ensureEnabled() {
        guard let tap else { return }
        if !AXIsProcessTrusted() {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
            self.tap = nil
            self.source = nil
        } else if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14,
              let ns = NSEvent(cgEvent: event),
              ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }

        let data = ns.data1
        let code = (data & 0xFFFF0000) >> 16
        let flags = data & 0x0000FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0xA
        let isRepeat = (flags & 0x1) != 0
        guard let key = SystemKey(rawValue: code) else { return Unmanaged.passUnretained(event) }

        let swallow = MainActor.assumeIsolated { handler?(key, isDown, isRepeat, ns.modifierFlags) ?? false }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
