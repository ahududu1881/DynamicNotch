import XCTest
@testable import DynamicNotch

@MainActor
final class WingAndCardTests: XCTestCase {
    private let g = NotchGeometry.fallback

    private func timer(id: String = "tea", seconds: TimeInterval = 120) -> Activity {
        let now = Date()
        return Activity(id: id, symbol: "timer", text: "Tea", subtitle: nil, level: nil, tint: "#FF9F0A",
                        startDate: now, endDate: now.addingTimeInterval(seconds), expires: now.addingTimeInterval(seconds + 60))
    }

    // MARK: Cards and wings

    func testAccessoryIsAHorizontalCardThatReplacesThePill() {
        let m = NotchModel(geometry: g)
        m.showHUD(.accessory(name: "AirPods Pro", model: .airpodsPro, connected: true, battery: AccessoryBattery(left: 80, right: 78, box: 55)), duration: 2)
        XCTAssertFalse(m.hudOverLive)
        XCTAssertEqual(m.bodySize.width, 330)
        XCTAssertEqual(m.bodySize.height, g.notchHeight + 64)
        XCTAssertTrue(HUDKind.accessory(name: "", model: .airpods, connected: true, battery: nil).showsInFullscreen,
                      "headphones still announce themselves over a full-screen app")
    }

    func testLightEventsAreWingPillsAndRichOnesAreNot() {
        XCTAssertTrue(HUDKind.focus(name: "", symbol: "moon.fill", tint: "#5E5CE6", on: true).isWing)
        XCTAssertTrue(HUDKind.lock(locked: true).isWing)
        XCTAssertTrue(HUDKind.custom(symbol: "link", text: "", level: nil, tint: nil).isWing, "an icon-only toast sits in the wing")
        XCTAssertFalse(HUDKind.custom(symbol: "link", text: "Copied", level: nil, tint: nil).isWing, "text needs the row below")
        XCTAssertFalse(HUDKind.custom(symbol: "arrow.down", text: "", level: 0.4, tint: nil).isWing, "a level needs the bar")
        XCTAssertFalse(HUDKind.volume(level: 0.5, muted: false).isWing)
    }

    func testWingPillStaysInsideTheNotchHeightOverMedia() {
        let m = NotchModel(geometry: g)
        m.showHUD(.custom(symbol: "link", text: "", level: nil, tint: "#34C759"), duration: 2)
        XCTAssertEqual(m.bodySize, CGSize(width: g.notchWidth + 2 * NotchModel.wingPillWidth, height: g.notchHeight))
    }

    // MARK: Timer card

    func testANewTimerOpensItsCard() {
        let m = NotchModel(geometry: g)
        m.upsertActivity(timer())
        XCTAssertEqual(m.presentation, .hud(.timer(id: "tea")))
        XCTAssertEqual(m.bodySize.width, 300)
        XCTAssertEqual(m.bodySize.height, g.notchHeight + 64)
    }

    func testUpdatingARunningTimerDoesNotReopenTheCard() {
        let m = NotchModel(geometry: g)
        m.upsertActivity(timer())
        m.dismissHUD()
        m.upsertActivity(timer())
        XCTAssertNotEqual(m.presentation, .hud(.timer(id: "tea")))
    }

    func testAPlainActivityDoesNotOpenACard() {
        let m = NotchModel(geometry: g)
        m.upsertActivity(Activity(id: "dl", symbol: "arrow.down", text: "Downloading", subtitle: nil, level: 0.3, tint: nil, expires: Date().addingTimeInterval(60)))
        XCTAssertNotEqual(m.presentation, .hud(.timer(id: "dl")))
    }

    func testPausingFreezesTheTimeLeftAndResumingContinuesIt() async throws {
        let m = NotchModel(geometry: g)
        m.upsertActivity(timer(seconds: 120))
        m.toggleTimerPause(id: "tea")
        let paused = try XCTUnwrap(m.activities.first)
        XCTAssertTrue(paused.isPaused)
        let frozen = paused.remaining(at: Date())
        XCTAssertEqual(paused.remaining(at: Date().addingTimeInterval(500)), frozen, accuracy: 0.01, "time stands still while paused")
        XCTAssertLessThanOrEqual(abs(frozen - 120), 1.5)

        m.toggleTimerPause(id: "tea")
        let resumed = try XCTUnwrap(m.activities.first)
        XCTAssertFalse(resumed.isPaused)
        XCTAssertEqual(resumed.remaining(at: Date()), frozen, accuracy: 0.5)
    }

    func testAPausedTimerIsNotExpiredEvenAfterItsOriginalEndDate() {
        let m = NotchModel(geometry: g)
        m.upsertActivity(timer(seconds: 30))
        m.toggleTimerPause(id: "tea")
        m.expireActivities(now: Date().addingTimeInterval(3_600))
        XCTAssertEqual(m.activities.count, 1)
    }

    func testCancellingEndsTheTimerAndClosesTheCard() {
        let m = NotchModel(geometry: g)
        m.upsertActivity(timer())
        m.cancelTimer(id: "tea")
        XCTAssertTrue(m.activities.isEmpty)
        XCTAssertNotEqual(m.presentation, .hud(.timer(id: "tea")))
    }

    func testTappingTheTimerPillOpensTheCard() {
        let m = NotchModel(geometry: g)
        m.upsertActivity(timer())
        m.dismissHUD()
        XCTAssertEqual(m.presentation, .live)
        m.primaryClick()
        XCTAssertEqual(m.presentation, .hud(.timer(id: "tea")))
    }

    func testPausingAnUnknownOrNonTimerActivityIsHarmless() {
        let m = NotchModel(geometry: g)
        m.toggleTimerPause(id: "nope")
        m.upsertActivity(Activity(id: "dl", symbol: "arrow.down", text: "x", subtitle: nil, level: nil, tint: nil, expires: Date().addingTimeInterval(60)))
        m.toggleTimerPause(id: "dl")
        XCTAssertFalse(m.activities.first?.isPaused ?? true)
    }

    // MARK: Lock

    func testLockIndicatorUpdatesInPlaceWhenTheMacUnlocks() {
        let m = NotchModel(geometry: g)
        m.showHUD(.lock(locked: true), duration: 600)
        XCTAssertEqual(m.presentation, .hud(.lock(locked: true)))
        m.showHUD(.lock(locked: false), duration: 1.3)
        XCTAssertEqual(m.presentation, .hud(.lock(locked: false)), "same channel: the padlock opens instead of queueing")
        XCTAssertEqual(HUDKind.lock(locked: true).channel, HUDKind.lock(locked: false).channel)
    }

    func testLockShowsOverFullScreenAndNeverHidesVolume() {
        XCTAssertTrue(HUDKind.lock(locked: true).showsInFullscreen)
        let m = NotchModel(geometry: g)
        m.showHUD(.lock(locked: true), duration: 600)
        m.showHUD(.volume(level: 0.4, muted: false), duration: 1)
        XCTAssertEqual(m.presentation, .hud(.volume(level: 0.4, muted: false)), "volume (high) preempts the padlock")
    }

    func testPausedTimerRemainingNeverGoesNegativeOrNaN() {
        var a = timer()
        a.pausedRemaining = -5
        XCTAssertEqual(a.remaining(), 0)
    }
}
