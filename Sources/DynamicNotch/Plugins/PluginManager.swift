import AppKit

/// Everything a plugin may cause in the app. The app delegate fills these in.
struct PluginActions {
    var showHUD: (HUDKind, TimeInterval, String?) -> Void = { _, _, _ in }
    var canShow: (HUDKind) -> Bool = { _ in true }
    var upsertActivity: (Activity) -> Void = { _ in }
    var removeActivity: (_ id: String) -> Void = { _ in }
    var removeAllActivities: (_ idPrefix: String) -> Void = { _ in }
    var mediaCommand: (String, Double?) -> Void = { _, _ in }
    var setVolume: (Double) -> Void = { _ in }
    var currentVolume: () -> Double? = { nil }
    var open: (URL) -> Void = { _ in }
}

/// Thread-safe copy of the now-playing state that plugins can read from their own queues.
final class PluginMediaBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: Any] = [:]

    var snapshot: [String: Any] { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: [String: Any]) { lock.lock(); value = new; lock.unlock() }
}

enum PluginPayload {
    static func media(_ np: NowPlaying?) -> [String: Any] {
        guard let np else { return [:] }
        let position = np.currentPosition()
        return ["title": np.title, "artist": np.artist, "album": np.album, "app": np.source.bundleID,
                "appName": np.source.name, "playing": np.isPlaying,
                "duration": np.duration.isFinite ? np.duration : 0, "position": position.isFinite ? position : 0]
    }
}

