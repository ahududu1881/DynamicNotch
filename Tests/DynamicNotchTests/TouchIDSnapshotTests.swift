import XCTest
import SwiftUI
@testable import DynamicNotch

/// Renders contact sheets of the Touch ID animation so the look can be reviewed without the notch.
@MainActor
final class TouchIDSnapshotTests: XCTestCase {
    private func frame(_ offset: Double, success: Bool, settleAt: Double = 0) -> some View {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let now = base.addingTimeInterval(offset)
        return Canvas { gc, size in
            TouchIDScan.draw(&gc, size: size, now: now, appeared: base,
                             successAt: success ? base.addingTimeInterval(settleAt) : nil)
        }
        .frame(width: 58, height: 58)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    func testRenderContactSheet() throws {
        guard let out = ProcessInfo.processInfo.environment["TOUCHID_SNAPSHOT"] else { return }
        // Row 1: appearing and waiting (with the sheen moving up). Rows 2-4: after the fingerprint is accepted at t = 3.
        let waiting = [0.05, 0.15, 0.3, 0.6, 0.9, 1.1, 1.3, 1.6]
        let success = [0.0, 0.06, 0.12, 0.18, 0.24, 0.32, 0.4, 0.48,
                       0.56, 0.64, 0.72, 0.8, 0.88, 0.96, 1.02, 1.08,
                       1.14, 1.2, 1.26, 1.32, 1.38, 1.46, 1.6, 2.0]
        let sheet = VStack(spacing: 6) {
            HStack(spacing: 6) { ForEach(waiting, id: \.self) { self.frame($0, success: false) } }
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(success[(row * 8)..<(row * 8 + 8)], id: \.self) { self.frame(3 + $0, success: true, settleAt: 3) }
                }
            }
        }
        .padding(8).background(Color(white: 0.15))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out))
    }
}
