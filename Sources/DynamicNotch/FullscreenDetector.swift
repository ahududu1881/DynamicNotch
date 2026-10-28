import AppKit

enum FullscreenDetector {
    /// True when another app has a window covering the whole screen (full-screen Space / video).
    static func isFullscreenActive(on screen: NSScreen) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        let display = CGDisplayBounds(screen.displayID)
        let safeTop = screen.safeAreaInsets.top
        let me = ProcessInfo.processInfo.processIdentifier

        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if bounds.width >= display.width - 2,
               bounds.height >= display.height - safeTop - 2,
               bounds.minY <= display.minY + safeTop + 2,
               bounds.minX <= display.minX + 2 {
                return true
            }
        }
        return false
    }
}
