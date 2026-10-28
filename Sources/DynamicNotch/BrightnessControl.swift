import AppKit

/// Built-in display brightness through the private DisplayServices framework.
final class BrightnessControl {
    static let shared = BrightnessControl()

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let getFn: GetFn?
    private let setFn: SetFn?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        getFn = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
        setFn = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }
    }

    var builtInDisplay: CGDirectDisplayID? {
        NSScreen.screens.map(\.displayID).first { CGDisplayIsBuiltin($0) != 0 }
    }

    var isAvailable: Bool { getFn != nil && setFn != nil && builtInDisplay != nil }

    /// True when the pointer is on the built-in display (the one the brightness keys should drive).
    var pointerOnBuiltIn: Bool {
        guard let builtIn = builtInDisplay else { return false }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.displayID == builtIn
    }

    func level() -> Double? {
        guard let getFn, let display = builtInDisplay else { return nil }
        var v: Float = 0
        return getFn(display, &v) == 0 ? Double(v) : nil
    }

    func set(_ level: Double) {
        guard let setFn, let display = builtInDisplay else { return }
        _ = setFn(display, Float(min(max(level, 0), 1)))
    }
}
