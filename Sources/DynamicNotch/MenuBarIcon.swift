import AppKit

/// Template image for the menu bar: the notch hanging from the screen edge with a tiny waveform cut out of it.
enum MenuBarIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            // Screen edge.
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 1.5, width: 18, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()

            // Notch with flared top corners and a rounded bottom, like the real one.
            let left: CGFloat = 4.5, right: CGFloat = 15.5, top: CGFloat = 2.4, bottom: CGFloat = 13.6
            let flare: CGFloat = 1.6, radius: CGFloat = 4.2
            let path = NSBezierPath()
            path.move(to: NSPoint(x: left - flare, y: top))
            path.curve(to: NSPoint(x: left, y: top + flare), controlPoint1: NSPoint(x: left, y: top), controlPoint2: NSPoint(x: left, y: top))
            path.line(to: NSPoint(x: left, y: bottom - radius))
            path.curve(to: NSPoint(x: left + radius, y: bottom), controlPoint1: NSPoint(x: left, y: bottom), controlPoint2: NSPoint(x: left, y: bottom))
            path.line(to: NSPoint(x: right - radius, y: bottom))
            path.curve(to: NSPoint(x: right, y: bottom - radius), controlPoint1: NSPoint(x: right, y: bottom), controlPoint2: NSPoint(x: right, y: bottom))
            path.line(to: NSPoint(x: right, y: top + flare))
            path.curve(to: NSPoint(x: right + flare, y: top), controlPoint1: NSPoint(x: right, y: top), controlPoint2: NSPoint(x: right, y: top))
            path.close()
            path.fill()

            // Waveform knocked out of the shape.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let heights: [CGFloat] = [3, 5.4, 3.6]
            let barWidth: CGFloat = 1.4, gap: CGFloat = 1.2
            var x = 10 - (CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap) / 2
            for h in heights {
                NSBezierPath(roundedRect: NSRect(x: x, y: 8.4 - h / 2, width: barWidth, height: h),
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
