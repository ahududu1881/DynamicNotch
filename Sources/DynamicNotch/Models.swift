import SwiftUI

/// The app a track is playing in (used for the badge and the fallback tint).
struct MediaApp: Equatable, Hashable {
    var bundleID: String
    var name: String

    static let music = MediaApp(bundleID: "com.apple.Music", name: "Apple Music")
    static let spotify = MediaApp(bundleID: "com.spotify.client", name: "Spotify")

    var fallbackAccent: Color {
        switch bundleID {
        case MediaApp.music.bundleID: return Color(red: 0.98, green: 0.25, blue: 0.38)
        case MediaApp.spotify.bundleID: return Color(red: 0.12, green: 0.84, blue: 0.38)
        case let id where id.contains("youtube"): return Color(red: 1.0, green: 0.2, blue: 0.2)
        default: return .white
        }
    }
}

enum MediaCommand { case toggle, next, previous }

struct NowPlaying: Equatable {
    var source: MediaApp
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var positionDate: Date
    var isPlaying: Bool

    var trackKey: String { "\(source.bundleID)|\(title)|\(artist)|\(album)" }

    func currentPosition(at date: Date = Date()) -> TimeInterval {
        let p = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }
}

/// Short-lived things the notch announces on top of whatever it is showing.
enum HUDKind: Equatable {
    case volume(level: Double, muted: Bool)
    case brightness(level: Double)
    case mediaKey(symbol: String, title: String)
    case output(name: String, symbol: String)
    case power(percent: Int, charging: Bool, plugged: Bool)
    /// Pushed by other apps through the local API. `tint` is a hex colour like "#FF9500".
    case custom(symbol: String, text: String, level: Double?, tint: String?)
    /// The Touch ID dialog is up (`waiting`) or the fingerprint was accepted (`success`).
    case touchID(TouchIDPhase)
    /// A Bluetooth accessory (AirPods, Beats...) connected or disconnected, drawn as a rotating 3D model with its battery levels.
    case accessory(name: String, model: AccessoryModel, connected: Bool, battery: AccessoryBattery?)
    /// A tile-style card pushed by a plugin: symbol, title, subtitle, optional link opened on click.
    case card(symbol: String, title: String, subtitle: String, tint: String?, url: String?)
    /// A Focus mode switched on or off.
    case focus(name: String, symbol: String, tint: String, on: Bool)
    /// A macOS notification mirrored into the notch (WhatsApp, Instagram, Messages...).
    case notification(bundleID: String, app: String, title: String, body: String)
    /// A running timer expanded into a card with pause / cancel buttons and the time left.
    case timer(id: String)
    /// The Mac is locked (padlock stays) or has just been unlocked (padlock opens).
    case lock(locked: Bool)
}

enum TouchIDPhase: Equatable { case waiting, success }

/// The kind of audio accessory, which decides which of Apple's own device drawings (SF Symbols) is shown.
enum AccessoryModel: Equatable {
    case airpods, airpods3, airpods4, airpodsPro, airpodsMax
    case beatsHeadphones, beatsEarphones, beatsFitPro, beatsStudioBuds, powerbeatsPro, powerbeats
    case jblHeadphones, jblEarbuds, jblSpeaker
    case earbuds, headphones, speaker

    /// Brand colour for the drawing; Apple and Beats drawings stay white.
    var brandTint: String? {
        switch self {
        case .jblHeadphones, .jblEarbuds, .jblSpeaker: return "#FF6A1A"
        default: return nil
        }
    }

    /// First name that exists on this macOS wins, so a future or older system still shows something sensible.
    var symbolCandidates: [String] {
        switch self {
        case .airpods: return ["airpods"]
        case .airpods3: return ["airpods.gen3", "airpods"]
        case .airpods4: return ["airpods.gen4", "airpods.gen3", "airpods"]
        case .airpodsPro: return ["airpods.pro", "airpodspro", "airpods"]
        case .airpodsMax: return ["airpods.max", "airpodsmax", "headphones"]
        case .beatsHeadphones: return ["beats.headphones", "headphones"]
        case .beatsEarphones: return ["beats.earphones", "earbuds", "headphones"]
        case .beatsFitPro: return ["beats.fitpro", "beats.earphones", "earbuds"]
        case .beatsStudioBuds: return ["beats.studiobuds", "beats.earphones", "earbuds"]
        case .powerbeatsPro: return ["beats.powerbeats.pro", "beats.earphones", "earbuds"]
        case .powerbeats: return ["beats.powerbeats", "beats.earphones", "earbuds"]
        case .jblHeadphones, .headphones: return ["headphones"]
        case .jblEarbuds, .earbuds: return ["earbuds", "airpods", "headphones"]
        case .jblSpeaker, .speaker: return ["hifispeaker.fill", "speaker.wave.2.fill"]
        }
    }

    var symbolName: String {
        symbolCandidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "headphones"
    }
}

struct AccessoryBattery: Equatable {
    var left: Int?
    var right: Int?
    var box: Int?
    var main: Int?

    var isEmpty: Bool { left == nil && right == nil && box == nil && main == nil }

