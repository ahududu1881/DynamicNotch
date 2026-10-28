import XCTest
import SQLite3
@testable import DynamicNotch

final class NotificationParsingTests: XCTestCase {
    private func plist(_ object: Any) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    func testParsesRequestFields() {
        let data = plist(["app": "net.whatsapp.WhatsApp", "req": ["titl": " Ayşe ", "subt": "Aile", "body": "Akşam geliyor musun?"]])
        let parsed = NotificationParser.parse(data)
        XCTAssertEqual(parsed?.title, "Ayşe")
        XCTAssertEqual(parsed?.subtitle, "Aile")
        XCTAssertEqual(parsed?.body, "Akşam geliyor musun?")
    }

    func testFallsBackToTopLevelAndRejectsEmptyOrGarbage() {
        XCTAssertEqual(NotificationParser.parse(plist(["titl": "x"]))?.title, "x")
        XCTAssertNil(NotificationParser.parse(plist(["req": ["titl": "", "body": "  "]])))
        XCTAssertNil(NotificationParser.parse(plist(["req": ["titl": 5]])))
        XCTAssertNil(NotificationParser.parse(Data()))
        XCTAssertNil(NotificationParser.parse(Data([0xff, 0x00, 0x13])))
        XCTAssertNil(NotificationParser.parse(plist([1, 2, 3])))
    }
}

final class NotificationFilterTests: XCTestCase {
    private func allowed(_ id: String, name: String = "", title: String = "", body: String = "", all: Bool = false) -> Bool {
        NotificationFilter.allows(bundleID: id, appName: name, title: title, body: body, allApps: all)
    }

    func testMessagingAppsPassOthersDoNot() {
        XCTAssertTrue(allowed("net.whatsapp.WhatsApp"))
        XCTAssertTrue(allowed("net.whatsapp.WhatsAppSomethingNew"))
        XCTAssertTrue(allowed("com.apple.MobileSMS"))
        XCTAssertTrue(allowed("ru.keepcoder.Telegram"))
        XCTAssertFalse(allowed("com.apple.reminders", name: "Reminders"))
        XCTAssertFalse(allowed("com.spotify.client", name: "Spotify"))
    }

    func testInstagramWebAppsAndBrowserNotifications() {
        XCTAssertTrue(allowed("com.google.Chrome.app.abcdef", name: "Instagram"))
        XCTAssertTrue(allowed("com.apple.Safari.WebApp.1234", name: "Instagram"))
        XCTAssertTrue(allowed("com.google.Chrome", name: "Google Chrome", title: "instagram.com", body: "ali sent a message"))
        XCTAssertFalse(allowed("com.google.Chrome", name: "Google Chrome", title: "news.example.com", body: "Breaking"))
    }

    func testAllAppsSwitch() {
        XCTAssertTrue(allowed("com.apple.reminders", all: true))
    }
}

/// Runs the monitor against a synthetic database that has the same layout as macOS's.
final class NotificationMonitorTests: XCTestCase {
    private var dir: String!
    private var path: String { dir + "/db" }
    private var db: OpaquePointer?

