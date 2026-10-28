import XCTest
@testable import DynamicNotch

final class TouchIDTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testDetectsThePromptWindow() {
        XCTAssertTrue(TouchIDPrompt.isVisible(in: [["kCGWindowOwnerName": "Finder"], ["kCGWindowOwnerName": "coreautha"]]))
        XCTAssertFalse(TouchIDPrompt.isVisible(in: [["kCGWindowOwnerName": "Finder"], ["other": 1]]))
        XCTAssertFalse(TouchIDPrompt.isVisible(in: []))
    }

    func testPromptThatClosesByItselfIsSuccess() {
        var m = TouchIDStateMachine()
        XCTAssertEqual(m.update(visible: true, now: t0, lastInteraction: nil), .started)
        XCTAssertNil(m.update(visible: true, now: t0.addingTimeInterval(0.5), lastInteraction: nil))
        XCTAssertEqual(m.update(visible: false, now: t0.addingTimeInterval(1.2), lastInteraction: nil), .success)
        XCTAssertNil(m.update(visible: false, now: t0.addingTimeInterval(2), lastInteraction: nil))
    }

    func testClickOrKeyJustBeforeClosingMeansCancelled() {
        var m = TouchIDStateMachine()
        _ = m.update(visible: true, now: t0, lastInteraction: nil)
        XCTAssertEqual(m.update(visible: false, now: t0.addingTimeInterval(3), lastInteraction: t0.addingTimeInterval(2.8)), .dismissed)
    }

    func testOldInteractionsDoNotCount() {
        var m = TouchIDStateMachine()
        _ = m.update(visible: true, now: t0, lastInteraction: nil)
        // clicked long before the prompt, and clicked while it was up but well before it closed
        XCTAssertEqual(m.update(visible: false, now: t0.addingTimeInterval(5), lastInteraction: t0.addingTimeInterval(-10)), .success)
        _ = m.update(visible: true, now: t0.addingTimeInterval(10), lastInteraction: nil)
        XCTAssertEqual(m.update(visible: false, now: t0.addingTimeInterval(14), lastInteraction: t0.addingTimeInterval(11)), .success)
    }

    func testFlickerIsIgnored() {
        var m = TouchIDStateMachine()
        _ = m.update(visible: true, now: t0, lastInteraction: nil)
        XCTAssertEqual(m.update(visible: false, now: t0.addingTimeInterval(0.05), lastInteraction: nil), .dismissed)
    }

    func testRepeatedPromptsEachStartAgain() {
        var m = TouchIDStateMachine()
        for i in 0..<3 {
            let base = t0.addingTimeInterval(Double(i) * 10)
            XCTAssertEqual(m.update(visible: true, now: base, lastInteraction: nil), .started)
            XCTAssertEqual(m.update(visible: false, now: base.addingTimeInterval(2), lastInteraction: nil), .success)
        }
    }
}

@MainActor
final class TouchIDHUDTests: XCTestCase {
    func testWaitingStaysAndTurnsIntoSuccessInPlace() async {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(.touchID(.waiting), duration: 30)
        XCTAssertEqual(m.presentation, .hud(.touchID(.waiting)))
        m.showHUD(.touchID(.success), duration: 0.4)
        XCTAssertEqual(m.presentation, .hud(.touchID(.success)))
        XCTAssertEqual(m.queuedHUDCount, 0)
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(m.presentation, .idle)
    }

    func testNothingPreemptsAnActiveTouchIDPrompt() {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(.touchID(.waiting), duration: 30)
        m.showHUD(.volume(level: 0.5, muted: false), duration: 1)
        XCTAssertEqual(m.presentation, .hud(.touchID(.waiting)))
        XCTAssertEqual(m.queuedHUDCount, 1, "volume waits its turn")
    }

    func testCancelledPromptDisappearsAndOthersContinue() {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(.touchID(.waiting), duration: 30)
        m.dismissHUD(channel: "touchid")
        XCTAssertEqual(m.presentation, .idle)
        m.showHUD(.volume(level: 0.5, muted: false), duration: 1)
        m.dismissHUD(channel: "touchid")   // other channel: untouched
        XCTAssertEqual(m.presentation, .hud(.volume(level: 0.5, muted: false)))
    }
}

@MainActor
final class TouchIDLayoutTests: XCTestCase {
    func testTouchIDIsTallerThanOtherHUDsAndKeepsNotchWidth() {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(.touchID(.waiting), duration: 30)
        XCTAssertEqual(m.bodySize.width, NotchGeometry.fallback.notchWidth)
        XCTAssertEqual(m.bodySize.height, NotchGeometry.fallback.notchHeight + NotchModel.touchIDHeight)
        XCTAssertGreaterThan(NotchModel.touchIDHeight, NotchModel.hudRow)
    }

    func testTouchIDReplacesThePillAndThePlayerInsteadOfGoingInline() {
        let np = NowPlaying(source: .spotify, title: "t", artist: "", album: "", duration: 10, position: 0, positionDate: Date(), isPlaying: true)
        let m = NotchModel(geometry: .fallback)
        m.setMedia(np, artwork: nil)
        m.showHUD(.touchID(.waiting), duration: 30)
        XCTAssertFalse(m.hudOverLive)

        let n = NotchModel(geometry: .fallback)
        n.setMedia(np, artwork: nil)
        n.expand()
        n.showHUD(.touchID(.waiting), duration: 30)
        XCTAssertEqual(n.presentation, .hud(.touchID(.waiting)), "full HUD, not the inline row")
        XCTAssertNil(n.inlineHUD)
    }
}
