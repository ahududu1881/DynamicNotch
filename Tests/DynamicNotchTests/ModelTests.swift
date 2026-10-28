import XCTest
@testable import DynamicNotch

@MainActor
final class ModelTests: XCTestCase {
    private func makeModel() -> NotchModel { NotchModel(geometry: .fallback) }

    private func track(_ title: String = "Song", playing: Bool = true, source: MediaApp = .spotify) -> NowPlaying {
        NowPlaying(source: source, title: title, artist: "A", album: "B", duration: 200, position: 10,
                   positionDate: Date(), isPlaying: playing)
    }

    private func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    // MARK: Presentation

    func testStartsIdleAtNotchSize() {
        let m = makeModel()
        XCTAssertEqual(m.presentation, .idle)
        XCTAssertEqual(m.bodySize.width, NotchGeometry.fallback.notchWidth)
        XCTAssertEqual(m.bodySize.height, NotchGeometry.fallback.notchHeight)
    }

    func testPlayingMediaMakesPillWiderThanNotch() {
        let m = makeModel()
        m.setMedia(track(), artwork: nil)
        XCTAssertEqual(m.presentation, .live)
        XCTAssertGreaterThan(m.bodySize.width, NotchGeometry.fallback.notchWidth)
    }

    func testClickWithoutMediaOnlyBounces() {
        let m = makeModel()
        m.primaryClick()
        XCTAssertEqual(m.presentation, .idle)
        XCTAssertFalse(m.expanded)
    }

    func testClickOnLivePillExpandsAndCollapses() {
        let m = makeModel()
        m.setMedia(track(), artwork: nil)
        m.primaryClick()
        XCTAssertEqual(m.presentation, .expanded)
        m.collapse()
        XCTAssertEqual(m.presentation, .live)
    }

    func testMediaEndingCollapsesPlayer() {
        let m = makeModel()
        m.setMedia(track(), artwork: nil)
        m.expand()
        m.setMedia(nil, artwork: nil)
        XCTAssertEqual(m.presentation, .idle)
        XCTAssertFalse(m.expanded)
    }

    func testPausedMediaStaysThenGoesIdle() async {
        let settings = Settings.shared
        let saved = settings.pauseLingerSeconds
        defer { settings.pauseLingerSeconds = saved }
        settings.pauseLingerSeconds = 2
        let m = makeModel()
        m.setMedia(track(), artwork: nil)
        m.setMedia(track(playing: false), artwork: nil)
        XCTAssertEqual(m.presentation, .live)
        await sleep(2.4)
        XCTAssertEqual(m.presentation, .idle)
        XCTAssertNotNil(m.media, "paused media is kept so the notch can still open the player")
        m.primaryClick()
        XCTAssertEqual(m.presentation, .expanded)
    }

    func testResumeCancelsLingerTimer() async {
        let settings = Settings.shared
        let saved = settings.pauseLingerSeconds
        defer { settings.pauseLingerSeconds = saved }
        settings.pauseLingerSeconds = 2
        let m = makeModel()
        m.setMedia(track(), artwork: nil)
        m.setMedia(track(playing: false), artwork: nil)
        m.setMedia(track(playing: true), artwork: nil)
        await sleep(2.4)
        XCTAssertEqual(m.presentation, .live)
    }

    func testRapidTrackChangesKeepStateConsistent() {
        let m = makeModel()
        for i in 0..<300 {
            m.setMedia(track("Song \(i)", playing: i % 5 != 0, source: i % 2 == 0 ? .spotify : .music), artwork: nil)
            if i % 17 == 0 { m.expand() }
            if i % 23 == 0 { m.collapse() }
        }
        XCTAssertEqual(m.media?.title, "Song 299")
        m.setMedia(nil, artwork: nil)
        XCTAssertEqual(m.presentation, .idle)
    }

    // MARK: HUD queue

