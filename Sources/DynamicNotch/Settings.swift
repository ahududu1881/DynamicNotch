import Foundation
import Combine

/// Interface language: follows the system unless the user picks one.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, tr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("Sistem", "System")
        case .en: return "English"
        case .tr: return "Türkçe"
        }
    }
}

/// User preferences, persisted in UserDefaults. Every value has a safe default and is clamped on read.
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    /// The one place that knows the default of every setting; used by `init` and `resetToDefaults`.
    private enum Default {
        static let language = AppLanguage.system.rawValue
        static let showInDock = false
        static let showMenuBarIcon = true
        static let notchEnabled = true
        static let interceptSystemHUD = true
        static let showMediaKeyToasts = true
        static let showOutputToasts = true
        static let showScreenRecording = true
        static let touchIDIndicator = true
        static let showAccessoryToasts = true
        static let showBatteryToasts = true
        static let focusToasts = true
        static let expandOnHover = false
        static let scrollGestures = true
        static let hotkeys = true
        static let showTitleStrip = true
        static let notificationsEnabled = true
        static let notificationsAllApps = false
        static let notificationsShowBody = true
        static let notificationsDuringFocus = true
        static let notificationSeconds = 5.0
        static let apiEnabled = false
        static let apiToken = ""
        static let apiPort = 39283
        static let animationSpeed = 1.0
        static let titleStripSeconds = 1.8
        static let pauseLingerSeconds = 8.0
        static let autoCollapseDelay = 0.2
        static let defaultToastSeconds = 2.2
        static let apiPortRange = 1024...65535
    }

    // General
    @Published var language: String {
        didSet { save(language, "language"); Localization.override = AppLanguage(rawValue: language)?.code }
    }
    /// At least one of Dock icon / menu bar icon always stays on, so the app can never become unreachable.
    @Published var showInDock: Bool {
        didSet {
            save(showInDock, "showInDock")
            if !showInDock, !showMenuBarIcon { showMenuBarIcon = true }
        }
    }
    @Published var showMenuBarIcon: Bool {
        didSet {
            save(showMenuBarIcon, "showMenuBarIcon")
            if !showMenuBarIcon, !showInDock { showInDock = true }
        }
    }
    @Published var notchEnabled: Bool { didSet { save(notchEnabled, "notchEnabled") } }

    // System events
    @Published var interceptSystemHUD: Bool { didSet { save(interceptSystemHUD, "interceptSystemHUD") } }
    @Published var showMediaKeyToasts: Bool { didSet { save(showMediaKeyToasts, "showMediaKeyToasts") } }
    @Published var showAccessoryToasts: Bool { didSet { save(showAccessoryToasts, "showAccessoryToasts") } }
    @Published var touchIDIndicator: Bool { didSet { save(touchIDIndicator, "touchIDIndicator") } }
    @Published var showScreenRecording: Bool { didSet { save(showScreenRecording, "showScreenRecording") } }
    @Published var showOutputToasts: Bool { didSet { save(showOutputToasts, "showOutputToasts") } }
    @Published var showBatteryToasts: Bool { didSet { save(showBatteryToasts, "showBatteryToasts") } }
    @Published var focusToasts: Bool { didSet { save(focusToasts, "focusToasts") } }

    // Player and interaction
    @Published var expandOnHover: Bool { didSet { save(expandOnHover, "expandOnHover") } }
    @Published var scrollGestures: Bool { didSet { save(scrollGestures, "scrollGestures") } }
    @Published var hotkeys: Bool { didSet { save(hotkeys, "hotkeys") } }
    @Published var showTitleStrip: Bool { didSet { save(showTitleStrip, "showTitleStrip") } }

    // Notifications
    @Published var notificationsEnabled: Bool { didSet { save(notificationsEnabled, "notificationsEnabled") } }
    @Published var notificationsAllApps: Bool { didSet { save(notificationsAllApps, "notificationsAllApps") } }
    @Published var notificationsShowBody: Bool { didSet { save(notificationsShowBody, "notificationsShowBody") } }
    @Published var notificationSeconds: Double { didSet { save(notificationSeconds, "notificationSeconds") } }
    @Published var notificationsDuringFocus: Bool { didSet { save(notificationsDuringFocus, "notificationsDuringFocus") } }

    // Local API
    @Published var apiEnabled: Bool { didSet { save(apiEnabled, "apiEnabled") } }
    @Published var apiToken: String { didSet { save(apiToken, "apiToken") } }
    @Published var apiPort: UInt16 { didSet { save(Int(apiPort), "apiPort") } }

    // Timing
    @Published var animationSpeed: Double { didSet { save(animationSpeed, "animationSpeed") } }
    @Published var titleStripSeconds: Double { didSet { save(titleStripSeconds, "titleStripSeconds") } }
    @Published var pauseLingerSeconds: Double { didSet { save(pauseLingerSeconds, "pauseLingerSeconds") } }
    @Published var autoCollapseDelay: Double { didSet { save(autoCollapseDelay, "autoCollapseDelay") } }
    @Published var defaultToastSeconds: Double { didSet { save(defaultToastSeconds, "defaultToastSeconds") } }

    private init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            let v = d.object(forKey: key) as? Double ?? fallback
            return v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : fallback
        }
        let savedLanguage = d.string(forKey: "language").flatMap(AppLanguage.init(rawValue:))?.rawValue ?? Default.language
        language = savedLanguage
        Localization.override = AppLanguage(rawValue: savedLanguage)?.code

        var dock = bool("showInDock", Default.showInDock)
        var menuBar = bool("showMenuBarIcon", Default.showMenuBarIcon)
        if !dock, !menuBar { dock = false; menuBar = true }
        showInDock = dock
        showMenuBarIcon = menuBar
        notchEnabled = bool("notchEnabled", Default.notchEnabled)

        interceptSystemHUD = bool("interceptSystemHUD", Default.interceptSystemHUD)
        showMediaKeyToasts = bool("showMediaKeyToasts", Default.showMediaKeyToasts)
        showOutputToasts = bool("showOutputToasts", Default.showOutputToasts)
        showScreenRecording = bool("showScreenRecording", Default.showScreenRecording)
        touchIDIndicator = bool("touchIDIndicator", Default.touchIDIndicator)
        showAccessoryToasts = bool("showAccessoryToasts", Default.showAccessoryToasts)
        showBatteryToasts = bool("showBatteryToasts", Default.showBatteryToasts)
        focusToasts = bool("focusToasts", Default.focusToasts)

        expandOnHover = bool("expandOnHover", Default.expandOnHover)
        scrollGestures = bool("scrollGestures", Default.scrollGestures)
        hotkeys = bool("hotkeys", Default.hotkeys)
        showTitleStrip = bool("showTitleStrip", Default.showTitleStrip)

        notificationsEnabled = bool("notificationsEnabled", Default.notificationsEnabled)
        notificationsAllApps = bool("notificationsAllApps", Default.notificationsAllApps)
        notificationsShowBody = bool("notificationsShowBody", Default.notificationsShowBody)
        notificationSeconds = number("notificationSeconds", Default.notificationSeconds, 2...20)
        notificationsDuringFocus = bool("notificationsDuringFocus", Default.notificationsDuringFocus)

        apiEnabled = bool("apiEnabled", Default.apiEnabled)
        apiToken = d.string(forKey: "apiToken") ?? Default.apiToken
        let storedPort = d.integer(forKey: "apiPort")
        apiPort = UInt16(Default.apiPortRange.contains(storedPort) ? storedPort : Default.apiPort)

        animationSpeed = number("animationSpeed", Default.animationSpeed, 0.6...1.8)
        titleStripSeconds = number("titleStripSeconds", Default.titleStripSeconds, 0.5...6)
        pauseLingerSeconds = number("pauseLingerSeconds", Default.pauseLingerSeconds, 2...60)
        autoCollapseDelay = number("autoCollapseDelay", Default.autoCollapseDelay, 0.05...3)
        defaultToastSeconds = number("defaultToastSeconds", Default.defaultToastSeconds, 0.8...8)
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    /// Port the user typed; anything outside the unprivileged range is ignored.
    func setAPIPort(_ value: Int) {
        guard Default.apiPortRange.contains(value) else { return }
        apiPort = UInt16(value)
    }

    func resetToDefaults() {
        language = Default.language
        showMenuBarIcon = Default.showMenuBarIcon
        showInDock = Default.showInDock
        notchEnabled = Default.notchEnabled

        interceptSystemHUD = Default.interceptSystemHUD; showMediaKeyToasts = Default.showMediaKeyToasts
        showOutputToasts = Default.showOutputToasts; showScreenRecording = Default.showScreenRecording
        touchIDIndicator = Default.touchIDIndicator; showAccessoryToasts = Default.showAccessoryToasts
        showBatteryToasts = Default.showBatteryToasts; focusToasts = Default.focusToasts

        expandOnHover = Default.expandOnHover; scrollGestures = Default.scrollGestures
        hotkeys = Default.hotkeys; showTitleStrip = Default.showTitleStrip

        notificationsEnabled = Default.notificationsEnabled; notificationsAllApps = Default.notificationsAllApps
        notificationsShowBody = Default.notificationsShowBody; notificationSeconds = Default.notificationSeconds
        notificationsDuringFocus = Default.notificationsDuringFocus

        apiEnabled = Default.apiEnabled; apiToken = Default.apiToken; apiPort = UInt16(Default.apiPort)

        animationSpeed = Default.animationSpeed; titleStripSeconds = Default.titleStripSeconds
        pauseLingerSeconds = Default.pauseLingerSeconds; autoCollapseDelay = Default.autoCollapseDelay
        defaultToastSeconds = Default.defaultToastSeconds
    }
}
