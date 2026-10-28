import AppKit

/// Now-playing info for every app (Spotify, Music, browsers, YouTube...) through the
/// MediaRemote bridge, a helper that runs inside /usr/bin/perl (see Helper/).
@MainActor
final class SystemMediaProvider: MediaProvider {
    var onUpdate: ((MediaSnapshot?) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private let lines = LineBuffer()
    private var artwork: NSImage?
    private var lastAlbum = ""
    private var restartDelay: TimeInterval = 1
    private var stopped = false
    private var launchTimes: [Date] = []
    private(set) var lastMessage: Date?
    private(set) var failure: String?

    /// Called once when the bridge cannot be kept alive (macOS changed something): callers switch to a fallback.
    var onUnavailable: ((String) -> Void)?

    private static var bridgeURLs: (script: URL, library: URL)? {
        guard let dir = Bundle.main.resourceURL else { return nil }
        let script = dir.appendingPathComponent("stream.pl")
        let library = dir.appendingPathComponent("libDynamicNotchMR.dylib")
        let fm = FileManager.default
        return fm.fileExists(atPath: script.path) && fm.fileExists(atPath: library.path) ? (script, library) : nil
    }

    static var isAvailable: Bool { bridgeURLs != nil }

    func start() { launch() }

    func send(_ command: MediaCommand) {
        switch command {
        case .toggle: write("toggle")
        case .next: write("next")
        case .previous: write("prev")
        }
    }

    func seek(to seconds: TimeInterval) {
        write(String(format: "seek %.2f", seconds).replacingOccurrences(of: ",", with: "."))
    }

    private func write(_ line: String) {
        try? stdin?.write(contentsOf: Data((line + "\n").utf8))
    }

    // MARK: Process

    private func launch() {
        guard !stopped, let urls = Self.bridgeURLs else { return }
        // Dying again and again right after launch means the bridge is broken on this macOS version.
        launchTimes = (launchTimes + [Date()]).filter { Date().timeIntervalSince($0) < 60 }
        if launchTimes.count > 5 { return fail("bridge keeps exiting right after launch") }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [urls.script.path, urls.library.path]
        let out = Pipe(), input = Pipe()
        task.standardOutput = out
        task.standardInput = input
        task.standardError = FileHandle.nullDevice

        // Parse on the reader's own thread and hop to main in order, so bursts of
        // messages (fast skipping, source switches) can never be applied out of order.
        let lines = self.lines
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for json in lines.feed(data) {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(json) } }
            }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.terminated() }
        }
        do {
            try task.run()
            process = task
            stdin = input.fileHandleForWriting
        } catch {
            NSLog("DynamicNotch: cannot start media bridge: \(error)")
        }
    }

    private func terminated() {
        process = nil
        stdin = nil
        lines.reset()
        guard !stopped else { return }
        onUpdate?(nil)
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.launch()
        }
    }

    private func fail(_ reason: String) {
        guard failure == nil else { return }
        failure = reason
        stopped = true
        process?.terminate()
        NSLog("DynamicNotch media bridge unavailable: \(reason)")
        onUnavailable?(reason)
    }

    var statusDescription: String {
        if let failure { return "failed: \(failure)" }
        guard process != nil else { return "not running" }
        guard let lastMessage else { return "running, waiting for first message" }
        return "running, last message \(Int(Date().timeIntervalSince(lastMessage)))s ago"
    }

    private func handle(_ json: [String: Any]) {
        restartDelay = 1
        lastMessage = Date()
        if let error = json["error"] as? String { return fail(error) }
        if json["empty"] != nil {
            artwork = nil
            onUpdate?(nil)
            return
        }
        guard json["error"] == nil else { return }

        let album = json["album"] as? String ?? ""
        if let art = json["artwork"] as? String {
            artwork = art.isEmpty ? nil : Data(base64Encoded: art).flatMap(NSImage.init(data:))
        } else if album != lastAlbum {
            // New album and the new cover has not arrived yet: show the placeholder, not the old cover.
            artwork = nil
        }
        lastAlbum = album

        let title = json["title"] as? String ?? ""
        let bundleID = (json["bundleId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (json["parentBundleId"] as? String) ?? ""
        let elapsed = (json["elapsed"] as? Double) ?? 0
        let timestamp = (json["timestamp"] as? Double) ?? Date().timeIntervalSince1970
        let playing = (json["playing"] as? Bool) ?? false

        let np = NowPlaying(source: MediaApp(bundleID: bundleID, name: Self.appName(for: bundleID)),
                            title: title,
                            artist: json["artist"] as? String ?? "",
                            album: album,
                            duration: (json["duration"] as? Double) ?? 0,
                            position: elapsed,
                            positionDate: Date(timeIntervalSince1970: timestamp),
                            isPlaying: playing)
        onUpdate?(MediaSnapshot(nowPlaying: np, artwork: artwork))
    }

    private static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Splits a byte stream into JSON objects, one per line. Only touched from the reader thread.
final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ data: Data) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var result: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { result.append(json) }
        }
        return result
    }

    func reset() { lock.lock(); buffer.removeAll(); lock.unlock() }
}
