import XCTest
@testable import DynamicNotch

final class MediaTests: XCTestCase {
    func testPositionAdvancesWhilePlayingOnly() {
        let start = Date()
        var np = NowPlaying(source: .music, title: "t", artist: "", album: "", duration: 100, position: 10,
                            positionDate: start, isPlaying: true)
        XCTAssertEqual(np.currentPosition(at: start.addingTimeInterval(5)), 15, accuracy: 0.001)
        np.isPlaying = false
        XCTAssertEqual(np.currentPosition(at: start.addingTimeInterval(5)), 10, accuracy: 0.001)
    }

    func testPositionIsClamped() {
        let start = Date()
        let np = NowPlaying(source: .music, title: "t", artist: "", album: "", duration: 100, position: 99,
                            positionDate: start, isPlaying: true)
        XCTAssertEqual(np.currentPosition(at: start.addingTimeInterval(60)), 100)
        let live = NowPlaying(source: .music, title: "t", artist: "", album: "", duration: 0, position: -5,
                              positionDate: start, isPlaying: false)
        XCTAssertEqual(live.currentPosition(at: start), 0)
    }

    func testLineBufferHandlesSplitAndMergedChunks() {
        let buffer = LineBuffer()
        XCTAssertTrue(buffer.feed(Data("{\"a\":".utf8)).isEmpty)
        let first = buffer.feed(Data("1}\n{\"b\":2}\n{\"c\"".utf8))
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[1]["b"] as? Int, 2)
        XCTAssertEqual(buffer.feed(Data(":3}\n".utf8)).first?["c"] as? Int, 3)
    }

    func testLineBufferSkipsGarbageLines() {
        let buffer = LineBuffer()
        let out = buffer.feed(Data("not json\n[1,2]\n{\"ok\":true}\n\n\u{0}\n".utf8))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?["ok"] as? Bool, true)
        buffer.reset()
        XCTAssertTrue(buffer.feed(Data("}\n".utf8)).isEmpty)
    }

    @MainActor
    func testHubIgnoresShortGapBetweenTracks() async {
        final class Stub: MediaProvider {
            var onUpdate: ((MediaSnapshot?) -> Void)?
            func start() {}
            func send(_ command: MediaCommand) {}
            func seek(to seconds: TimeInterval) {}
        }
        func snapshot(_ title: String) -> MediaSnapshot {
            MediaSnapshot(nowPlaying: NowPlaying(source: .spotify, title: title, artist: "", album: "", duration: 10, position: 0,
                                                 positionDate: Date(), isPlaying: true), artwork: nil)
        }
        let stub = Stub()
        let hub = MediaHub(providers: [stub])
        var received: [String?] = []
        hub.onUpdate = { received.append($0?.nowPlaying.title) }

        stub.onUpdate?(snapshot("one"))
        stub.onUpdate?(nil)                       // momentary "nothing" while switching
        try? await Task.sleep(nanoseconds: 200_000_000)
        stub.onUpdate?(snapshot("two"))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(received, ["one", "two"], "a short gap must not clear the notch")

        stub.onUpdate?(nil)                       // a real stop
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(received.last ?? "x", nil)
    }
}
