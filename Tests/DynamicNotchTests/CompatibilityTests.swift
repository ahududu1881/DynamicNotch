import XCTest
import SQLite3
@testable import DynamicNotch

@MainActor
final class CompositeHUDTests: XCTestCase {
    private func playing() -> NowPlaying {
        NowPlaying(source: .spotify, title: "t", artist: "", album: "", duration: 10, position: 0, positionDate: Date(), isPlaying: true)
    }

    func testFocusOverLivePillKeepsThePillAndGrowsDownward() {
        let m = NotchModel(geometry: .fallback)
        m.setMedia(playing(), artwork: nil)
        let pill = m.bodySize.width
        m.showHUD(.focus(name: "Work", symbol: "briefcase.fill", tint: "#0A84FF", on: true), duration: 2, id: "focus")
        XCTAssertTrue(m.hudOverLive)
        XCTAssertEqual(m.bodySize.width, pill, "the pill keeps its width so artwork and waveform stay visible")
        XCTAssertEqual(m.bodySize.height, NotchGeometry.fallback.notchHeight + HUDKind.focus(name: "", symbol: "", tint: "", on: true).rowHeight)
    }

    func testWithoutPillTheHUDStaysNotchWidthAndCardsReplaceThePill() {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(.volume(level: 0.5, muted: false), duration: 2)
        XCTAssertFalse(m.hudOverLive)
        XCTAssertEqual(m.bodySize.width, NotchGeometry.fallback.notchWidth)

        let n = NotchModel(geometry: .fallback)
        n.setMedia(playing(), artwork: nil)
        n.showHUD(.notification(bundleID: "x", app: "A", title: "t", body: "b"), duration: 2, id: "n")
        XCTAssertFalse(n.hudOverLive)
        XCTAssertEqual(n.bodySize.width, NotchModel.notificationWidth)
    }

    func testActivityPillAlsoCarriesTheHUD() {
        let m = NotchModel(geometry: .fallback)
        m.upsertActivity(Activity(id: "a", symbol: "bolt.fill", text: "x", subtitle: nil, level: nil, tint: nil,
                                  expires: Date().addingTimeInterval(60)))
        m.showHUD(.volume(level: 0.3, muted: false), duration: 2)
        XCTAssertTrue(m.hudOverLive)
        XCTAssertEqual(m.bodySize.width, NotchGeometry.fallback.notchWidth + 2 * m.wing)
    }
}

final class CompatibilityTests: XCTestCase {
    func testNotificationParserAcceptsAlternativeKeyNames() {
        func plist(_ o: Any) -> Data { try! PropertyListSerialization.data(fromPropertyList: o, format: .binary, options: 0) }
        let a = NotificationParser.parse(plist(["request": ["title": "T", "subtitle": "S", "message": "M"]]))
        XCTAssertEqual(a?.title, "T"); XCTAssertEqual(a?.subtitle, "S"); XCTAssertEqual(a?.body, "M")
        XCTAssertEqual(NotificationParser.parse(plist(["req": ["titl": "", "title": "fallback"]]))?.title, "fallback")
    }

    func testDiagnosticsSummaryAndReport() {
        let ok = [ComponentStatus(name: "A", level: .ok, detail: "fine")]
        XCTAssertTrue(Diagnostics.summary(ok).healthy)
        let bad = ok + [ComponentStatus(name: "Media", level: .failure, detail: "broken"), ComponentStatus(name: "W", level: .warning, detail: "meh")]
        let summary = Diagnostics.summary(bad)
        XCTAssertFalse(summary.healthy)
        XCTAssertTrue(summary.text.contains("Media"))
        XCTAssertFalse(summary.text.contains("W"), "warnings do not trigger the post-update alert")
        let report = Diagnostics.report(bad)
        XCTAssertTrue(report.contains("FAIL Media: broken"))
        XCTAssertTrue(report.contains("WARN W: meh"))
        XCTAssertEqual(Diagnostics.json(bad).count, 3)
    }

