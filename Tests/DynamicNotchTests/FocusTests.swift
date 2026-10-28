import XCTest
@testable import DynamicNotch

final class FocusTests: XCTestCase {
    private func assertions(_ mode: String?) -> Data {
        let records: [[String: Any]] = mode.map { [["assertionDetails": ["assertionDetailsModeIdentifier": $0]]] } ?? []
        return try! JSONSerialization.data(withJSONObject: ["data": [["storeAssertionRecords": records]]])
    }

    private let configs = try! JSONSerialization.data(withJSONObject: [
        "data": [["modeConfigurations": [
            "com.apple.focus.work": ["mode": ["name": "Work", "symbolImageName": "briefcase.fill", "tintColorName": "systemBlueColor"]],
            "custom.mode": ["mode": ["name": "Okuma Odası", "symbolImageName": "no.such.symbol", "tintColorName": "systemPinkColor"]],
        ]]]
    ])

    func testActiveModeDetection() {
        XCTAssertEqual(FocusParser.activeModeID(assertions: assertions("com.apple.focus.work")), "com.apple.focus.work")
        XCTAssertNil(FocusParser.activeModeID(assertions: assertions(nil)))
        XCTAssertNil(FocusParser.activeModeID(assertions: Data()))
        XCTAssertNil(FocusParser.activeModeID(assertions: Data("[1,2".utf8)))
    }

    func testModeDetailsFromConfigurationsWithFallbacks() {
        let work = FocusParser.mode(id: "com.apple.focus.work", configurations: configs)
        XCTAssertEqual(work.name, "Work")
        XCTAssertEqual(work.symbol, "briefcase.fill")
        XCTAssertEqual(work.tint, "#0A84FF")

        let custom = FocusParser.mode(id: "custom.mode", configurations: configs)
        XCTAssertEqual(custom.name, "Okuma Odası")
        XCTAssertEqual(custom.symbol, "moon.fill", "invalid symbols fall back")
        XCTAssertEqual(custom.tint, "#FF375F")

        let unknown = FocusParser.mode(id: "x.y", configurations: nil)
        XCTAssertEqual(unknown.symbol, "moon.fill")
        XCTAssertEqual(FocusParser.mode(id: "com.apple.donotdisturb.mode.default", configurations: Data("garbage".utf8)).symbol, "moon.fill")
    }

    func testMonitorReportsOnlyChanges() throws {
        let dir = NSTemporaryDirectory() + "focus-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func write(_ mode: String?) { try! assertions(mode).write(to: URL(fileURLWithPath: dir + "/Assertions.json")) }
        try configs.write(to: URL(fileURLWithPath: dir + "/ModeConfigurations.json"))

        let monitor = FocusMonitor(directory: dir)
        XCTAssertNil(monitor.pollOnce(), "no file yet")
        write("com.apple.focus.work")
        XCTAssertNil(monitor.pollOnce(), "the state at launch is only a baseline")

        write(nil)
        XCTAssertEqual(monitor.pollOnce(), .off(FocusParser.mode(id: "com.apple.focus.work", configurations: configs)))
        XCTAssertNil(monitor.pollOnce())

        write("com.apple.donotdisturb.mode.default")
        guard case .on(let dnd)? = monitor.pollOnce() else { return XCTFail() }
        XCTAssertEqual(dnd.symbol, "moon.fill")

        write("com.apple.focus.work")   // switching straight from one mode to another
        guard case .on(let work)? = monitor.pollOnce() else { return XCTFail() }
        XCTAssertEqual(work.name, "Work")
    }

    @MainActor
    func testFocusHUDGrowsDownwardAndKeepsTheNotchWidth() {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(.focus(name: "Work", symbol: "briefcase.fill", tint: "#0A84FF", on: true), duration: 2, id: "focus")
        XCTAssertEqual(m.bodySize.width, NotchGeometry.fallback.notchWidth)
        XCTAssertEqual(m.bodySize.height, NotchGeometry.fallback.notchHeight + HUDKind.focus(name: "Work", symbol: "briefcase.fill", tint: "#0A84FF", on: true).rowHeight)
    }
}