    override func setUp() {
        dir = NSTemporaryDirectory() + "notif-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        exec("CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT)")
        exec("CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, data BLOB, request_date REAL, delivered_date REAL)")
        exec("INSERT INTO app VALUES (1, 'net.whatsapp.WhatsApp'), (2, 'com.apple.reminders')")
    }

    override func tearDown() {
        sqlite3_close(db)
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }

    private func insert(id: Int, app: Int, title: String, body: String, age: TimeInterval = 0) {
        let data = try! PropertyListSerialization.data(fromPropertyList: ["req": ["titl": title, "body": body]], format: .binary, options: 0)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO record VALUES (?, ?, ?, 0, ?)", -1, &statement, nil)
        sqlite3_bind_int(statement, 1, Int32(id))
        sqlite3_bind_int(statement, 2, Int32(app))
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), nil) }
        sqlite3_bind_double(statement, 4, Date().addingTimeInterval(-age).timeIntervalSinceReferenceDate)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    func testAccessStates() {
        XCTAssertEqual(NotificationMonitor(path: path).access, .granted)
        XCTAssertEqual(NotificationMonitor(path: dir + "/nope").access, .missing)
    }

    func testBaselineThenOnlyNewRecords() {
        insert(id: 1, app: 1, title: "Old", body: "history")
        let monitor = NotificationMonitor(path: path)
        XCTAssertTrue(monitor.pollOnce().isEmpty, "first look must not replay history")

        insert(id: 2, app: 1, title: "Ayşe", body: "Selam")
        insert(id: 3, app: 2, title: "Reminder", body: "Do it")
        let new = monitor.pollOnce()
        XCTAssertEqual(new.map(\.title), ["Ayşe", "Reminder"])
        XCTAssertEqual(new.first?.bundleID, "net.whatsapp.WhatsApp")
        XCTAssertTrue(monitor.pollOnce().isEmpty, "nothing new the second time")
    }

    func testStaleAndUnparsableRecordsAreSkipped() {
        let monitor = NotificationMonitor(path: path)
        _ = monitor.pollOnce()
        insert(id: 1, app: 1, title: "Stale", body: "from before sleep", age: 600)
        exec("INSERT INTO record VALUES (2, 1, x'DEADBEEF', 0, \(Date().timeIntervalSinceReferenceDate))")
        insert(id: 3, app: 1, title: "Fresh", body: "now")
        XCTAssertEqual(monitor.pollOnce().map(\.title), ["Fresh"])
    }

    func testDatabaseResetDoesNotCrashOrReplay() {
        for i in 1...5 { insert(id: i, app: 1, title: "n\(i)", body: "") }
        let monitor = NotificationMonitor(path: path)
        _ = monitor.pollOnce()
        exec("DELETE FROM record")
        insert(id: 1, app: 1, title: "after reset", body: "")
        XCTAssertEqual(monitor.pollOnce().map(\.title), ["after reset"])
        insert(id: 2, app: 1, title: "next", body: "")
        XCTAssertEqual(monitor.pollOnce().map(\.title), ["next"])
    }

    func testWrongSchemaFailsQuietly() {
        exec("DROP TABLE record")
        exec("CREATE TABLE record (something INTEGER)")
        let monitor = NotificationMonitor(path: path)
        XCTAssertTrue(monitor.pollOnce().isEmpty)
        XCTAssertTrue(monitor.pollOnce().isEmpty)
    }
}

@MainActor
final class NotificationPresentationTests: XCTestCase {
    private func card(_ app: String = "net.whatsapp.WhatsApp") -> HUDKind {
        .notification(bundleID: app, app: "WhatsApp", title: "Ayşe", body: "Selam")
    }

    func testCardIsBiggerThanNotchAndSameAppUpdatesInPlace() {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(card(), duration: 5, id: "notif-a")
        XCTAssertGreaterThan(m.bodySize.width, NotchGeometry.fallback.notchWidth)
        XCTAssertGreaterThan(m.bodySize.height, NotchGeometry.fallback.notchHeight + 40)
        m.showHUD(.notification(bundleID: "net.whatsapp.WhatsApp", app: "WhatsApp", title: "Ayşe", body: "İkinci"), duration: 5, id: "notif-a")
        XCTAssertEqual(m.queuedHUDCount, 0)
    }

    func testDifferentAppsQueue() {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(card(), duration: 5, id: "notif-a")
        m.showHUD(card("ru.keepcoder.Telegram"), duration: 5, id: "notif-b")
        XCTAssertEqual(m.queuedHUDCount, 1)
    }

    func testClickOpensAppAndDismisses() {
        let m = NotchModel(geometry: .fallback)
        var opened: String?
        m.onOpenApp = { opened = $0 }
        m.showHUD(card(), duration: 5, id: "notif-a")
        m.primaryClick()
        XCTAssertEqual(opened, "net.whatsapp.WhatsApp")
        XCTAssertEqual(m.presentation, .idle)
    }

    func testVolumeStillPreemptsNotificationAndItResumes() async {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(card(), duration: 4, id: "notif-a")
        m.showHUD(.volume(level: 0.5, muted: false), duration: 0.4)
        XCTAssertEqual(m.queuedHUDCount, 1)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(m.presentation, .hud(card()))
    }

    func testHoverKeepsCardUntilPointerLeaves() async {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(card(), duration: 0.5, id: "notif-a")
        m.setHovering(true)
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(m.presentation, .hud(card()), "still visible while hovered")
        m.setHovering(false)
        try? await Task.sleep(nanoseconds: 1_700_000_000)
        XCTAssertEqual(m.presentation, .idle)
    }

    func testTextIsTruncated() {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(.notification(bundleID: "x", app: "A", title: String(repeating: "t", count: 5000), body: String(repeating: "b", count: 5000)),
                  duration: 1, id: "n")
        if case .hud(.notification(_, _, let title, let body)) = m.presentation {
            XCTAssertEqual(title.count, 120)
            XCTAssertEqual(body.count, 240)
        } else { XCTFail() }
    }
}
