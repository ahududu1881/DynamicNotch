import AppKit

/// Apple Music and Spotify, read through their AppleScript dictionaries.
@MainActor
final class ScriptablePlayerProvider: MediaProvider {
    var onUpdate: ((MediaSnapshot?) -> Void)?

    private struct Player {
        let app: MediaApp
        let scriptName: String
        let notification: String
        let durationIsMilliseconds: Bool
    }

    private let players = [
        Player(app: .music, scriptName: "Music", notification: "com.apple.Music.playerInfo", durationIsMilliseconds: false),
        Player(app: .spotify, scriptName: "Spotify", notification: "com.spotify.client.PlaybackStateChanged", durationIsMilliseconds: true),
    ]

    private var states: [MediaApp: NowPlaying] = [:]
    private var artworks: [String: NSImage] = [:]
    private var artworkRequested: Set<String> = []
    private var stamps: [MediaApp: Date] = [:]
    private var timer: Timer?
    private let runner = ScriptRunner()

    func start() {
        for player in players {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(player.notification),
                                                                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll(player) }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self, let player = self.players.first(where: { $0.app.bundleID == id }) else { return }
                self.states[player.app] = nil
                self.emit()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAll() }
        }
        pollAll()
    }

    func send(_ command: MediaCommand) {
        guard let player = activePlayer() else { return }
        let verb: String
        switch command {
        case .toggle: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        runner.run("tell application \"\(player.scriptName)\" to \(verb)") { [weak self] _ in
            Task { @MainActor in self?.poll(player) }
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let player = activePlayer() else { return }
        let value = String(format: "%.2f", seconds).replacingOccurrences(of: ",", with: ".")
        runner.run("tell application \"\(player.scriptName)\" to set player position to \(value)") { [weak self] _ in
            Task { @MainActor in self?.poll(player) }
        }
        if var np = states[player.app] {
            np.position = seconds
            np.positionDate = Date()
            states[player.app] = np
            emit()
        }
    }

    // MARK: Polling

    private func activePlayer() -> Player? {
        let playing = states.filter { $0.value.isPlaying }
        let pool = playing.isEmpty ? states : playing
        guard let app = pool.keys.max(by: { (stamps[$0] ?? .distantPast) < (stamps[$1] ?? .distantPast) }) else { return nil }
        return players.first { $0.app == app }
    }

    private func pollAll() { players.forEach(poll) }

    private func poll(_ player: Player) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: player.app.bundleID).isEmpty == false
        guard running else {
            if states.removeValue(forKey: player.app) != nil { emit() }
            return
        }
        runner.run(stateScript(for: player)) { [weak self] descriptor in
            Task { @MainActor in self?.apply(descriptor, for: player) }
        }
    }

    private func stateScript(for player: Player) -> String {
        if player.app == .spotify {
            return """
            tell application "Spotify"
              set st to player state as text
              if st is "stopped" then return {"stopped"}
              set t to current track
              return {st, name of t, artist of t, album of t, (duration of t) as text, (player position) as text, artwork url of t}
            end tell
            """
        }
        return """
        tell application "Music"
          set st to player state as text
          if st is "stopped" then return {"stopped"}
          set t to current track
          set d to 0
          try
            set d to duration of t
          end try
          set a to ""
          try
            set a to artist of t
          end try
          set al to ""
          try
            set al to album of t
          end try
          return {st, name of t, a, al, d as text, (player position) as text}
        end tell
        """
    }

    private func apply(_ descriptor: NSAppleEventDescriptor?, for player: Player) {
        guard let descriptor, descriptor.numberOfItems >= 1 else { return }
        func item(_ i: Int) -> String? { descriptor.atIndex(i)?.stringValue }
        func number(_ s: String?) -> Double { Double((s ?? "").replacingOccurrences(of: ",", with: ".")) ?? 0 }

        guard item(1) != "stopped", descriptor.numberOfItems >= 6 else {
            if states.removeValue(forKey: player.app) != nil { emit() }
            return
        }
        let playing = item(1) == "playing"
        var duration = number(item(5))
        if player.durationIsMilliseconds { duration /= 1000 }
        var np = NowPlaying(source: player.app, title: item(2) ?? "", artist: item(3) ?? "", album: item(4) ?? "",
                            duration: duration, position: number(item(6)), positionDate: Date(), isPlaying: playing)

        if let old = states[player.app], old.trackKey == np.trackKey {
            // Keep the local clock when the system's position agrees, so the bar does not jitter.
            if old.isPlaying == np.isPlaying, abs(old.currentPosition() - np.position) < 1.5 {
                np.position = old.position
                np.positionDate = old.positionDate
            }
        }
        if states[player.app]?.isPlaying != true, playing { stamps[player.app] = Date() }
        if stamps[player.app] == nil { stamps[player.app] = Date() }
        states[player.app] = np

        requestArtwork(for: np, player: player, spotifyURL: item(7))
        emit()
    }

    private func emit() {
        let playing = states.filter { $0.value.isPlaying }
        let pool = playing.isEmpty ? states : playing
        guard let app = pool.keys.max(by: { (stamps[$0] ?? .distantPast) < (stamps[$1] ?? .distantPast) }),
              let np = states[app] else {
            onUpdate?(nil)
            return
        }
        onUpdate?(MediaSnapshot(nowPlaying: np, artwork: artworks[np.trackKey]))
    }

    // MARK: Artwork

    private func requestArtwork(for np: NowPlaying, player: Player, spotifyURL: String?) {
        let key = np.trackKey
        guard artworks[key] == nil, !artworkRequested.contains(key) else { return }
        artworkRequested.insert(key)

        func store(_ image: NSImage?) {
            guard let image else { return }
            artworks[key] = image
            if artworks.count > 40, let drop = artworks.keys.first(where: { $0 != key }) { artworks[drop] = nil }
            emit()
        }

        if player.app == .spotify, let urlString = spotifyURL, let url = URL(string: urlString) {
            Task { store(await Self.download(url)) }
            return
        }
        runner.run("tell application \"Music\" to get data of artwork 1 of current track") { descriptor in
            let image = descriptor.flatMap { NSImage(data: $0.data) }
            Task { @MainActor in
                if let image { store(image) } else { store(await Self.searchArtwork(for: np)) }
            }
        }
    }

    private nonisolated static func download(_ url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    /// Streaming tracks that are not in the library have no embedded artwork; ask the iTunes catalogue.
    private nonisolated static func searchArtwork(for np: NowPlaying) async -> NSImage? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: "\(np.artist) \(np.title)"),
                                 URLQueryItem(name: "entity", value: "song"),
                                 URLQueryItem(name: "limit", value: "1")]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let small = first["artworkUrl100"] as? String,
              let big = URL(string: small.replacingOccurrences(of: "100x100", with: "600x600"))
        else { return nil }
        return await download(big)
    }
}

/// NSAppleScript is not thread safe, so every script runs on one serial queue.
final class ScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dynamicnotch.applescript", qos: .userInitiated)
    private var cache: [String: NSAppleScript] = [:]

    func run(_ source: String, completion: @escaping @Sendable (NSAppleEventDescriptor?) -> Void) {
        queue.async { [self] in
            let script = cache[source] ?? NSAppleScript(source: source)
            cache[source] = script
            var error: NSDictionary?
            let result = script?.executeAndReturnError(&error)
            if let error, (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                NSLog("DynamicNotch: automation permission denied for script")
            }
            completion(error == nil ? result : nil)
        }
    }
}