    func testHUDShowsAndExpires() async {
        let m = makeModel()
        m.showHUD(.volume(level: 0.5, muted: false), duration: 0.3)
        XCTAssertEqual(m.presentation, .hud(.volume(level: 0.5, muted: false)))
        await sleep(0.6)
        XCTAssertEqual(m.presentation, .idle)
    }

    func testSameChannelUpdatesInPlace() {
        let m = makeModel()
        m.showHUD(.volume(level: 0.2, muted: false), duration: 5)
        m.showHUD(.volume(level: 0.8, muted: false), duration: 5)
        XCTAssertEqual(m.presentation, .hud(.volume(level: 0.8, muted: false)))
        XCTAssertEqual(m.queuedHUDCount, 0)
    }

    func testLowPriorityQueuesBehindCurrent() async {
        let m = makeModel()
        m.showHUD(.custom(symbol: "star", text: "first", level: nil, tint: nil), duration: 0.4, id: "a")
        m.showHUD(.custom(symbol: "star", text: "second", level: nil, tint: nil), duration: 0.4, id: "b")
        XCTAssertEqual(m.queuedHUDCount, 1)
        XCTAssertEqual(m.presentation, .hud(.custom(symbol: "star", text: "first", level: nil, tint: nil)))
        await sleep(1.0)
        XCTAssertEqual(m.presentation, .hud(.custom(symbol: "star", text: "second", level: nil, tint: nil)))
        await sleep(0.6)
        XCTAssertEqual(m.presentation, .idle)
        XCTAssertEqual(m.queuedHUDCount, 0)
    }

    func testVolumePreemptsCustomToastAndToastResumes() async {
        let m = makeModel()
        m.showHUD(.custom(symbol: "star", text: "long", level: nil, tint: nil), duration: 3, id: "a")
        m.showHUD(.volume(level: 0.4, muted: false), duration: 0.4)
        XCTAssertEqual(m.presentation, .hud(.volume(level: 0.4, muted: false)))
        XCTAssertEqual(m.queuedHUDCount, 1, "preempted toast is requeued")
        await sleep(1.0)
        XCTAssertEqual(m.presentation, .hud(.custom(symbol: "star", text: "long", level: nil, tint: nil)))
    }

    func testQueueIsBounded() {
        let m = makeModel()
        m.showHUD(.custom(symbol: "star", text: "x", level: nil, tint: nil), duration: 30, id: "first")
        for i in 0..<100 { m.showHUD(.custom(symbol: "star", text: "\(i)", level: nil, tint: nil), duration: 1, id: "n\(i)") }
        XCTAssertLessThanOrEqual(m.queuedHUDCount, NotchModel.maxQueuedHUDs)
    }

    func testHUDValuesAreSanitized() {
        let m = makeModel()
        m.showHUD(.brightness(level: .nan), duration: 1)
        XCTAssertEqual(m.presentation, .hud(.brightness(level: 0)))
        m.showHUD(.volume(level: 9, muted: false), duration: 1)
        XCTAssertEqual(m.presentation, .hud(.volume(level: 1, muted: false)))
        m.showHUD(.volume(level: .infinity, muted: false), duration: .nan)
        XCTAssertEqual(m.presentation, .hud(.volume(level: 0, muted: false)))
    }

    func testInlineHUDKeepsPlayerAndGrowsIt() {
        let m = makeModel()
        m.setMedia(track(), artwork: nil)
        m.expand()
        let before = m.bodySize.height
        m.showHUD(.volume(level: 0.5, muted: false), duration: 5)
        XCTAssertEqual(m.presentation, .expanded)
        XCTAssertEqual(m.bodySize.height, before + NotchModel.inlineExtra)
        m.collapse()
        XCTAssertEqual(m.presentation, .live)
    }

    func testResetClearsEverything() {
        let m = makeModel()
        m.showHUD(.custom(symbol: "star", text: "a", level: nil, tint: nil), duration: 5, id: "a")
        m.showHUD(.custom(symbol: "star", text: "b", level: nil, tint: nil), duration: 5, id: "b")
        m.reset()
        XCTAssertEqual(m.presentation, .idle)
        XCTAssertEqual(m.queuedHUDCount, 0)
    }

