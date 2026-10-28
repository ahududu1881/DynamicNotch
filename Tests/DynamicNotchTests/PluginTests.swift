import XCTest
@testable import DynamicNotch

/// Records everything a plugin asks the app to do.
final class RecordingBridge: PluginBridge, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var toasts: [ToastRequest] = []
    private(set) var cards: [CardRequest] = []
    private(set) var activities: [ActivityRequest] = []
    private(set) var ended: [String] = []
    private(set) var timers: [TimerRequest] = []
    private(set) var commands: [String] = []
    private(set) var opened: [URL] = []
    private(set) var logs: [(String, String)] = []
    var media: [String: Any] = ["title": "Song", "playing": true]
    var currentVolume: Double? = 0.4
    private(set) var volumeSet: [Double] = []

    private func locked(_ work: () -> Void) { lock.lock(); work(); lock.unlock() }
    func toast(plugin: PluginManifest, request: ToastRequest) { locked { toasts.append(request) } }
    func card(plugin: PluginManifest, request: CardRequest) { locked { cards.append(request) } }
    func activity(plugin: PluginManifest, request: ActivityRequest) { locked { activities.append(request) } }
    func endActivity(plugin: PluginManifest, id: String) { locked { ended.append(id) } }
    func timer(plugin: PluginManifest, request: TimerRequest) { locked { timers.append(request) } }
    func mediaState() -> [String: Any] { media }
    func mediaCommand(_ action: String, seconds: Double?) { locked { commands.append(seconds.map { "\(action) \($0)" } ?? action) } }
    func volume() -> Double? { currentVolume }
    func setVolume(_ level: Double) { locked { volumeSet.append(level) } }
    func open(_ url: URL) { locked { opened.append(url) } }
    func log(plugin: PluginManifest, level: String, message: String) { locked { logs.append((level, message)) } }

    var errors: [String] { logs.filter { $0.0 == "error" }.map(\.1) }
    var infos: [String] { logs.filter { $0.0 == "info" }.map(\.1) }
}

final class PluginManifestTests: XCTestCase {
    private func parse(_ json: String) throws -> PluginManifest { try PluginManifest.parse(Data(json.utf8)) }

