import AppKit

struct FocusMode: Equatable {
    var id: String
    var name: String
    var symbol: String
    /// Hex colour, e.g. "#5E5CE6".
    var tint: String
}

/// Reads the active Focus (Do Not Disturb, Work, Sleep...) from the files macOS keeps in ~/Library/DoNotDisturb.
/// Like the notification database these need the Full Disk Access permission.
enum FocusParser {
    /// The id of the active mode, or nil when no Focus is on. The key is searched for anywhere so small layout changes do not break it.
    static func activeModeID(assertions data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return find(key: "assertionDetailsModeIdentifier", in: json) as? String
    }

    static func mode(id: String, configurations data: Data?) -> FocusMode {
        let known = fallback(for: id)
        guard let data, let json = try? JSONSerialization.jsonObject(with: data),
              let entry = find(key: id, in: json) else { return known }
        let name = (find(key: "name", in: entry) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? known.name
        let symbol = JSONField.symbol(find(key: "symbolImageName", in: entry) as? String, fallback: known.symbol)
        let tint = (find(key: "tintColorName", in: entry) as? String).flatMap(color(named:)) ?? known.tint
        return FocusMode(id: id, name: name, symbol: symbol, tint: tint)
    }

    static func fallback(for id: String) -> FocusMode {
        switch id {
        case "com.apple.donotdisturb.mode.default": return FocusMode(id: id, name: L("Rahatsız Etme", "Do Not Disturb"), symbol: "moon.fill", tint: "#5E5CE6")
        case "com.apple.sleep.sleep-mode": return FocusMode(id: id, name: L("Uyku", "Sleep"), symbol: "bed.double.fill", tint: "#64D2FF")
        case "com.apple.focus.work": return FocusMode(id: id, name: L("İş", "Work"), symbol: "briefcase.fill", tint: "#0A84FF")
        case "com.apple.focus.personal-time": return FocusMode(id: id, name: L("Kişisel", "Personal"), symbol: "person.fill", tint: "#BF5AF2")
        case "com.apple.focus.driving": return FocusMode(id: id, name: L("Sürüş", "Driving"), symbol: "car.fill", tint: "#FF9F0A")
        case "com.apple.focus.reduce-interruptions": return FocusMode(id: id, name: L("Kesintileri Azalt", "Reduce Interruptions"), symbol: "sparkles", tint: "#8E8E93")
        case "com.apple.focus.gaming": return FocusMode(id: id, name: L("Oyun", "Gaming"), symbol: "gamecontroller.fill", tint: "#30D158")
        case "com.apple.focus.fitness": return FocusMode(id: id, name: L("Fitness", "Fitness"), symbol: "figure.run", tint: "#30D158")
        case "com.apple.focus.reading": return FocusMode(id: id, name: L("Okuma", "Reading"), symbol: "book.fill", tint: "#FF9F0A")
        case "com.apple.focus.mindfulness": return FocusMode(id: id, name: L("Farkındalık", "Mindfulness"), symbol: "circle.hexagongrid.fill", tint: "#64D2FF")
        default: return FocusMode(id: id, name: L("Odak", "Focus"), symbol: "moon.fill", tint: "#5E5CE6")
        }
    }

    static func color(named name: String) -> String? {
        let table = ["systemindigocolor": "#5E5CE6", "systempurplecolor": "#BF5AF2", "systemblue": "#0A84FF", "systembluecolor": "#0A84FF",
                     "systemtealcolor": "#64D2FF", "systemcyancolor": "#64D2FF", "systemgreencolor": "#30D158", "systemmintcolor": "#63E6E2",
                     "systemorangecolor": "#FF9F0A", "systemyellowcolor": "#FFD60A", "systemredcolor": "#FF453A", "systempinkcolor": "#FF375F",
                     "systembrowncolor": "#AC8E68", "systemgraycolor": "#8E8E93"]
        let key = name.lowercased()
        return table[key] ?? table[key + "color"]
    }

    /// First value stored under `key`, searching dictionaries and arrays depth-first.
    private static func find(key: String, in object: Any) -> Any? {
        if let dict = object as? [String: Any] {
            if let value = dict[key] { return value }
            for value in dict.values { if let found = find(key: key, in: value) { return found } }
        } else if let array = object as? [Any] {
            for value in array { if let found = find(key: key, in: value) { return found } }
        }
        return nil
    }
}

final class FocusMonitor: @unchecked Sendable {
    enum Event: Equatable {
        case on(FocusMode)
        case off(FocusMode)
    }

    static var defaultDirectory: String { NSHomeDirectory() + "/Library/DoNotDisturb/DB" }

    /// Delivered on the main thread.
    var onEvent: ((Event) -> Void)?

    private let directory: String
    private let queue = DispatchQueue(label: "dynamicnotch.focus", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var baselineTaken = false
    private var current: FocusMode?
    private var lastStamp = ""
    private let lock = NSLock()
    private var _problem: String?

    init(directory: String = FocusMonitor.defaultDirectory) { self.directory = directory }

    /// The Focus that is on right now, if any.
    var activeMode: FocusMode? { lock.lock(); defer { lock.unlock() }; return current }
    /// Why the files could not be understood, for the health report.
    var problem: String? { lock.lock(); defer { lock.unlock() }; return _problem }

    var isReadable: Bool {
        let fd = open(directory + "/Assertions.json", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, let event = self.pollOnce() else { return }
            DispatchQueue.main.async { self.onEvent?(event) }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() { timer?.cancel(); timer = nil }

    /// Returns an event when the Focus changed since the last call. The very first call only records the starting state.
    func pollOnce() -> Event? {
        let assertionsPath = directory + "/Assertions.json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: assertionsPath) else { return nil }
        let stamp = "\(attrs[.size] ?? 0):\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        guard stamp != lastStamp || !baselineTaken else { return nil }
        lastStamp = stamp
        guard let data = FileManager.default.contents(atPath: assertionsPath) else { return nil }

        let id = FocusParser.activeModeID(assertions: data)
        defer { baselineTaken = true }
        lock.lock()
        // A readable but non-JSON file means Apple changed the format.
        _problem = (try? JSONSerialization.jsonObject(with: data)) == nil ? "Assertions.json is not valid JSON" : nil
        lock.unlock()

        let existing = activeMode
        switch (existing, id) {
        case (nil, nil): return nil
        case (let old?, nil):
            lock.lock(); current = nil; lock.unlock()
            return baselineTaken ? .off(old) : nil
        case (let old?, let id?) where old.id == id:
            return nil
        case (_, let id?):
            let configs = FileManager.default.contents(atPath: directory + "/ModeConfigurations.json")
            let mode = FocusParser.mode(id: id, configurations: configs)
            lock.lock(); current = mode; lock.unlock()
            return baselineTaken ? .on(mode) : nil
        }
    }
}