    // MARK: Activities

    private func activity(_ id: String, text: String = "job", ttl: TimeInterval = 100, end: Date? = nil) -> Activity {
        Activity(id: id, symbol: "bolt.fill", text: text, subtitle: nil, level: nil, tint: nil,
                 startDate: Date(), endDate: end, expires: Date().addingTimeInterval(ttl))
    }

    func testActivityUsesPillWhenNoMedia() {
        let m = makeModel()
        m.upsertActivity(activity("a"))
        XCTAssertEqual(m.presentation, .live)
        XCTAssertEqual(m.pillActivity?.id, "a")
        XCTAssertGreaterThan(m.wing, 30)
        m.primaryClick()
        XCTAssertFalse(m.expanded)
        XCTAssertTrue(m.endActivity(id: "a"))
        XCTAssertEqual(m.presentation, .idle)
        XCTAssertFalse(m.endActivity(id: "a"))
    }

    func testMediaTakesThePillOverActivities() {
        let m = makeModel()
        m.upsertActivity(activity("a"))
        m.setMedia(track(), artwork: nil)
        XCTAssertNil(m.pillActivity)
        XCTAssertEqual(m.stripText, "Song")
    }

    func testActivityUpsertReplacesAndIsBounded() {
        let m = makeModel()
        m.upsertActivity(activity("a", text: "one"))
        m.upsertActivity(activity("a", text: "two"))
        XCTAssertEqual(m.activities.count, 1)
        XCTAssertEqual(m.activities.first?.text, "two")
        for i in 0..<50 { m.upsertActivity(activity("n\(i)")) }
        XCTAssertLessThanOrEqual(m.activities.count, NotchModel.maxActivities)
    }

    func testExpiredActivitiesDisappearAndTimersReport() {
        let m = makeModel()
        var finished: [String] = []
        m.onActivityFinished = { finished.append($0.id) }
        m.upsertActivity(activity("old", ttl: -1))
        m.upsertActivity(activity("timer", ttl: 100, end: Date().addingTimeInterval(-1)))
        m.upsertActivity(activity("alive"))
        m.expireActivities()
        XCTAssertEqual(m.activities.map(\.id), ["alive"])
        XCTAssertEqual(finished, ["timer"], "only countdowns report completion, not ttl expiry")
    }

    func testTimerRemaining() {
        let a = activity("t", end: Date().addingTimeInterval(90))
        XCTAssertEqual(a.remaining(), 90, accuracy: 1)
        XCTAssertEqual(a.remaining(at: Date().addingTimeInterval(500)), 0)
    }
}

@MainActor
final class RestingStateTests: XCTestCase {
    func testNothingIsDrawnWhenEmpty() {
        let m = NotchModel(geometry: .fallback)
        XCTAssertTrue(m.isResting)
        m.setHovering(true)
        XCTAssertTrue(m.isResting, "hovering an empty notch must not draw anything")
        XCTAssertEqual(m.bodySize.width, NotchGeometry.fallback.notchWidth)
    }

    func testClickFeedbackAndHoverWithMediaAreVisible() {
        let m = NotchModel(geometry: .fallback)
        m.bounce()
        XCTAssertFalse(m.isResting)
        let np = NowPlaying(source: .spotify, title: "t", artist: "", album: "", duration: 10, position: 0, positionDate: Date(), isPlaying: true)
        let n = NotchModel(geometry: .fallback)
        n.setMedia(np, artwork: nil)
        XCTAssertEqual(n.presentation, .live)
        XCTAssertFalse(n.isResting)
        n.setMedia(nil, artwork: nil)
        n.setMedia(NowPlaying(source: .spotify, title: "t", artist: "", album: "", duration: 10, position: 0,
                              positionDate: Date(), isPlaying: false), artwork: nil)
        n.setHovering(true)
        XCTAssertFalse(n.isResting, "idle with a track to open shows hover feedback")
        XCTAssertGreaterThan(n.bodySize.width, NotchGeometry.fallback.notchWidth)
    }
}

