import Foundation

/// One line of the health report: does a feature work on this Mac, and if not, why.
struct ComponentStatus: Equatable {
    enum Level: Int { case ok, warning, failure }
    var name: String
    var level: Level
    var detail: String
}

enum Diagnostics {
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func report(_ statuses: [ComponentStatus]) -> String {
        var lines = ["Dynamic Notch · macOS \(osVersion)"]
        for s in statuses {
            let mark = s.level == .ok ? "OK  " : s.level == .warning ? "WARN" : "FAIL"
            lines.append("\(mark) \(s.name): \(s.detail)")
        }
        return lines.joined(separator: "\n")
    }

    static func json(_ statuses: [ComponentStatus]) -> [[String: Any]] {
        statuses.map { ["name": $0.name, "level": ["ok", "warning", "failure"][$0.level.rawValue], "detail": $0.detail] }
    }

    /// Summary used for the toast shown after macOS was updated.
    static func summary(_ statuses: [ComponentStatus]) -> (text: String, healthy: Bool) {
        let failing = statuses.filter { $0.level == .failure }
        if failing.isEmpty { return (L("macOS güncellendi · her şey çalışıyor", "macOS updated · everything works"), true) }
        let names = failing.prefix(2).map(\.name).joined(separator: ", ")
        return (L("macOS güncellendi · kontrol gerek: ", "macOS updated · check: ") + names, false)
    }

    /// True when the stored version differs from the running one (and records the new one).
    static func osChangedSinceLastRun(defaults: UserDefaults = .standard, current: String = osVersion) -> Bool {
        let key = "lastSeenOSVersion"
        let previous = defaults.string(forKey: key)
        defaults.set(current, forKey: key)
        guard let previous else { return false } // first run
        return previous != current
    }
}
