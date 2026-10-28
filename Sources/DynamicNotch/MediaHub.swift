import AppKit

struct MediaSnapshot {
    var nowPlaying: NowPlaying
    var artwork: NSImage?
}

/// A source of now-playing information. The hub merges every provider into one stream.
@MainActor
protocol MediaProvider: AnyObject {
    var onUpdate: ((MediaSnapshot?) -> Void)? { get set }
    func start()
    func send(_ command: MediaCommand)
    func seek(to seconds: TimeInterval)
}

/// Picks the provider that is playing (most recent wins) and forwards commands to it.
@MainActor
final class MediaHub {
    var onUpdate: ((MediaSnapshot?) -> Void)?

    private var providers: [MediaProvider]
    private var snapshots: [Int: (snapshot: MediaSnapshot, stamp: Date)] = [:]
    private var activeIndex: Int?
    private var clearTask: Task<Void, Never>?

    init(providers: [MediaProvider]) {
        self.providers = providers
        for (index, provider) in providers.enumerated() {
            provider.onUpdate = { [weak self] snapshot in self?.receive(snapshot, from: index) }
        }
    }

    func start() { providers.forEach { $0.start() } }

    /// Adds a provider at runtime (used when the primary one turns out to be broken).
    func add(_ provider: MediaProvider) {
        let index = providers.count
        providers.append(provider)
        provider.onUpdate = { [weak self] snapshot in self?.receive(snapshot, from: index) }
        provider.start()
    }

    func send(_ command: MediaCommand) { activeIndex.map { providers[$0].send(command) } }
    func seek(to seconds: TimeInterval) { activeIndex.map { providers[$0].seek(to: seconds) } }

    private func receive(_ snapshot: MediaSnapshot?, from index: Int) {
        clearTask?.cancel(); clearTask = nil
        if let snapshot {
            let wasPlaying = snapshots[index]?.snapshot.nowPlaying.isPlaying == true
            let stamp = (snapshot.nowPlaying.isPlaying && !wasPlaying) ? Date() : (snapshots[index]?.stamp ?? Date())
            snapshots[index] = (snapshot, stamp)
        } else {
            snapshots[index] = nil
        }

        let playing = snapshots.filter { $0.value.snapshot.nowPlaying.isPlaying }
        let pool = playing.isEmpty ? snapshots : playing
        let best = pool.max { $0.value.stamp < $1.value.stamp }
        activeIndex = best?.key
        guard let best else {
            // Switching tracks or apps briefly reports "nothing"; only believe it if it lasts.
            clearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled, let self else { return }
                self.onUpdate?(nil)
            }
            return
        }
        onUpdate?(best.value.snapshot)
    }
}