@MainActor
final class RestTimingTests: XCTestCase {
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    func testClickBounceDisappearsQuickly() async {
        let m = NotchModel(geometry: .fallback)
        XCTAssertTrue(m.shapeHidden)
        m.primaryClick()                       // idle, no media: only the bounce
        await sleep(0.05)
        XCTAssertFalse(m.shapeHidden, "the pop is visible")
        await sleep(0.45)
        XCTAssertTrue(m.shapeHidden, "and gone well within half a second")
    }

    func testShrinkingFromABigStateStillWaitsForTheSpring() async {
        let np = NowPlaying(source: .spotify, title: "t", artist: "", album: "", duration: 10, position: 0, positionDate: Date(), isPlaying: false)
        let m = NotchModel(geometry: .fallback)
        m.setMedia(np, artwork: nil)           // paused, never played: stays idle but openable
        m.expand()
        await sleep(0.1)
        XCTAssertFalse(m.shapeHidden)
        m.collapse()
        await sleep(0.2)
        XCTAssertFalse(m.shapeHidden, "still shrinking, must not vanish yet")
        await sleep(0.6)
        XCTAssertTrue(m.shapeHidden)
    }

    func testBounceIsShortAndSettlesSmall() async {
        let m = NotchModel(geometry: .fallback)
        m.bounce()
        XCTAssertGreaterThan(m.bodySize.width, NotchGeometry.fallback.notchWidth)
        await sleep(0.2)
        XCTAssertEqual(m.bodySize.width, NotchGeometry.fallback.notchWidth)
    }
}

@MainActor
final class ScreenRecordingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    func testNeedsTwoAgreeingPollsToStartAndToStop() {
        var m = ScreenRecordingStateMachine()
        XCTAssertNil(m.update(watching: true, now: t0))
        XCTAssertNil(m.update(watching: false, now: t0.addingTimeInterval(0.8)), "a one-poll blip (screenshot) is ignored")
        XCTAssertNil(m.update(watching: true, now: t0.addingTimeInterval(1.6)))
        XCTAssertEqual(m.update(watching: true, now: t0.addingTimeInterval(2.4)), .started(t0.addingTimeInterval(2.4)))
        XCTAssertTrue(m.isRecording)
        XCTAssertNil(m.update(watching: true, now: t0.addingTimeInterval(3.2)))
        XCTAssertNil(m.update(watching: false, now: t0.addingTimeInterval(4)))
        XCTAssertNil(m.update(watching: true, now: t0.addingTimeInterval(4.8)), "a gap of one poll does not end it")
        XCTAssertNil(m.update(watching: false, now: t0.addingTimeInterval(5.6)))
        guard case .stopped(let duration)? = m.update(watching: false, now: t0.addingTimeInterval(12.4)) else { return XCTFail() }
        XCTAssertEqual(duration, 10, accuracy: 0.01)
        XCTAssertFalse(m.isRecording)
    }

    private func recording() -> Activity {
        Activity(id: Activity.recordingID, symbol: "record.circle.fill", text: "Screen recording", subtitle: nil, level: nil, tint: "#FF453A",
                 startDate: Date().addingTimeInterval(-5), expires: Date().addingTimeInterval(86_400), countsUp: true)
    }

    func testRecordingOwnsThePillEvenWhenOtherActivitiesArrive() {
        let m = NotchModel(geometry: .fallback)
        m.upsertActivity(recording())
        m.upsertActivity(Activity(id: "dl", symbol: "arrow.down", text: "x", subtitle: nil, level: nil, tint: nil, expires: Date().addingTimeInterval(60)))
        XCTAssertEqual(m.pillActivity?.id, Activity.recordingID)
        XCTAssertTrue(m.isRecording)
        XCTAssertGreaterThan(m.wing, 30)
        m.endActivity(id: Activity.recordingID)
        XCTAssertEqual(m.pillActivity?.id, "dl")
    }

    func testRecordingDotMakesRoomInTheMediaPill() {
        let np = NowPlaying(source: .spotify, title: "t", artist: "", album: "", duration: 10, position: 0, positionDate: Date(), isPlaying: true)
        let m = NotchModel(geometry: .fallback)
        m.setMedia(np, artwork: nil)
        let plain = m.bodySize.width
        m.upsertActivity(recording())
        XCTAssertNil(m.pillActivity, "media keeps the pill")
        XCTAssertGreaterThan(m.bodySize.width, plain, "but it widens for the red dot")
    }

    func testRecordingNeverExpiresByTtlWithinADayAndCountsUp() {
        let r = recording()
        XCTAssertTrue(r.countsUp)
        XCTAssertFalse(r.isTimer)
        let m = NotchModel(geometry: .fallback)
        m.upsertActivity(r)
        m.expireActivities()
        XCTAssertTrue(m.isRecording)
    }
}

