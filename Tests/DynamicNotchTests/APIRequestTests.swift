import XCTest
@testable import DynamicNotch

final class APIRequestTests: XCTestCase {
    func testToastRequiresTextOrLevel() {
        XCTAssertThrowsError(try ToastRequest.parse([:], defaultDuration: 2))
        XCTAssertNoThrow(try ToastRequest.parse(["text": "hi"], defaultDuration: 2))
        XCTAssertNoThrow(try ToastRequest.parse(["level": 0.4], defaultDuration: 2))
    }

    func testToastClampsAndDefaults() throws {
        let r = try ToastRequest.parse(["level": 7, "duration": 1e12, "symbol": "no.such.symbol", "tint": "nope"], defaultDuration: 2)
        XCTAssertEqual(r.level, 1)
        XCTAssertEqual(r.duration, 10)
        XCTAssertEqual(r.symbol, "bell.fill")
        XCTAssertNil(r.tint)
        XCTAssertEqual(try ToastRequest.parse(["text": "x", "duration": -3], defaultDuration: 2).duration, 0.5)
        XCTAssertEqual(try ToastRequest.parse(["text": "x"], defaultDuration: 3.3).duration, 3.3)
    }

    func testToastValidSymbolAndTintArePreserved() throws {
        let r = try ToastRequest.parse(["text": "x", "symbol": "star.fill", "tint": "#FF9500"], defaultDuration: 2)
        XCTAssertEqual(r.symbol, "star.fill")
        XCTAssertEqual(r.tint, "#FF9500")
    }

    func testToastTruncatesLongText() throws {
        XCTAssertEqual(try ToastRequest.parse(["text": String(repeating: "A", count: 5000)], defaultDuration: 2).text.count, 80)
    }

    func testWrongTypesAreRejected() {
        for body: [String: Any] in [["text": 5], ["text": "x", "level": "high"], ["text": "x", "level": true],
                                    ["text": "x", "symbol": []], ["text": "x", "tint": [:]], ["text": "x", "id": 4]] {
            XCTAssertThrowsError(try ToastRequest.parse(body, defaultDuration: 2), "\(body)")
        }
    }

    func testNonFiniteNumbersAreRejected() {
        XCTAssertThrowsError(try ToastRequest.parse(["text": "x", "level": Double.nan], defaultDuration: 2))
        XCTAssertThrowsError(try ToastRequest.parse(["text": "x", "level": Double.infinity], defaultDuration: 2))
    }

    func testIdentifiers() {
        XCTAssertNoThrow(try ActivityRequest.parse(["id": "build:42.v1-ok_x"]))
        for bad in ["", "has space", "emoji🎧", String(repeating: "a", count: 65), "semi;colon"] {
            XCTAssertThrowsError(try ActivityRequest.parse(["id": bad]), bad)
        }
        XCTAssertThrowsError(try ActivityRequest.parse([:]))
    }

    func testActivityDefaults() throws {
        let a = try ActivityRequest.parse(["id": "x", "level": -4, "ttl": 1e12])
        XCTAssertEqual(a.level, 0)
        XCTAssertEqual(a.ttl, 86_400)
        XCTAssertEqual(a.symbol, "circle.fill")
    }

    func testTimerBounds() {
        XCTAssertThrowsError(try TimerRequest.parse([:]))
        XCTAssertThrowsError(try TimerRequest.parse(["seconds": 0]))
        XCTAssertThrowsError(try TimerRequest.parse(["seconds": -1]))
        XCTAssertThrowsError(try TimerRequest.parse(["seconds": 86_401]))
        XCTAssertThrowsError(try TimerRequest.parse(["seconds": "10"]))
        XCTAssertEqual(try TimerRequest.parse(["seconds": 90]).id, "timer")
        XCTAssertEqual(try TimerRequest.parse(["seconds": 90]).tint, "#FF9F0A")
    }

    func testHexColors() {
        XCTAssertNotNil(Color(hex: "#FF9500"))
        XCTAssertNotNil(Color(hex: "ff9500"))
        XCTAssertNil(Color(hex: "#FFF"))
        XCTAssertNil(Color(hex: "#GGGGGG"))
        XCTAssertNil(Color(hex: ""))
    }

    func testFormatTime() {
        XCTAssertEqual(formatTime(0), "0:00")
        XCTAssertEqual(formatTime(65.9), "1:05")
        XCTAssertEqual(formatTime(3600), "60:00")
        XCTAssertEqual(formatTime(-4), "0:00")
        XCTAssertEqual(formatTime(.nan), "0:00")
        XCTAssertEqual(formatTime(.infinity), "0:00")
    }
}
import SwiftUI
