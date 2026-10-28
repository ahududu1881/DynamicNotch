import AppKit
import SQLite3

struct IncomingNotification: Equatable {
    var recordID: Int64
    var bundleID: String
    var title: String
    var subtitle: String
    var body: String
    var delivered: Date
}

/// Decodes the property list macOS stores for every delivered notification.
enum NotificationParser {
    static func parse(_ data: Data) -> (title: String, subtitle: String, body: String)? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        // Key names have changed between macOS releases before, so accept the known variants.
        let request = ["req", "request"].lazy.compactMap { object[$0] as? [String: Any] }.first ?? object
        func text(_ keys: [String]) -> String {
            keys.lazy.compactMap { (request[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
        }
        let parsed = (title: text(["titl", "title"]), subtitle: text(["subt", "subtitle"]), body: text(["body", "message", "text"]))
        return parsed.title.isEmpty && parsed.subtitle.isEmpty && parsed.body.isEmpty ? nil : parsed
    }
}

/// Which notifications are worth mirroring.
enum NotificationFilter {
    private static let messagingIDs: Set<String> = [
        "net.whatsapp.WhatsApp", "com.apple.MobileSMS", "com.apple.iChat", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.facebook.archon.developerID", "com.apple.mail",
        "org.whispersystems.signal-desktop", "com.microsoft.teams2",
    ]
    private static let keywords = ["whatsapp", "instagram", "telegram", "messenger", "signal", "discord", "slack", "messages", "mesajlar"]
    private static let browsers = ["com.google.chrome", "com.apple.safari", "company.thebrowser.browser", "com.brave.browser", "org.mozilla.firefox", "com.microsoft.edgemac"]

    static func allows(bundleID: String, appName: String, title: String, body: String, allApps: Bool) -> Bool {
        if allApps { return true }
        if messagingIDs.contains(bundleID) || bundleID.hasPrefix("net.whatsapp.") { return true }
        let id = bundleID.lowercased(), name = appName.lowercased()
        if keywords.contains(where: { id.contains($0) || name.contains($0) }) { return true }
        // Web notifications from a browser: judge by who sent them.
        if browsers.contains(where: { id.hasPrefix($0) }) {
            let text = (title + " " + body).lowercased()
            return ["instagram", "whatsapp"].contains { text.contains($0) }
        }
        return false
    }
}

enum AppInfo {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func name(for bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
        names[bundleID] = resolved
        return resolved
    }

    static func icon(for bundleID: String) -> NSImage {
        if let cached = icons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil) ?? NSImage()
        icons[bundleID] = icon
        return icon
    }
}

/// Watches macOS's notification database for new entries so they can be shown in the notch.
/// The file is protected: the app needs the Full Disk Access permission to read it.
final class NotificationMonitor: @unchecked Sendable {
    enum Access { case granted, denied, missing }

    /// Known locations, newest first; the first one that exists wins.
    static var defaultPath: String {
        let base = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted"
        let candidates = [base + "/db2/db", base + "/db3/db", base + "/db/db"]
        return candidates.first { access(atPathExists: $0) } ?? candidates[0]
    }

    private static func access(atPathExists path: String) -> Bool {
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return errno != ENOENT   // protected files exist even when we may not read them
    }

    /// Delivered on the main thread.
    var onNotification: ((IncomingNotification) -> Void)?
    /// Notifications older than this when first seen are ignored (e.g. after sleep).
    var maxAge: TimeInterval = 30