    func testOSChangeDetection() {
        let suite = UserDefaults(suiteName: "dynamicnotch-test-\(UUID().uuidString)")!
        XCTAssertFalse(Diagnostics.osChangedSinceLastRun(defaults: suite, current: "26.4.1"), "first run is not a change")
        XCTAssertFalse(Diagnostics.osChangedSinceLastRun(defaults: suite, current: "26.4.1"))
        XCTAssertTrue(Diagnostics.osChangedSinceLastRun(defaults: suite, current: "26.5.0"))
        XCTAssertFalse(Diagnostics.osChangedSinceLastRun(defaults: suite, current: "26.5.0"))
    }

    @MainActor
    func testHubAcceptsProvidersAddedLater() async {
        final class Stub: MediaProvider {
            var onUpdate: ((MediaSnapshot?) -> Void)?
            var started = false
            func start() { started = true }
            func send(_ command: MediaCommand) {}
            func seek(to seconds: TimeInterval) {}
        }
        let first = Stub(), second = Stub()
        let hub = MediaHub(providers: [first])
        var titles: [String] = []
        hub.onUpdate = { if let t = $0?.nowPlaying.title { titles.append(t) } }
        hub.add(second)
        XCTAssertTrue(second.started)
        second.onUpdate?(MediaSnapshot(nowPlaying: NowPlaying(source: .music, title: "from fallback", artist: "", album: "", duration: 1,
                                                              position: 0, positionDate: Date(), isPlaying: true), artwork: nil))
        XCTAssertEqual(titles, ["from fallback"])
    }
}

/// A future macOS may change the notification database; the monitor must report it instead of crashing.
final class SchemaDriftTests: XCTestCase {
    private var dir = ""

    override func setUp() { dir = NSTemporaryDirectory() + "drift-\(UUID().uuidString)"; try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private func makeDB(_ statements: [String]) -> String {
        var db: OpaquePointer?
        let path = dir + "/db"
        sqlite3_open(path, &db)
        for sql in statements { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
        sqlite3_close(db)
        return path
    }

    func testMissingColumnIsReportedNotCrashed() {
        let path = makeDB(["CREATE TABLE app (app_id INTEGER, identifier TEXT)", "CREATE TABLE record (rec_id INTEGER, app_id INTEGER, payload BLOB)"])
        let monitor = NotificationMonitor(path: path)
        XCTAssertTrue(monitor.pollOnce().isEmpty)
        XCTAssertEqual(monitor.schemaProblem, "column record.data not found")
    }

    func testMissingTableIsReported() {
        let path = makeDB(["CREATE TABLE unrelated (x INTEGER)"])
        let monitor = NotificationMonitor(path: path)
        XCTAssertTrue(monitor.pollOnce().isEmpty)
        XCTAssertNotNil(monitor.schemaProblem)
    }

    func testDatabaseWithoutDateColumnsStillDeliversAsNew() {
        let path = makeDB(["CREATE TABLE app (app_id INTEGER, identifier TEXT)", "CREATE TABLE record (rec_id INTEGER, app_id INTEGER, data BLOB)",
                           "INSERT INTO app VALUES (1, 'net.whatsapp.WhatsApp')"])
        let monitor = NotificationMonitor(path: path)
        _ = monitor.pollOnce()   // baseline
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        let data = try! PropertyListSerialization.data(fromPropertyList: ["req": ["titl": "Ayşe", "body": "hi"]], format: .binary, options: 0)
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO record VALUES (5, 1, ?)", -1, &st, nil)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(st, 1, $0.baseAddress, Int32(data.count), nil) }
        sqlite3_step(st); sqlite3_finalize(st); sqlite3_close(db)
        XCTAssertEqual(monitor.pollOnce().map(\.title), ["Ayşe"])
        XCTAssertNil(monitor.schemaProblem)
    }

    func testFocusFilesThatAreNotJSONAreFlagged() throws {
        try Data("<xml/>".utf8).write(to: URL(fileURLWithPath: dir + "/Assertions.json"))
        let monitor = FocusMonitor(directory: dir)
        XCTAssertNil(monitor.pollOnce())
        XCTAssertNotNil(monitor.problem)
    }
}