    var clamped: AccessoryBattery {
        func c(_ v: Int?) -> Int? { v.map { min(max($0, 0), 100) } }
        return AccessoryBattery(left: c(left), right: c(right), box: c(box), main: c(main))
    }
}

enum HUDPriority: Int, Comparable {
    case low, normal, high, critical
    /// Tied to something happening right now that cannot wait (the Touch ID dialog).
    case immediate
    static func < (a: HUDPriority, b: HUDPriority) -> Bool { a.rawValue < b.rawValue }
}

extension HUDKind {
    /// System state changes that are still worth showing while a full-screen app is active.
    var showsInFullscreen: Bool {
        switch self {
        case .volume, .brightness, .focus, .accessory, .output, .touchID, .lock: return true
        default: return false
        }
    }

    var isTouchID: Bool { if case .touchID = self { return true } else { return false } }

    /// Wide, tall presentations (notification, battery, accessory, timer) that replace the pill and are never shown inline.
    var isCard: Bool {
        switch self {
        case .notification, .power, .card, .accessory, .timer: return true
        default: return false
        }
    }

    /// Light events that live inside the notch's own height: an icon in the left wing, an optional word in the right one.
    var isWing: Bool {
        switch self {
        case .focus, .lock: return true
        case .custom(_, let text, let level, _): return text.isEmpty && level == nil
        default: return false
        }
    }

    /// Height of the row under the notch for the compact HUD styles.
    var rowHeight: CGFloat { NotchModel.hudRow }

    var cardHeight: CGFloat {
        switch self {
        case .power: return 70
        case .accessory, .timer: return 64
        default: return 78
        }
    }

    var cardWidth: CGFloat {
        switch self {
        case .accessory: return 330
        case .timer: return 300
        default: return NotchModel.notificationWidth
        }
    }

    var priority: HUDPriority {
        switch self {
        case .volume, .brightness: return .high
        case .power(_, _, let plugged): return plugged ? .normal : .critical
        case .touchID: return .immediate
        case .custom, .notification, .focus, .accessory, .card, .timer, .lock: return .normal
        case .mediaKey, .output: return .low
        }
    }

    /// Items on the same channel update each other in place instead of queueing.
    var channel: String {
        switch self {
        case .volume: return "volume"
        case .brightness: return "brightness"
        case .mediaKey: return "mediaKey"
        case .output: return "output"
        case .power: return "power"
        case .custom: return "custom"
        case .focus: return "focus"
        case .accessory: return "accessory"
        case .card: return "card"
        case .timer: return "timer-card"
        case .lock: return "lock"
        case .touchID: return "touchid"
        case .notification(let bundleID, _, _, _): return "notification:\(bundleID)"
        }
    }

    /// Clamps levels so NaN / out-of-range values can never reach the layout code.
    var sanitized: HUDKind {
        func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
        switch self {
        case .volume(let level, let muted): return .volume(level: clamp(level), muted: muted)
        case .brightness(let level): return .brightness(level: clamp(level))
        case .power(let percent, let charging, let plugged): return .power(percent: min(max(percent, 0), 100), charging: charging, plugged: plugged)
        case .custom(let symbol, let text, let level, let tint): return .custom(symbol: symbol, text: text, level: level.map(clamp), tint: tint)
        case .card(let symbol, let title, let subtitle, let tint, let url):
            return .card(symbol: symbol, title: String(title.prefix(80)), subtitle: String(subtitle.prefix(140)), tint: tint, url: url)
        case .accessory(let name, let model, let connected, let battery):
            return .accessory(name: String(name.prefix(60)), model: model, connected: connected, battery: battery?.clamped)
        case .notification(let id, let app, let title, let body):
            return .notification(bundleID: id, app: String(app.prefix(60)), title: String(title.prefix(120)), body: String(body.prefix(240)))
        default: return self
        }
    }
}

/// A persistent item pushed by another app (download, build, timer...). Shown in the pill when no media is live.
struct Activity: Identifiable, Equatable {
    var id: String
    var symbol: String
    var text: String
    var subtitle: String?
    var level: Double?
    var tint: String?
    var startDate = Date()
    /// Countdown activities (timers) finish at this date.
    var endDate: Date?
    /// Safety net so an app that crashes cannot leave its activity on screen forever.
    var expires: Date

    /// Counts elapsed time instead of remaining time (the screen recording indicator).
    var countsUp = false
    /// Set while a timer is paused: the time that was left at that moment.
    var pausedRemaining: TimeInterval?
    static let recordingID = "system.recording"

    var isRecording: Bool { id == Activity.recordingID }
    var isTimer: Bool { endDate != nil }

    var isPaused: Bool { pausedRemaining != nil }

    func remaining(at date: Date = Date()) -> TimeInterval {
        if let pausedRemaining { return max(0, pausedRemaining) }
        return max(0, (endDate ?? date).timeIntervalSince(date))
    }
    var totalDuration: TimeInterval { max(1, (endDate ?? startDate).timeIntervalSince(startDate)) }
}

enum Presentation: Equatable {
    case idle, live, expanded
    case hud(HUDKind)
}

struct AudioOutput: Identifiable, Equatable {
    let id: UInt32
    let name: String
    let symbol: String
    let isDefault: Bool
    var isBluetooth = false
}