/// Nothing in the wings of the pill may sit behind the hardware notch.
@MainActor
final class PillLayoutTests: XCTestCase {
    private typealias L = NotchModel.PillLayout
    private let margin: CGFloat = 2

    private func playing() -> NowPlaying {
        NowPlaying(source: .spotify, title: "t", artist: "", album: "", duration: 10, position: 0, positionDate: Date(), isPlaying: true)
    }

    private func clearOfNotch(_ range: ClosedRange<CGFloat>, width: CGFloat, wing: CGFloat, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let notch = wing...(width - wing)
        XCTAssertTrue(range.upperBound <= notch.lowerBound - margin || range.lowerBound >= notch.upperBound + margin,
                      "\(what) \(range) overlaps the notch \(notch)", file: file, line: line)
    }

    func testMediaPillWithAndWithoutRecording() {
        for recording in [false, true] {
            let m = NotchModel(geometry: .fallback)
            m.setMedia(playing(), artwork: nil)
            if recording {
                m.upsertActivity(Activity(id: Activity.recordingID, symbol: "record.circle.fill", text: "r", subtitle: nil, level: nil, tint: nil,
                                          expires: Date().addingTimeInterval(60), countsUp: true))
            }
            let w = m.bodySize.width, wing = m.wing
            clearOfNotch(L.artworkX...(L.artworkX + L.artworkSize), width: w, wing: wing, "artwork")
            clearOfNotch(L.waveX(width: w)...(L.waveX(width: w) + L.waveWidth), width: w, wing: wing, "waveform")
            if recording {
                clearOfNotch(L.dotX(width: w)...(L.dotX(width: w) + L.dotSize), width: w, wing: wing, "recording dot")
            }
        }
    }

    func testActivityPill() {
        let m = NotchModel(geometry: .fallback)
        m.upsertActivity(Activity(id: "a", symbol: "bolt.fill", text: "x", subtitle: nil, level: nil, tint: nil, expires: Date().addingTimeInterval(60)))
        let w = m.bodySize.width, wing = m.wing
        clearOfNotch(L.activityIconX...(L.activityIconX + L.activityIconSize), width: w, wing: wing, "activity icon")
        clearOfNotch(L.trailingX(width: w)...(L.trailingX(width: w) + L.trailingWidth), width: w, wing: wing, "activity trailing")
    }

    func testWorksOnWiderAndNarrowerNotches() {
        for notch in [150, 186, 210] as [CGFloat] {
            var g = NotchGeometry.fallback
            g.notchWidth = notch
            let m = NotchModel(geometry: g)
            m.setMedia(playing(), artwork: nil)
            m.upsertActivity(Activity(id: Activity.recordingID, symbol: "r", text: "r", subtitle: nil, level: nil, tint: nil,
                                      expires: Date().addingTimeInterval(60), countsUp: true))
            let w = m.bodySize.width
            clearOfNotch(L.dotX(width: w)...(L.dotX(width: w) + L.dotSize), width: w, wing: m.wing, "dot at notch \(notch)")
        }
    }
}
