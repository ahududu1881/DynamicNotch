import AppKit
import Darwin

/// Detects when something is recording or sharing the screen.
/// macOS has no public notification for it, so this asks the window server (private SkyLight call used by the
/// system's own indicator logic) and, if that symbol ever disappears, falls back to looking for `screencapture`.
struct ScreenRecordingStateMachine {
    enum Event: Equatable { case started(Date), stopped(duration: TimeInterval) }

    /// Consecutive polls needed to switch state, so a screenshot or a brief capture is not "a recording".
    var polls = 2
    private var streak = 0
    private(set) var since: Date?

    var isRecording: Bool { since != nil }

    mutating func update(watching: Bool, now: Date) -> Event? {
        // Count agreeing polls in the direction of change.
        if watching == isRecording { streak = 0; return nil }
        streak += 1
        guard streak >= polls else { return nil }
        streak = 0
        if watching {
            since = now
            return .started(now)
        }
        let start = since ?? now
        since = nil
        return .stopped(duration: now.timeIntervalSince(start))
    }
}

final class ScreenRecordingMonitor {
    var onEvent: ((ScreenRecordingStateMachine.Event) -> Void)?

    private typealias WatcherFn = @convention(c) () -> Bool
    private static let watcher: WatcherFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let symbol = dlsym(handle, "CGSIsScreenWatcherPresent") else { return nil }
        return unsafeBitCast(symbol, to: WatcherFn.self)
    }()

    private var machine = ScreenRecordingStateMachine()
    private var timer: Timer?

    /// Which method is in use, for the health report.
    var method: String { Self.watcher != nil ? "SkyLight CGSIsScreenWatcherPresent" : "process scan (screencapture)" }
    var isRecording: Bool { machine.isRecording }
    var since: Date? { machine.since }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.2
    }

    func poll() {
        if let event = machine.update(watching: Self.isWatching(), now: Date()) { onEvent?(event) }
    }

    static func isWatching() -> Bool {
        if let watcher { return watcher() }
        return processRunning(named: "screencapture")
    }

    private static func processRunning(named target: String) -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) + 16)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            if proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == target { return true }
        }
        return false
    }
}