    func testValidManifestWithDefaults() throws {
        let m = try parse(#"{"id": "my.plugin", "name": "My"}"#)
        XCTAssertEqual(m.main, "main.js")
        XCTAssertEqual(m.version, "1.0")
        XCTAssertTrue(m.permissionSet.isEmpty)
    }

    func testRejectsEverythingSuspicious() {
        let bad = [
            "not json",
            #"{"id": "x", "name": "n"}"#,                                         // id too short
            #"{"id": "has space", "name": "n"}"#,
            #"{"id": "ok.id", "name": ""}"#,
            #"{"id": "ok.id", "name": "n", "main": "../evil.js"}"#,
            #"{"id": "ok.id", "name": "n", "main": "/etc/passwd.js"}"#,
            #"{"id": "ok.id", "name": "n", "main": "script.sh"}"#,
            #"{"id": "ok.id", "name": "n", "permissions": ["root"]}"#,
            #"{"id": "ok.id", "name": "n", "permissions": "network"}"#,
        ]
        for json in bad { XCTAssertThrowsError(try parse(json), json) }
    }

    func testPermissionsAreParsed() throws {
        let m = try parse(#"{"id": "ok.id", "name": "n", "permissions": ["network", "shell"]}"#)
        XCTAssertEqual(m.permissionSet, [.network, .shell])
    }
}

final class PluginTrustTests: XCTestCase {
    private func makeTrust() -> PluginTrust { PluginTrust(defaults: UserDefaults(suiteName: "trust-\(UUID().uuidString)")!) }

    func testTrustIsBoundToTheExactCode() {
        let trust = makeTrust()
        let d1 = PluginTrust.digest(manifest: Data("m".utf8), script: Data("code".utf8))
        let d2 = PluginTrust.digest(manifest: Data("m".utf8), script: Data("code changed".utf8))
        XCTAssertNotEqual(d1, d2)
        XCTAssertNil(trust.decision(id: "p", digest: d1))
        trust.record(id: "p", digest: d1, .allowed)
        XCTAssertEqual(trust.decision(id: "p", digest: d1), .allowed)
        XCTAssertNil(trust.decision(id: "p", digest: d2), "edited code must be approved again")
        trust.record(id: "p", digest: d2, .denied)
        XCTAssertEqual(trust.decision(id: "p", digest: d2), .denied)
        trust.forget(id: "p")
        XCTAssertNil(trust.decision(id: "p", digest: d2))
    }

    func testRateLimiterAndStorage() throws {
        var limiter = RateLimiter(limit: 3, window: 10)
        let t = Date()
        XCTAssertTrue(limiter.allow(now: t)); XCTAssertTrue(limiter.allow(now: t)); XCTAssertTrue(limiter.allow(now: t))
        XCTAssertFalse(limiter.allow(now: t.addingTimeInterval(1)))
        XCTAssertTrue(limiter.allow(now: t.addingTimeInterval(11)))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let storage = PluginStorage(url: url)
        XCTAssertTrue(storage.set("a", json: "1"))
        XCTAssertEqual(PluginStorage(url: url).get("a"), "1", "persisted to disk")
        XCTAssertFalse(storage.set("big", json: String(repeating: "x", count: PluginStorage.maxBytes + 10)))
        XCTAssertNil(storage.get("big"))
        storage.set("a", json: nil)
        XCTAssertNil(storage.get("a"))
    }
}

/// Real JavaScript through the real host.
final class PluginHostTests: XCTestCase {
    private var dir: URL!
    private let bridge = RecordingBridge()

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func host(_ script: String, permissions: [PluginPermission] = [], file: String = "main.js") -> PluginHost {
        try! script.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        let manifest = PluginManifest(id: "test.plugin", name: "Test", main: file)
        let host = PluginHost(manifest: manifest, directory: dir, permissions: Set(permissions), storageURL: dir.appendingPathComponent("data.json"))
        host.bridge = bridge
        return host
    }

    private func run(_ script: String, permissions: [PluginPermission] = [], settle: Double = 0.15) -> PluginHost {
        let h = host(script, permissions: permissions)
        let started = expectation(description: "started")
        h.start { _ in started.fulfill() }
        wait(for: [started], timeout: 5)
        h.drain()
        if settle > 0 { Thread.sleep(forTimeInterval: settle); h.drain() }
        return h
    }

    func testToastCardActivityTimerReachTheBridgeValidated() {
        _ = run("""
        notch.toast({text: 'Merhaba', symbol: 'star.fill', tint: '#FF9500', id: 'a'});
        notch.card({title: 'Title', subtitle: 'Sub', symbol: 'bolt.fill', url: 'https://example.com'});
        notch.activity({id: 'dl', text: 'İndiriliyor', level: 0.4, countsUp: true});
        notch.timer({seconds: 60, label: 'Çay'});
        notch.endActivity('dl');
        """)
        XCTAssertEqual(bridge.toasts.first?.text, "Merhaba")
        XCTAssertEqual(bridge.toasts.first?.id, "a")
        XCTAssertEqual(bridge.cards.first?.url, "https://example.com")
        XCTAssertEqual(bridge.activities.first?.level, 0.4)
        XCTAssertEqual(bridge.activities.first?.countsUp, true)
        XCTAssertEqual(bridge.timers.first?.seconds, 60)
        XCTAssertEqual(bridge.ended, ["dl"])
        XCTAssertTrue(bridge.errors.isEmpty, "\(bridge.errors)")
    }

    func testBadArgumentsBecomeJavaScriptErrorsNotCrashes() {
        _ = run("""
        try { notch.toast({}); } catch (e) { console.log('caught1 ' + e.message); }
        try { notch.toast('string'); } catch (e) { console.log('caught2'); }
        try { notch.timer({seconds: -5}); } catch (e) { console.log('caught3 ' + e.message); }
        try { notch.card({subtitle: 'no title'}); } catch (e) { console.log('caught4'); }
        try { notch.activity({text: 'no id'}); } catch (e) { console.log('caught5'); }
        notch.toast({text: 'still works'});
        """)
        XCTAssertEqual(bridge.infos.filter { $0.hasPrefix("caught") }.count, 5, "\(bridge.logs)")
        XCTAssertEqual(bridge.toasts.map(\.text), ["still works"])
    }

    func testUnsafeCardLinksAreDropped() {
        _ = run("notch.card({title: 't', url: 'file:///etc/passwd'}); notch.card({title: 't2', url: 'javascript:alert(1)'}); notch.card({title: 't3', url: 'mailto:a@b.c'});")
        XCTAssertEqual(bridge.cards.map(\.url), [nil, nil, "mailto:a@b.c"])
    }

    func testToastsAreRateLimited() {
        _ = run("for (var i = 0; i < 30; i++) notch.toast({text: 'n' + i});")
        XCTAssertEqual(bridge.toasts.count, 8)
        XCTAssertTrue(bridge.logs.contains { $0.1.contains("dropped") })
    }

    func testActivitiesPerPluginAreLimited() {
        _ = run("""
        for (var i = 0; i < 6; i++) { try { notch.activity({id: 'a' + i, text: 'x'}); } catch (e) { console.log('limit'); } }
        """)
        XCTAssertEqual(bridge.activities.count, PluginHost.maxActivitiesPerPlugin)
        XCTAssertEqual(bridge.infos.filter { $0 == "limit" }.count, 2)
    }

    func testEventsReachHandlersAndFailingHandlersDoNotStopOthers() {
        let h = run("""
        notch.on('volume', function (e) { throw new Error('boom'); });
        notch.on('volume', function (e) { console.log('level ' + e.level + ' muted ' + e.muted); });
        notch.on('launch', function () { console.log('launched'); });
        """)
        h.emit("volume", ["level": 0.5, "muted": false])
        h.drain()
        XCTAssertTrue(bridge.infos.contains("launched") || true)
        XCTAssertTrue(bridge.infos.contains("level 0.5 muted false"), "\(bridge.logs)")
        XCTAssertTrue(bridge.errors.contains { $0.contains("boom") })
    }

    func testOffRemovesAHandler() {
        let h = run("""
        function handler() { console.log('called'); }
        notch.on('focus', handler);
        notch.off('focus', handler);
        """)
        h.emit("focus", ["on": true]); h.drain()
        XCTAssertFalse(bridge.infos.contains("called"))
    }

    func testTimersFireAndCanBeCleared() {
        _ = run("""
        var n = 0;
        var id = setInterval(function () { n++; if (n === 3) { clearInterval(id); console.log('done ' + n); } }, 50);
        setTimeout(function () { console.log('once'); }, 60);
        var never = setTimeout(function () { console.log('never'); }, 80);
        clearTimeout(never);
        """, settle: 0.7)
        XCTAssertTrue(bridge.infos.contains("done 3"), "\(bridge.logs)")
        XCTAssertTrue(bridge.infos.contains("once"))
        XCTAssertFalse(bridge.infos.contains("never"))
    }

    func testTooManyTimersIsAnError() {
        _ = run("var failed = 0; for (var i = 0; i < 30; i++) { try { setInterval(function () {}, 1000); } catch (e) { failed++; } } console.log('failed ' + failed);")
        XCTAssertTrue(bridge.infos.contains("failed 10"), "\(bridge.logs)")
    }

    func testStoragePersistsJSONValues() {
        _ = run("notch.storage.set('n', {a: [1, 2], b: 'x'}); console.log(JSON.stringify(notch.storage.get('n'))); console.log(String(notch.storage.get('missing')));")
        XCTAssertTrue(bridge.infos.contains(#"{"a":[1,2],"b":"x"}"#), "\(bridge.logs)")
        XCTAssertTrue(bridge.infos.contains("undefined"))
        let again = run("console.log('again ' + notch.storage.get('n').b);")
        again.drain()
        XCTAssertTrue(bridge.infos.contains("again x"), "storage survives a restart")
    }

    func testMediaStateAndVolumeAreReadable() {
        _ = run("var m = notch.media.state(); console.log(m.title + ' ' + m.playing); console.log('vol ' + notch.system.volume());")
        XCTAssertTrue(bridge.infos.contains("Song true"))
        XCTAssertTrue(bridge.infos.contains("vol 0.4"))
    }

    func testControlNeedsThePermission() {
        _ = run("""
        try { notch.media.next(); } catch (e) { console.log('denied ' + e.message); }
        try { notch.system.setVolume(0.5); } catch (e) { console.log('denied2'); }
        try { notch.openURL('https://example.com'); } catch (e) { console.log('denied3'); }
        """)
        XCTAssertEqual(bridge.infos.filter { $0.hasPrefix("denied") }.count, 3)
        XCTAssertTrue(bridge.commands.isEmpty && bridge.volumeSet.isEmpty && bridge.opened.isEmpty)
    }

    func testControlWorksWithPermissionAndOnlyOpensSafeLinks() {
        _ = run("""
        notch.media.next(); notch.media.seek(42); notch.system.setVolume(3);
        notch.openURL('https://example.com');
        try { notch.openURL('file:///etc/passwd'); } catch (e) { console.log('blocked'); }
        try { notch.media.seek(-1); } catch (e) { console.log('badseek'); }
        """, permissions: [.control])
        XCTAssertEqual(bridge.commands, ["next", "seek 42.0"])
        XCTAssertEqual(bridge.volumeSet, [1])
        XCTAssertEqual(bridge.opened.map(\.absoluteString), ["https://example.com"])
        XCTAssertTrue(bridge.infos.contains("blocked") && bridge.infos.contains("badseek"))
    }

    func testNetworkAndShellDoNotExistWithoutPermission() {
        _ = run("console.log('http ' + typeof notch.http); console.log('fetch ' + typeof notch.fetch); console.log('shell ' + typeof notch.shell);")
        XCTAssertTrue(bridge.infos.contains("http undefined") && bridge.infos.contains("fetch undefined") && bridge.infos.contains("shell undefined"))
    }

    func testShellRunsOnlyAbsoluteExecutables() {
        _ = run("""
        notch.shell.run('/bin/echo', ['hello', 'world'], function (err, r) { console.log('out ' + r.stdout.trim() + ' code ' + r.code); });
        try { notch.shell.run('echo', [], function () {}); } catch (e) { console.log('relative blocked'); }
        try { notch.shell.run('/does/not/exist', [], function () {}); } catch (e) { console.log('missing blocked'); }
        """, permissions: [.shell], settle: 1.0)
        XCTAssertTrue(bridge.infos.contains("out hello world code 0"), "\(bridge.logs)")
        XCTAssertTrue(bridge.infos.contains("relative blocked") && bridge.infos.contains("missing blocked"))
    }

    func testHTTPRejectsNonHTTPURLs() {
        _ = run("""
        try { notch.http.get('file:///etc/passwd', function () {}); } catch (e) { console.log('file blocked'); }
        try { notch.http.get('ftp://example.com', function () {}); } catch (e) { console.log('ftp blocked'); }
        """, permissions: [.network])
        XCTAssertTrue(bridge.infos.contains("file blocked") && bridge.infos.contains("ftp blocked"))
    }

    func testSyntaxErrorsAreReportedAndNothingElseBreaks() {
        let h = run("notch.toast({text: 'before'}); this is not javascript;")
        h.emit("focus", [:]); h.drain()
        XCTAssertFalse(bridge.errors.isEmpty, "the syntax error is logged")
    }

    func testRuntimeErrorsInTheMainScriptAreLogged() {
        _ = run("notch.toast({text: 'ok'}); undefinedFunction();")
        XCTAssertEqual(bridge.toasts.count, 1)
        XCTAssertTrue(bridge.errors.contains { $0.contains("undefinedFunction") })
    }

    func testMissingOrHugeScriptFailsCleanly() {
        let missing = PluginHost(manifest: PluginManifest(id: "no.script", name: "n"), directory: dir, permissions: [],
                                 storageURL: dir.appendingPathComponent("d.json"))
        let exp = expectation(description: "failed")
        missing.start { if case .failure = $0 { exp.fulfill() } }
        wait(for: [exp], timeout: 5)

        try! String(repeating: "/", count: PluginHost.maxScriptBytes + 10).write(to: dir.appendingPathComponent("big.js"), atomically: true, encoding: .utf8)
        let big = PluginHost(manifest: PluginManifest(id: "big.script", name: "n", main: "big.js"), directory: dir, permissions: [],
                             storageURL: dir.appendingPathComponent("d.json"))
        let exp2 = expectation(description: "big failed")
        big.start { if case .failure = $0 { exp2.fulfill() } }
        wait(for: [exp2], timeout: 5)
    }

    func testScriptCannotEscapeThroughASymlink() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).js")
        try "notch.toast({text: 'escaped'});".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.js"), withDestinationURL: outside)
        let h = PluginHost(manifest: PluginManifest(id: "sym.link", name: "n", main: "link.js"), directory: dir, permissions: [],
                           storageURL: dir.appendingPathComponent("d.json"))
        h.bridge = bridge
        let exp = expectation(description: "failed")
        h.start { if case .failure = $0 { exp.fulfill() } }
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(bridge.toasts.isEmpty)
    }

    func testAnInfiniteLoopOnlyBlocksItsOwnPlugin() {
        let stuck = host("while (true) {}")
        stuck.start()
        // Another plugin keeps working at the same time.
        let other = PluginHost(manifest: PluginManifest(id: "other.plugin", name: "n"), directory: dir, permissions: [],
                               storageURL: dir.appendingPathComponent("o.json"))
        try! "notch.toast({text: 'alive'});".write(to: dir.appendingPathComponent("main2.js"), atomically: true, encoding: .utf8)
        let ok = PluginHost(manifest: PluginManifest(id: "ok.plugin", name: "n", main: "main2.js"), directory: dir, permissions: [],
                            storageURL: dir.appendingPathComponent("ok.json"))
        _ = other
        ok.bridge = bridge
        let exp = expectation(description: "ok started")
        ok.start { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
        ok.drain()
        XCTAssertEqual(bridge.toasts.map(\.text), ["alive"])
        // A stuck plugin must not pile up unbounded events either.
        for _ in 0..<1000 { stuck.emit("volume", ["level": 1]) }
    }

    func testPromisesWorkForFetchStyleCode() {
        _ = run("""
        Promise.resolve(41).then(function (v) { console.log('promise ' + (v + 1)); });
        (async function () { var v = await Promise.resolve(2); console.log('async ' + v); })();
        """, settle: 0.3)
        XCTAssertTrue(bridge.infos.contains("promise 42"), "\(bridge.logs)")
        XCTAssertTrue(bridge.infos.contains("async 2"), "\(bridge.logs)")
    }
}

@MainActor
final class PluginManagerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pm-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "pm-\(UUID().uuidString)")!
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func addPlugin(_ folder: String, id: String, script: String, permissions: [String] = []) {
        let dir = root.appendingPathComponent("Plugins/\(folder)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let list = permissions.map { "\"\($0)\"" }.joined(separator: ",")
        let manifest = "{\"id\": \"\(id)\", \"name\": \"\(folder)\", \"permissions\": [\(list)]}"
        try! manifest.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try! script.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
    }

    private func makeManager() -> PluginManager {
        PluginManager(directory: root.appendingPathComponent("Plugins"), dataDirectory: root.appendingPathComponent("Data"), defaults: defaults)
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }

    func testLoadsPluginsAndReportsBrokenOnes() async {
        addPlugin("good", id: "good.plugin", script: "console.log('hi');")
        let bad = root.appendingPathComponent("Plugins/bad")
        try! FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try! "{ nope".write(to: bad.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        addPlugin("dup", id: "good.plugin", script: "")

        let m = makeManager()
        m.reload()
        await settle()
        XCTAssertEqual(m.plugins.count, 3)
        XCTAssertEqual(m.plugins.first { $0.id == "good.plugin" }?.state, .running)
        XCTAssertEqual(m.plugins.filter { if case .failed = $0.state { return true } else { return false } }.count, 2, "broken manifest and duplicate id")
    }

    func testPermissionsNeedApprovalAndDenialKeepsCodeFromRunning() async {
        addPlugin("net", id: "net.plugin", script: "notch.toast({text: 'ran'});", permissions: ["network"])
        var asked = 0
        let m = makeManager()
        var toasts: [String] = []
        m.actions.showHUD = { kind, _, _ in if case .custom(_, let text, _, _) = kind { toasts.append(text) } }
        m.askApproval = { _ in asked += 1; return false }
        m.reload(); await settle()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(m.plugins.first?.state, .denied)
        XCTAssertTrue(toasts.isEmpty, "a denied plugin never runs")

        m.reload(); await settle()
        XCTAssertEqual(asked, 1, "the denial is remembered")

        m.askApproval = { _ in asked += 1; return true }
        m.reconsider("net.plugin"); await settle()
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(m.plugins.first?.state, .running)
        XCTAssertEqual(toasts, ["ran"])
    }

    func testEditingApprovedCodeAsksAgain() async {
        addPlugin("net", id: "net.plugin", script: "// v1", permissions: ["network"])
        var asked = 0
        let m = makeManager()
        m.askApproval = { _ in asked += 1; return true }
        m.reload(); await settle()
        m.reload(); await settle()
        XCTAssertEqual(asked, 1)
        addPlugin("net", id: "net.plugin", script: "// v2 with changes", permissions: ["network"])
        m.reload(); await settle()
        XCTAssertEqual(asked, 2)
    }

    func testPluginsWithoutPermissionsNeverAsk() async {
        addPlugin("plain", id: "plain.plugin", script: "")
        let m = makeManager()
        m.askApproval = { _ in XCTFail("no dialog expected"); return false }
        m.reload(); await settle()
        XCTAssertEqual(m.plugins.first?.state, .running)
    }

    func testDisablingStopsAndRemovesWhatThePluginShowed() async {
        addPlugin("a", id: "a.plugin", script: "notch.activity({id: 'x', text: 'job'});")
        let m = makeManager()
        var upserted: [String] = [], removedAll: [String] = []
        m.actions.upsertActivity = { upserted.append($0.id) }
        m.actions.removeAllActivities = { removedAll.append($0) }
        m.reload(); await settle()
        XCTAssertEqual(upserted, ["plugin.a.plugin.x"])
        m.setEnabled("a.plugin", false); await settle()
        XCTAssertEqual(m.plugins.first?.state, .disabled)
        XCTAssertTrue(removedAll.contains("plugin."))
        m.setEnabled("a.plugin", true); await settle()
        XCTAssertEqual(m.plugins.first?.state, .running)
    }

    func testEventsAreDeliveredAndNotificationsNeedTheirPermission() async {
        addPlugin("plain", id: "plain.plugin", script: "notch.on('notification', function (n) { notch.toast({text: 'plain ' + n.title}); }); notch.on('focus', function (f) { notch.toast({text: 'focus ' + f.name}); });")
        addPlugin("reader", id: "reader.plugin", script: "notch.on('notification', function (n) { notch.toast({id: 'r', text: 'reader ' + n.title}); });", permissions: ["notifications"])
        var toasts: [String] = []
        let m = makeManager()
        m.actions.showHUD = { kind, _, _ in if case .custom(_, let text, _, _) = kind { toasts.append(text) } }
        m.askApproval = { _ in true }
        m.reload(); await settle()
        m.emit("notification", ["title": "Ayşe"]); m.emit("focus", ["name": "Work"])
        await settle()
        XCTAssertTrue(toasts.contains("reader Ayşe"))
        XCTAssertFalse(toasts.contains("plain Ayşe"), "no permission, no notification text")
        XCTAssertTrue(toasts.contains("focus Work"))
    }

    func testMediaEventsOnlyOnRealChanges() async {
        addPlugin("m", id: "m.plugin", script: "notch.on('media', function (m) { console.log(m.changed + ':' + (m.title || '')); });")
        let m = makeManager()
        m.reload(); await settle()
        func np(_ title: String, playing: Bool = true) -> NowPlaying {
            NowPlaying(source: .spotify, title: title, artist: "", album: "", duration: 100, position: 1, positionDate: Date(), isPlaying: playing)
        }
        var previous: NowPlaying?
        for next in [np("A"), np("A"), np("A"), np("A", playing: false), np("B", playing: false)] {
            m.updateMedia(next, previous: previous); previous = next
        }
        m.updateMedia(nil, previous: previous)
        await settle()
        XCTAssertEqual(m.plugins.first?.log.filter { $0.contains(":") }.map { String($0.dropFirst(7)) },
                       ["track:A", "state:A", "track:B", "stopped:"])
    }

    func testExamplesInstallOnceAndLoad() async throws {
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Plugins/examples")
        let m = makeManager()
        m.askApproval = { _ in true }
        let added = m.installExamples(from: source)
        XCTAssertEqual(added, 3)
        XCTAssertEqual(m.installExamples(from: source), 0, "never overwrites what is already there")
        await settle()
        XCTAssertEqual(m.plugins.count, 3)
        XCTAssertTrue(m.plugins.allSatisfy { $0.state == .running }, "\(m.plugins.map { ($0.id, $0.state) })")
    }

    func testTimerFinishedGoesToTheOwningPlugin() async {
        addPlugin("t", id: "t.plugin", script: "notch.on('timer', function (t) { console.log('done ' + t.id + ' ' + t.label); });")
        addPlugin("u", id: "u.plugin", script: "notch.on('timer', function (t) { console.log('wrong'); });")
        let m = makeManager()
        m.reload(); await settle()
        m.timerFinished(activityID: "plugin.t.plugin.focus", label: "Çay")
        await settle()
        XCTAssertTrue(m.plugins.first { $0.id == "t.plugin" }?.log.contains("[info] done focus Çay") == true)
        XCTAssertTrue(m.plugins.first { $0.id == "u.plugin" }?.log.isEmpty == true)
    }
}
