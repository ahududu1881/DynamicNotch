import SwiftUI
import AppKit
import Combine

extension Animation {
    /// Main shape spring. The speed setting scales the response time.
    static var notch: Animation { .spring(response: 0.42 / Settings.shared.animationSpeed, dampingFraction: 0.74) }
    static var notchQuick: Animation { .spring(response: 0.3 / Settings.shared.animationSpeed, dampingFraction: 0.74) }
}

/// All state the notch UI renders. Mutate it through the methods so every change animates.
@MainActor
final class NotchModel: ObservableObject {
    // Layout constants (points)
    static let strip: CGFloat = 16
    static let hudRow: CGFloat = 32
    /// Extra height the expanded player grows by while volume / brightness feedback is showing.
    static let inlineExtra: CGFloat = 30
    static let expandedWidth: CGFloat = 396
    static let expandedBodyHeight: CGFloat = 166
    static let outputRowHeight: CGFloat = 34
    static let outputHeaderHeight: CGFloat = 22
    /// Space between the controls and the output list, and below the last row.
    static let outputTopGap: CGFloat = 8
    static let outputBottomGap: CGFloat = 4
    static let notificationWidth: CGFloat = 372
    /// The Touch ID animation needs room below the notch.
    static let touchIDHeight: CGFloat = 76
    static let notificationHeight: CGFloat = 78
    /// Each wing of a light event (Focus, lock...) beside the camera housing.
    static let wingPillWidth: CGFloat = 50
    static let maxActivities = 8
    static let maxQueuedHUDs = 12

    @Published var geometry: NotchGeometry
    @Published private(set) var hud: HUDKind?
    /// Volume / brightness feedback shown inside the expanded player, which keeps its size.
    @Published private(set) var inlineHUD: HUDKind?
    @Published private(set) var expanded = false
    /// True while the media should be shown in the pill (playing, or recently paused).
    @Published private(set) var liveActive = false
    @Published private(set) var hovering = false
    @Published private(set) var bouncing = false
    /// The title line under the pill; shows briefly when a track or activity starts, then retracts.
    @Published private(set) var stripVisible = false
    @Published private(set) var media: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color = .white
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var currentOutput: AudioOutput?
    @Published private(set) var activities: [Activity] = []
    /// Set while a full-screen app is active: only transient HUDs may appear, never the pill or the player.
    @Published var suppressPill = false
    @Published var showOutputs = false
    /// True once nothing needs drawing; the view fades the black shape out only then.
    @Published private(set) var shapeHidden = true
    @Published var volume: Double = 0
    @Published var sourceIcon: NSImage?

    /// True while a slider is being dragged; keeps the expanded notch from collapsing.
    var isInteracting = false