    private let path: String
    private let queue = DispatchQueue(label: "dynamicnotch.notifications", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastRecordID: Int64?
    private var lastStamp = ""
    private let problemLock = NSLock()
    private var _schemaProblem: String?
    /// Set when the database layout is not what we expect (a future macOS changed it).
    var schemaProblem: String? { problemLock.lock(); defer { problemLock.unlock() }; return _schemaProblem }
    private func setProblem(_ value: String?) { problemLock.lock(); _schemaProblem = value; problemLock.unlock() }

    init(path: String = NotificationMonitor.defaultPath) { self.path = path }

    var access: Access {
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return .granted }
        return errno == ENOENT ? .missing : .denied
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for item in self.pollOnce() {
                DispatchQueue.main.async { self.onNotification?(item) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() { timer?.cancel(); timer = nil }

    /// Reads whatever is new since the last call. Call only from the monitor's queue (or tests).
    func pollOnce(now: Date = Date()) -> [IncomingNotification] {
        guard access == .granted, changed() else { return [] }
        guard var rows = readRows(after: lastRecordID) else { return [] }

        guard let last = lastRecordID else {
            // First look: remember where we are, show nothing from the past.
            lastRecordID = rows.maxID ?? 0
            return []
        }
        // The database was recreated (ids restarted): read it from the top.
        if let highest = rows.maxID, highest < last {
            lastRecordID = 0
            rows = readRows(after: 0) ?? Rows(items: [], maxID: highest)
        }
        var result: [IncomingNotification] = []
        for row in rows.items {
            lastRecordID = max(lastRecordID ?? 0, row.recordID)
            guard now.timeIntervalSince(row.delivered) <= maxAge else { continue }
            result.append(row)
        }
        return result
    }

    // MARK: Database

    /// Cheap change detection: size and modification time of the database and its write-ahead log.
    private func changed() -> Bool {
        let stamp = [path, path + "-wal"].map { file -> String in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file) else { return "-" }
            return "\(attrs[.size] ?? 0):\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
        defer { lastStamp = stamp }
        return stamp != lastStamp || lastRecordID == nil
    }

    private struct Rows { var items: [IncomingNotification]; var maxID: Int64? }

    private func readRows(after last: Int64?) -> Rows? {
        if let rows = query(at: path, after: last) { return rows }
        // A read-only connection cannot always attach to a live WAL database: query a private copy instead.
        let temp = NSTemporaryDirectory() + "dynamicnotch-notif-\(getpid())"
        try? FileManager.default.removeItem(atPath: temp)
        guard (try? FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(atPath: temp) }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.copyItem(atPath: path + suffix, toPath: temp + "/db" + suffix)
        }
        return query(at: temp + "/db", after: last)
    }

    private func query(at file: String, after last: Int64?) -> Rows? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)

        let record = columns(of: "record", in: db), appTable = columns(of: "app", in: db)
        let required = [("record", "rec_id", record), ("record", "app_id", record), ("record", "data", record),
                        ("app", "app_id", appTable), ("app", "identifier", appTable)]
        if let missing = required.first(where: { !$0.2.contains($0.1) }) {
            setProblem("column \(missing.0).\(missing.1) not found")
            return nil
        }
        setProblem(nil)
        // Prefer the delivery date, fall back to the request date, and to "now" if neither exists.
        let dates = ["delivered_date", "request_date"].filter(record.contains).map { "record.\($0)" }
        let dateExpression = dates.isEmpty ? "0" : "COALESCE(\(dates.joined(separator: ", ")), 0)"

        var statement: OpaquePointer?
        let sql = """
        SELECT record.rec_id, app.identifier, record.data, \(dateExpression)
        FROM record JOIN app ON record.app_id = app.app_id
        WHERE record.rec_id > ? ORDER BY record.rec_id
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            setProblem("query failed: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, last ?? Int64.max - 1) // first look only needs the highest id

        var items: [IncomingNotification] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let bundle = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let raw = sqlite3_column_double(statement, 3)
            // A missing or zero date means "unknown": treat it as just delivered.
            let delivered = raw > 1_000 ? Date(timeIntervalSinceReferenceDate: raw) : Date()
            var data = Data()
            if let bytes = sqlite3_column_blob(statement, 2) {
                data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
            }
            guard let fields = NotificationParser.parse(data) else {
                items.append(IncomingNotification(recordID: id, bundleID: bundle, title: "", subtitle: "", body: "", delivered: .distantPast))
                continue
            }
            items.append(IncomingNotification(recordID: id, bundleID: bundle, title: fields.title, subtitle: fields.subtitle,
                                              body: fields.body, delivered: delivered))
        }
        return Rows(items: items, maxID: maxRecordID(db))
    }

    private func columns(of table: String, in db: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
        }
        return names
    }

    private func maxRecordID(_ db: OpaquePointer) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(rec_id) FROM record", -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
    }
}
