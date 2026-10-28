import AppKit

/// Where the (real or simulated) notch sits on a screen.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var centerX: CGFloat
    var hasHardwareNotch: Bool

    /// Used when no display is attached (clamshell, display sleep) and in tests.
    static let fallback = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                        notchWidth: 186, notchHeight: 32, centerX: 756, hasHardwareNotch: true)
}

extension NotchGeometry {
    init(screen: NSScreen) {
        screenFrame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            hasHardwareNotch = true
            notchHeight = screen.safeAreaInsets.top
            // +1 hides the antialiased hardware edge.
            notchWidth = right.minX - left.maxX + 1
            centerX = (left.maxX + right.minX) / 2
        } else {
            hasHardwareNotch = false
            notchHeight = max(NSStatusBar.system.thickness, 24)
            notchWidth = 170
            centerX = screen.frame.midX
        }
    }

    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