/// Finds, approves, starts and supervises plugins. They live in
/// `~/Library/Application Support/DynamicNotch/Plugins/<name>/{plugin.json, main.js}`.
@MainActor
final class PluginManager: ObservableObject {
    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DynamicNotch/Plugins", isDirectory: true)
    }

    static let maxPlugins = 50

    @Published private(set) var plugins: [PluginStatus] = []
    var actions = PluginActions()
    /// Asks the user to approve permissions. Replaceable so tests do not open dialogs.
    var askApproval: (PluginManifest) -> Bool = PluginManager.askWithAlert

    let directory: URL
    private let dataDirectory: URL
    private let trust: PluginTrust
    private let defaults: UserDefaults
    private let mediaBox = PluginMediaBox()
    private var hosts: [String: PluginHost] = [:]
    private var logs: [String: [String]] = [:]
    private var errors: [String: String] = [:]
    private var watchTimer: Timer?
    private var fingerprint = ""
    private lazy var bridge = PluginBridgeImpl(manager: self, media: mediaBox)

    private var disabled: Set<String> {
        get { Set(defaults.stringArray(forKey: "pluginDisabled") ?? []) }
        set { defaults.set(Array(newValue), forKey: "pluginDisabled") }
    }

    init(directory: URL = PluginManager.defaultDirectory, dataDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.dataDirectory = dataDirectory ?? directory.deletingLastPathComponent().appendingPathComponent("PluginData", isDirectory: true)
        self.defaults = defaults
        self.trust = PluginTrust(defaults: defaults)
    }

    // MARK: Lifecycle

    func start() {
        reload()
        // Editing a plugin while the app runs reloads it.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = self.currentFingerprint()
                if now != self.fingerprint { self.reload() }
            }
        }
    }

    func reload() {
        for host in hosts.values { host.stop() }
        hosts.removeAll()
        actions.removeAllActivities("plugin.")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fingerprint = currentFingerprint()

        var statuses: [PluginStatus] = []
        let folders = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(Self.maxPlugins)

        var seen: Set<String> = []
        for folder in folders {
            let manifestURL = folder.appendingPathComponent("plugin.json")
            guard let manifestData = try? Data(contentsOf: manifestURL) else { continue }
            do {
                let manifest = try PluginManifest.parse(manifestData)
                guard seen.insert(manifest.id).inserted else {
                    statuses.append(broken(folder, "duplicate plugin id \"\(manifest.id)\""))
                    continue
                }
                statuses.append(load(manifest, manifestData: manifestData, folder: folder))
            } catch {
                statuses.append(broken(folder, "\(error)"))
            }
        }
        plugins = statuses
    }

    func stop() {
        watchTimer?.invalidate()
        for host in hosts.values { host.stop() }
        hosts.removeAll()
    }

    private func broken(_ folder: URL, _ message: String) -> PluginStatus {
        PluginStatus(id: "invalid:" + folder.lastPathComponent, name: folder.lastPathComponent, version: "", description: "",
                     permissions: [], state: .failed(message), directory: folder, log: [], lastError: message)
    }

    private func load(_ manifest: PluginManifest, manifestData: Data, folder: URL) -> PluginStatus {
        var status = PluginStatus(id: manifest.id, name: manifest.name, version: manifest.version, description: manifest.description,
                                  permissions: manifest.permissionSet.sorted { $0.rawValue < $1.rawValue }, state: .running,
                                  directory: folder, log: logs[manifest.id] ?? [], lastError: errors[manifest.id])
        if disabled.contains(manifest.id) { status.state = .disabled; return status }

        // Plugins that want permissions must be approved, and approval is tied to their exact code.
        var granted: Set<PluginPermission> = []
        if !manifest.permissionSet.isEmpty {
            let script = (try? Data(contentsOf: folder.appendingPathComponent(manifest.main))) ?? Data()
            let digest = PluginTrust.digest(manifest: manifestData, script: script)
            switch trust.decision(id: manifest.id, digest: digest) {
            case .allowed?:
                granted = manifest.permissionSet
            case .denied?:
                status.state = .denied
                return status
            case nil:
                if askApproval(manifest) {
                    trust.record(id: manifest.id, digest: digest, .allowed)
                    granted = manifest.permissionSet
                } else {
                    trust.record(id: manifest.id, digest: digest, .denied)
                    status.state = .denied
                    return status
                }
            }
        }

        let host = PluginHost(manifest: manifest, directory: folder, permissions: granted,
                              storageURL: dataDirectory.appendingPathComponent("\(manifest.id).json"))
        host.bridge = bridge
        hosts[manifest.id] = host
        host.start { [weak self] result in
            if case .failure(let error) = result {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.markFailed(manifest.id, "\(error)") }
                }
            }
        }
        return status
    }

    private func currentFingerprint() -> String {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(atPath: directory.path) else { return "" }
        return folders.sorted().map { folder -> String in
            let base = directory.appendingPathComponent(folder)
            return ["plugin.json", "main.js"].map { name in
                let attrs = try? manager.attributesOfItem(atPath: base.appendingPathComponent(name).path)
                return "\(folder)/\(name):\(attrs?[.size] ?? 0):\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            }.joined(separator: ",")
        }.joined(separator: "|")
    }

    // MARK: User actions

    func setEnabled(_ id: String, _ enabled: Bool) {
        var set = disabled
        if enabled { set.remove(id) } else { set.insert(id) }
        disabled = set
        reload()
    }

    /// Asks again for a plugin that was denied before.
    func reconsider(_ id: String) {
        trust.forget(id: id)
        reload()
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    /// Copies the bundled example plugins that are not there yet. Returns how many were added.
    @discardableResult
    func installExamples(from source: URL? = Bundle.main.resourceURL?.appendingPathComponent("examples")) -> Int {
        guard let source, let examples = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return 0 }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var added = 0
        for example in examples where !example.lastPathComponent.hasPrefix(".") {
            let target = directory.appendingPathComponent(example.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            if (try? FileManager.default.copyItem(at: example, to: target)) != nil { added += 1 }
        }
        if added > 0 { reload() }
        return added
    }

    // MARK: Events from the app to plugins

    func emit(_ event: String, _ payload: [String: Any] = [:]) {
        for (id, host) in hosts {
            if event == "notification", !host.permissions.contains(.notifications) { continue }
            _ = id
            host.emit(event, payload)
        }
    }

    func updateMedia(_ np: NowPlaying?, previous: NowPlaying?) {
        mediaBox.set(PluginPayload.media(np))
        guard let np else {
            if previous != nil { emit("media", ["changed": "stopped"]) }
            return
        }
        if previous?.trackKey != np.trackKey {
            emit("media", PluginPayload.media(np).merging(["changed": "track"]) { $1 })
        } else if previous?.isPlaying != np.isPlaying {
            emit("media", PluginPayload.media(np).merging(["changed": "state"]) { $1 })
        }
    }

    /// Tells the plugin that owns a timer activity that it ran out.
    func timerFinished(activityID: String, label: String) {
        let prefix = "plugin."
        guard activityID.hasPrefix(prefix) else { return }
        let rest = activityID.dropFirst(prefix.count)
        for (id, host) in hosts where rest.hasPrefix(id + ".") {
            host.emit("timer", ["id": String(rest.dropFirst(id.count + 1)), "label": label])
        }
    }

    // MARK: Called back from the bridge (main thread)

    func appendLog(_ pluginID: String, level: String, message: String) {
        let line = "[\(level)] \(message)"
        var list = logs[pluginID] ?? []
        list.append(line)
        if list.count > 100 { list.removeFirst(list.count - 100) }
        logs[pluginID] = list
        if level == "error" { errors[pluginID] = message }
        NSLog("DynamicNotch plugin %@ %@", pluginID, line)
        if let index = plugins.firstIndex(where: { $0.id == pluginID }) {
            plugins[index].log = list
            plugins[index].lastError = errors[pluginID]
        }
    }

    private func markFailed(_ id: String, _ message: String) {
        hosts[id]?.stop()
        hosts[id] = nil
        errors[id] = message
        if let index = plugins.firstIndex(where: { $0.id == id }) {
            plugins[index].state = .failed(message)
            plugins[index].lastError = message
        }
    }

    // MARK: Approval dialog

    private static func askWithAlert(_ manifest: PluginManifest) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("\"\(manifest.name)\" eklentisi izin istiyor", "The plugin \"\(manifest.name)\" asks for permissions")
        let list = manifest.permissionSet.sorted { $0.rawValue < $1.rawValue }.map { "• " + $0.title }.joined(separator: "\n")
        alert.informativeText = (manifest.description.isEmpty ? "" : manifest.description + "\n\n") + list + "\n\n"
            + L("Yalnızca güvendiğin eklentilere izin ver. Eklentinin kodu değişirse yeniden sorulur.",
                "Only allow plugins you trust. You will be asked again if the plugin's code changes.")
        alert.addButton(withTitle: L("İzin ver", "Allow"))
        alert.addButton(withTitle: L("İzin verme", "Don't allow"))
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Receives calls on plugin queues and applies them on the main thread.
final class PluginBridgeImpl: PluginBridge, @unchecked Sendable {
    private weak var manager: PluginManager?
    private let media: PluginMediaBox

    init(manager: PluginManager, media: PluginMediaBox) {
        self.manager = manager
        self.media = media
    }

    private func onMain(_ work: @escaping @MainActor (PluginManager) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let manager = self?.manager { work(manager) } }
        }
    }

    private func qualify(_ plugin: PluginManifest, _ id: String) -> String { "plugin.\(plugin.id).\(id)" }

    func toast(plugin: PluginManifest, request: ToastRequest) {
        onMain { m in
            let kind = HUDKind.custom(symbol: request.symbol, text: request.text, level: request.level, tint: request.tint)
            guard m.actions.canShow(kind) else { return }
            m.actions.showHUD(kind, request.duration, self.qualify(plugin, request.id ?? "toast"))
        }
    }

    func card(plugin: PluginManifest, request: CardRequest) {
        onMain { m in
            let kind = HUDKind.card(symbol: request.symbol, title: request.title, subtitle: request.subtitle, tint: request.tint, url: request.url)
            guard m.actions.canShow(kind) else { return }
            m.actions.showHUD(kind, request.duration, self.qualify(plugin, request.id ?? "card"))
        }
    }

    func activity(plugin: PluginManifest, request: ActivityRequest) {
        onMain { m in
            m.actions.upsertActivity(Activity(id: self.qualify(plugin, request.id), symbol: request.symbol, text: request.text,
                                              subtitle: request.subtitle, level: request.level, tint: request.tint,
                                              expires: Date().addingTimeInterval(request.ttl), countsUp: request.countsUp))
        }
    }

    func endActivity(plugin: PluginManifest, id: String) {
        onMain { m in m.actions.removeActivity(self.qualify(plugin, id)) }
    }

    func timer(plugin: PluginManifest, request: TimerRequest) {
        onMain { m in
            let now = Date()
            m.actions.upsertActivity(Activity(id: self.qualify(plugin, request.id), symbol: request.symbol, text: request.label,
                                              subtitle: nil, level: nil, tint: request.tint, startDate: now,
                                              endDate: now.addingTimeInterval(request.seconds),
                                              expires: now.addingTimeInterval(request.seconds + 5)))
        }
    }

    func mediaState() -> [String: Any] { media.snapshot }
    func mediaCommand(_ action: String, seconds: Double?) { onMain { $0.actions.mediaCommand(action, seconds) } }
    func volume() -> Double? { AudioControl.shared.volume() }
    func setVolume(_ level: Double) { onMain { $0.actions.setVolume(level) } }
    func open(_ url: URL) { onMain { $0.actions.open(url) } }

    func log(plugin: PluginManifest, level: String, message: String) {
        onMain { $0.appendLog(plugin.id, level: level, message: message) }
    }
}