    var onCommand: ((MediaCommand) -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onSelectOutput: ((AudioOutput) -> Void)?
    var onOutputsRequested: (() -> Void)?
    var onActivityFinished: ((Activity) -> Void)?
    var onOpenApp: ((String) -> Void)?
    var onOpenBatterySettings: (() -> Void)?
    var onOpenURL: ((String) -> Void)?
    /// True while any HUD is on screen (the controller uses it to reveal the panel over full-screen apps).
    var onHUDVisibility: ((Bool) -> Void)?

    private struct HUDItem {
        var kind: HUDKind
        var duration: TimeInterval
        var priority: HUDPriority
        var channel: String
    }

    private var currentHUD: HUDItem?
    private var hudQueue: [HUDItem] = []
    private var hudEnd = Date.distantPast
    private var hudTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var stripTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var artworkID: ObjectIdentifier?
    private var restTask: Task<Void, Never>?
    private var wasBig = false
    private var restObserver: AnyCancellable?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        // Look at the state once it has settled after every change.
        restObserver = objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.evaluateRest() } }
        }
    }

    /// Hides the shape once it is back to rest. After a big presentation it waits for the shrink spring to
    /// settle; after the tiny click bounce there is nothing left to wait for.
    private func evaluateRest() {
        if !isResting {
            restTask?.cancel(); restTask = nil
            if presentation != .idle { wasBig = true }
            if shapeHidden { shapeHidden = false }
            return
        }
        guard restTask == nil, !shapeHidden else { return }
        let delay = wasBig ? Self.restFadeDelay : 0.05
        wasBig = false
        restTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.restTask = nil
            if self.isResting { self.shapeHidden = true }
        }
    }

    // MARK: Derived layout

    var pillShowsMedia: Bool { !suppressPill && liveActive && media != nil }

    /// The activity occupying the pill (only when no media is live).
    /// A running screen recording always takes the pill (it is privacy relevant), otherwise the newest activity.
    var pillActivity: Activity? {
        guard !suppressPill, !pillShowsMedia else { return nil }
        return activities.first(where: \.isRecording) ?? activities.last
    }

    var isRecording: Bool { activities.contains(where: \.isRecording) }

    var presentation: Presentation {
        if let hud { return .hud(hud) }
        if suppressPill { return .idle }
        if expanded, media != nil { return .expanded }
        return (pillShowsMedia || pillActivity != nil) ? .live : .idle
    }

    var stripText: String { pillShowsMedia ? (media?.title ?? "") : (pillActivity?.text ?? "") }

    /// Hover feedback only makes sense when there is something to open.
    private var idleBulge: Bool { bouncing || (hovering && media != nil) }

    /// Nothing is drawn at all: only the hardware notch is visible.
    var isResting: Bool { presentation == .idle && !idleBulge }

    /// How long the shape needs to finish shrinking before it may fade out (see NotchRootView).
    static let restFadeDelay = 0.5

    /// Light feedback (volume, focus...) while the pill is on screen keeps the pill and grows a row below it.
    var hudOverLive: Bool {
        guard let hud, !hud.isCard, !hud.isTouchID, !hud.isWing else { return false }
        return pillShowsMedia || pillActivity != nil
    }

    /// Wider wings carry the activity text; a media pill grows a little to make room for the recording dot.
    var wing: CGFloat { pillActivity != nil ? 44 : (isRecording && pillShowsMedia ? 46 : 30) }

    var visibleRows: Int { min(max(outputs.count, 1), 4) }
    var pickerHeight: CGFloat {
        Self.outputTopGap + Self.outputHeaderHeight + CGFloat(visibleRows) * Self.outputRowHeight + Self.outputBottomGap
    }

    /// Size of the black body, without the top flares.
    var bodySize: CGSize {
        let nw = geometry.notchWidth, nh = geometry.notchHeight
        switch presentation {
        case .idle:
            if bouncing { return CGSize(width: nw + 12, height: nh + 5) }
            return idleBulge ? CGSize(width: nw + 8, height: nh + 3) : CGSize(width: nw, height: nh)
        case .live:
            let bump: CGFloat = hovering ? 8 : 0
            return CGSize(width: nw + 2 * wing + bump,
                          height: nh + (stripVisible ? Self.strip : 0) + (hovering ? 2 : 0))
        case .expanded:
            var h = nh + Self.expandedBodyHeight
            if showOutputs { h += pickerHeight }
            if inlineHUD != nil { h += Self.inlineExtra }
            return CGSize(width: Self.expandedWidth, height: h)
        case .hud(let kind):
            if kind.isCard { return CGSize(width: kind.cardWidth, height: nh + kind.cardHeight) }
            if kind.isTouchID { return CGSize(width: nw, height: nh + Self.touchIDHeight) }
            if kind.isWing { return CGSize(width: nw + 2 * Self.wingPillWidth, height: nh) }
            return CGSize(width: hudOverLive ? nw + 2 * wing : nw, height: nh + kind.rowHeight)
        }
    }

    var topRadius: CGFloat {
        switch presentation {
        case .idle: return idleBulge ? 4 : 0
        case .live: return 6
        case .hud(let kind): return kind.isCard ? 8 : (kind.isWing || hudOverLive ? 6 : 0)
        case .expanded: return 12
        }
    }

    var bottomRadius: CGFloat {
        switch presentation {
        case .idle: return idleBulge ? 12 : 8
        case .live: return 16
        case .hud(let kind): return kind.isTouchID ? 24 : 16
        case .expanded: return 30
        }
    }

    var showsShadow: Bool { presentation != .idle }

    // MARK: Pill layout

    /// Horizontal positions (in body coordinates) of everything that sits in the wings of the live pill.
    /// The middle `notchWidth` of the pill is the hardware notch: nothing may be placed there.
    enum PillLayout {
        static let waveWidth: CGFloat = 17
        static let dotSize: CGFloat = 8
        static let artworkX: CGFloat = 8
        static let artworkSize: CGFloat = 18
        static let activityIconX: CGFloat = 10
        static let activityIconSize: CGFloat = 16
        static let trailingWidth: CGFloat = 34
        static let trailingInset: CGFloat = 8
        static let gap: CGFloat = 8

        static func waveX(width: CGFloat) -> CGFloat { width - trailingInset - waveWidth }
        static func dotX(width: CGFloat) -> CGFloat { waveX(width: width) - gap - dotSize }
        static func trailingX(width: CGFloat) -> CGFloat { width - trailingInset - trailingWidth }
    }

    // MARK: Interaction

    func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        withAnimation(.notchQuick) { hovering = value }
        holdHUD(value)
    }

    /// A notification stays while the pointer is on it and leaves shortly after the pointer does.
    private func holdHUD(_ hold: Bool) {
        guard let current = currentHUD, current.kind.isCard else { return }
        hudTask?.cancel()
        guard !hold else { return }
        hudEnd = Date().addingTimeInterval(0.6)
        hudTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.finishHUD()
        }
    }

    /// Removes the current HUD only if it belongs to `channel` (e.g. a cancelled Touch ID prompt).
    func dismissHUD(channel: String) {
        hudQueue.removeAll { $0.channel == channel }
        guard currentHUD?.channel == channel else { return }
        dismissHUD()
    }

    func dismissHUD() {
        hudTask?.cancel()
        finishHUD()
    }

    func primaryClick() {
        switch presentation {
        case .idle, .live:
            if media != nil { expand() }
            else if let timer = pillActivity, timer.isTimer { showTimerCard(id: timer.id) }
            else { bounce() }
        case .hud(let kind):
            // Tapping a notification opens its app.
            if case .notification(let bundleID, _, _, _) = kind {
                onOpenApp?(bundleID)
                dismissHUD()
            } else if case .power = kind {
                onOpenBatterySettings?()
                dismissHUD()
            } else if case .card(_, _, _, _, let url) = kind {
                if let url { onOpenURL?(url) }
                dismissHUD()
            }
        case .expanded:
            break
        }
    }

    func expand() {
        guard media != nil, !expanded else { return }
        withAnimation(.notch) { expanded = true }
    }

    func collapse() {
        guard expanded || showOutputs else { return }
        withAnimation(.notch) {
            inlineHUD = nil
            expanded = false
            showOutputs = false
        }
    }

    func toggleOutputs() {
        if !showOutputs { onOutputsRequested?() }
        withAnimation(.notch) { showOutputs.toggle() }
    }

    func bounce() {
        guard !bouncing else { return }
        // A small, soft swell and release: no overshoot, so it never looks like a bounce.
        withAnimation(.spring(response: 0.28, dampingFraction: 0.95)) { bouncing = true }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.95)) { self.bouncing = false }
        }
    }

    /// Hides the notch contents immediately (used while a full-screen app is active).
    func reset() {
        hudTask?.cancel()
        hudQueue.removeAll()
        currentHUD = nil
        withAnimation(nil) {
            hud = nil
            inlineHUD = nil
            expanded = false
            showOutputs = false
            hovering = false
        }
    }

    // MARK: HUD queue

    /// Shows feedback. Same-channel items update in place, higher priority preempts, the rest queue up.
    func showHUD(_ kind: HUDKind, duration: TimeInterval = 1.7, id: String? = nil) {
        if case .volume(let level, _) = kind, level.isFinite { volume = min(max(level, 0), 1) }
        let clean = kind.sanitized
        let item = HUDItem(kind: clean, duration: min(max(duration.isFinite ? duration : 1.7, 0.3), 30),
                           priority: clean.priority, channel: id.map { "custom:\($0)" } ?? clean.channel)

        guard let current = currentHUD else { return present(item) }
        if current.channel == item.channel { return present(item) }

        // Higher priority wins. Volume / brightness feedback answers a key press, so it shows right away over
        // everything except the Touch ID dialog; a battery warning can never push aside another critical item.
        if item.priority > current.priority || (item.priority == .high && current.priority != .immediate) {
            let remaining = hudEnd.timeIntervalSinceNow
            // Things that matter come back after the interruption (but not transient volume / key feedback).
            if current.priority >= .normal, current.priority != .high, remaining > 0.8 {
                var resumed = current
                resumed.duration = remaining
                enqueue(resumed, atFront: true)
            }
            present(item)
        } else {
            enqueue(item)
        }
    }

    private func enqueue(_ item: HUDItem, atFront: Bool = false) {
        hudQueue.removeAll { $0.channel == item.channel }
        if atFront { hudQueue.insert(item, at: 0) } else { hudQueue.append(item) }
        while hudQueue.count > Self.maxQueuedHUDs {
            // Drop the oldest of the lowest priority.
            let lowest = hudQueue.map(\.priority).min() ?? .low
            if let index = hudQueue.firstIndex(where: { $0.priority == lowest }) { hudQueue.remove(at: index) }
        }
    }

    private func present(_ item: HUDItem) {
        currentHUD = item
        onHUDVisibility?(true)
        hudEnd = Date().addingTimeInterval(item.duration)
        hudQueue.removeAll { $0.channel == item.channel }

        // Inside the big player the feedback grows the player instead of replacing it.
        if expanded, media != nil, !item.kind.isTouchID, !item.kind.isCard {
            withAnimation(.notchQuick) { inlineHUD = item.kind }
        } else {
            withAnimation(.notch) { hud = item.kind }
        }

        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(item.duration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.finishHUD()
        }
    }

    private func finishHUD() {
        currentHUD = nil
        withAnimation(.notch) { hud = nil; inlineHUD = nil }
        guard !hudQueue.isEmpty else { return onHUDVisibility?(false) ?? () }
        hudTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000) // let the shape settle between items
            guard !Task.isCancelled, let self, self.currentHUD == nil, !self.hudQueue.isEmpty else { return }
            let top = self.hudQueue.map(\.priority).max() ?? .low
            if let index = self.hudQueue.firstIndex(where: { $0.priority == top }) {
                self.present(self.hudQueue.remove(at: index))
            }
        }
    }

    var queuedHUDCount: Int { hudQueue.count }

    /// Replaces what the current HUD shows without restarting its timer (e.g. battery level arriving late).
    func updateHUD(channel: String, to kind: HUDKind) {
        guard var current = currentHUD, current.channel == channel else { return }
        current.kind = kind.sanitized
        currentHUD = current
        if hud != nil { hud = current.kind }
        if inlineHUD != nil { inlineHUD = current.kind }
    }

    // MARK: Activities

    func upsertActivity(_ activity: Activity) {
        let previous = activities.first { $0.id == activity.id }
        withAnimation(.notch) {
            activities.removeAll { $0.id == activity.id }
            activities.append(activity)
            while activities.count > Self.maxActivities { activities.removeFirst() }
        }
        if previous?.text != activity.text, pillActivity?.id == activity.id { flashStrip() }
        startActivityTicker()
        // A new timer announces itself with its card.
        if previous == nil, activity.isTimer { showTimerCard(id: activity.id) }
    }

    // MARK: Timers

    func toggleTimerPause(id: String) {
        guard let index = activities.firstIndex(where: { $0.id == id }), activities[index].isTimer else { return }
        var activity = activities[index]
        let now = Date()
        if let left = activity.pausedRemaining {
            activity.endDate = now.addingTimeInterval(left)
            activity.pausedRemaining = nil
            activity.expires = max(activity.expires, now.addingTimeInterval(left + 60))
        } else {
            let left = activity.remaining(at: now)
            activity.pausedRemaining = left
            // A paused timer must not be swept away by the safety net.
            activity.expires = now.addingTimeInterval(left + 86_400)
        }
        withAnimation(.notch) { activities[index] = activity }
        extendTimerCard()
    }

    func cancelTimer(id: String) {
        endActivity(id: id)
        dismissHUD(channel: "timer-card")
    }

    /// Opens the timer's card (on start, and when its pill is clicked).
    func showTimerCard(id: String) {
        guard activities.contains(where: { $0.id == id && $0.isTimer }) else { return }
        showHUD(.timer(id: id), duration: 6)
    }

    /// Pressing a button keeps the card up a little longer.
    private func extendTimerCard() {
        if case .hud(.timer(let id)) = presentation { showHUD(.timer(id: id), duration: 5) }
    }

    @discardableResult
    func endActivity(id: String) -> Bool {
        guard activities.contains(where: { $0.id == id }) else { return false }
        withAnimation(.notch) { activities.removeAll { $0.id == id } }
        return true
    }

    private func startActivityTicker() {
        guard activityTask == nil else { return }
        activityTask = Task { [weak self] in
            while let self, !self.activities.isEmpty, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.expireActivities()
            }
            self?.activityTask = nil
        }
    }

    func expireActivities(now: Date = ViewClock.date(Date())) {
        let done = activities.filter { $0.expires <= now || ($0.pausedRemaining == nil && ($0.endDate.map { $0 <= now } ?? false)) }
        guard !done.isEmpty else { return }
        withAnimation(.notch) { activities.removeAll { a in done.contains { $0.id == a.id } } }
        for activity in done where activity.isTimer && (activity.endDate ?? .distantFuture) <= now {
            onActivityFinished?(activity)
        }
    }

    // MARK: Media

    func setMedia(_ new: NowPlaying?, artwork newArtwork: NSImage?) {
        let artChanged = newArtwork.map(ObjectIdentifier.init) != artworkID
        if artChanged {
            artworkID = newArtwork.map(ObjectIdentifier.init)
            artwork = newArtwork
            accent = newArtwork?.dominantAccent() ?? new?.source.fallbackAccent ?? .white
            if let bundleID = new?.source.bundleID { sourceIcon = Self.icon(for: bundleID) }
        }
        if new?.source != media?.source, let bundleID = new?.source.bundleID {
            sourceIcon = Self.icon(for: bundleID)
            if newArtwork == nil { accent = new?.source.fallbackAccent ?? .white }
        }
        let trackChanged = new != nil && new?.trackKey != media?.trackKey
        if new != media { media = new }
        if trackChanged, new?.isPlaying == true { flashStrip() }

        guard let new else {
            pauseTask?.cancel(); pauseTask = nil
            withAnimation(.notch) { liveActive = false; expanded = false; showOutputs = false }
            return
        }
        if new.isPlaying {
            pauseTask?.cancel(); pauseTask = nil
            if !liveActive {
                withAnimation(.notch) { liveActive = true }
                flashStrip()
            }
        } else if liveActive, pauseTask == nil {
            // Paused: keep the live activity around for a while like the Dynamic Island does.
            let linger = Settings.shared.pauseLingerSeconds
            pauseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                withAnimation(.notch) { self.liveActive = false }
                self.pauseTask = nil
            }
        }
    }

    private func flashStrip() {
        guard Settings.shared.showTitleStrip else { return }
        let seconds = Settings.shared.titleStripSeconds
        stripTask?.cancel()
        withAnimation(.notch) { stripVisible = true }
        stripTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.notch) { self.stripVisible = false }
        }
    }

    // MARK: Audio output

    func setOutputs(_ list: [AudioOutput]) {
        outputs = list
        currentOutput = list.first(where: \.isDefault)
    }

    private static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

extension NSImage {
    /// A vivid average colour of the artwork, used to tint the waveform.
    func dominantAccent() -> Color {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        let size = 8
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in 0..<(size * size) {
            let pr = Double(pixels[i * 4]) / 255, pg = Double(pixels[i * 4 + 1]) / 255, pb = Double(pixels[i * 4 + 2]) / 255
            let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
            let weight = 0.1 + (mx - mn) // favour saturated pixels
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total > 0 else { return .white }
        let ns = NSColor(red: r / total, green: g / total, blue: b / total, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        ns.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(1, max(s, 0.45))), brightness: Double(max(br, 0.82)))
    }
}
