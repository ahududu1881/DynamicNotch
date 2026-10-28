import AppKit
import Combine
import SwiftUI
import ServiceManagement

@MainActor
final class HealthStore: ObservableObject {
    @Published var statuses: [ComponentStatus] = []
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController!
    private var hub: MediaHub!
    private var system: SystemEventsCoordinator!
    private var statusItem: NSStatusItem!
    private var api: NotchAPI!
    private let notifications = NotificationMonitor()
    private let focus = FocusMonitor()
    private let touchID = TouchIDMonitor()
    private let screenRecording = ScreenRecordingMonitor()
    private var systemMedia: SystemMediaProvider?
    private var scriptingFallbackActive = false
    private let health = HealthStore()
    private var demo: DemoRunner!
    let plugins = PluginManager()
    private var settingsWindow: NSWindow?
    private let settingsNavigation = SettingsNavigation()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller.start()

        // MediaRemote sees every app; fall back to Music/Spotify scripting if the bridge is not bundled.
        let provider: MediaProvider
        if SystemMediaProvider.isAvailable {
            let system = SystemMediaProvider()
            // If macOS breaks the bridge, Apple Music and Spotify keep working through scripting.
            system.onUnavailable = { [weak self] _ in
                guard let self, !self.scriptingFallbackActive else { return }
                self.scriptingFallbackActive = true
                self.hub.add(ScriptablePlayerProvider())
            }
            systemMedia = system
            provider = system
        } else {
            scriptingFallbackActive = true
            provider = ScriptablePlayerProvider()
        }
        hub = MediaHub(providers: [provider])
        hub.onUpdate = { [weak self] snapshot in
            guard let self else { return }
            let previous = self.controller.model.media
            self.controller.model.setMedia(snapshot?.nowPlaying, artwork: snapshot?.artwork)
            self.plugins.updateMedia(snapshot?.nowPlaying, previous: previous)
        }
        controller.model.onCommand = { [weak self] in self?.hub.send($0) }
        controller.model.onSeek = { [weak self] in self?.hub.seek(to: $0) }
        controller.model.onActivityFinished = { [weak self] activity in self?.timerFinished(activity) }
        hub.start()

        system = SystemEventsCoordinator(controller: controller)
        system.plugins = plugins
        system.start()
        startPlugins()

        api = NotchAPI(controller: controller, hub: hub)
        demo = DemoRunner(model: controller.model)
        api.diagnostics = { [weak self] in self?.collectDiagnostics() ?? [] }
        api.demo = { [weak self] kind in self?.demo.run(kind) ?? false }
        api.apply()
        let settings = Settings.shared
        Publishers.Merge3(settings.$apiEnabled.map { _ in () }, settings.$apiToken.map { _ in () }, settings.$apiPort.map { _ in () })
            .dropFirst(3)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.api.apply() }
            .store(in: &cancellables)

        controller.model.onOpenBatterySettings = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
        }
        controller.model.onOpenApp = { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        notifications.onNotification = { [weak self] item in
            MainActor.assumeIsolated { self?.mirror(item) }
        }
        notifications.start()
        focus.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.showFocus(event) }
        }
        focus.start()
        touchID.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handleTouchID(event) }
        }
        touchID.start()
        screenRecording.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handleRecording(event) }
        }
        screenRecording.start()

        setupStatusItem()
        controller.setEnabled(settings.notchEnabled)
        applyAppearance()
        observeSettings()
        checkAfterOSUpdate()
    }

    /// Clicking the Dock icon, or launching the app again from Finder, opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: Appearance (Dock icon, menu bar icon, language)

    private func observeSettings() {
        let settings = Settings.shared
        settings.$showInDock.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.applyAppearance() } }.store(in: &cancellables)
        settings.$showMenuBarIcon.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.applyAppearance() } }.store(in: &cancellables)
        settings.$notchEnabled.dropFirst().sink { [weak self] enabled in self?.controller.setEnabled(enabled) }.store(in: &cancellables)
        settings.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.settingsWindow?.title = L("Dynamic Notch Ayarları", "Dynamic Notch Settings")
                self?.buildMainMenu()
            }
        }.store(in: &cancellables)
    }

    private func applyAppearance() {
        let settings = Settings.shared
        let policy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            // Changing the policy sends windows to the back; bring Settings forward again.
            if settingsWindow?.isVisible == true {
                NSApp.activate(ignoringOtherApps: true)
                settingsWindow?.makeKeyAndOrderFront(nil)
            }
        }
        statusItem?.isVisible = settings.showMenuBarIcon
        buildMainMenu()
    }

    /// The menu bar shown while the app is in the Dock.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        appItem.submenu = app
        func add(_ title: String, _ action: Selector?, _ key: String = "", target: AnyObject? = self) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            app.addItem(item)
        }
        add(L("Dynamic Notch Hakkında", "About Dynamic Notch"), #selector(showAbout))
        app.addItem(.separator())
        add(L("Ayarlar…", "Settings…"), #selector(showSettings), ",")
        app.addItem(.separator())
        add(L("Dynamic Notch'u Gizle", "Hide Dynamic Notch"), #selector(NSApplication.hide(_:)), "h", target: NSApp)
        app.addItem(.separator())
        add(L("Dynamic Notch'tan Çık", "Quit Dynamic Notch"), #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        NSApp.mainMenu = main
    }

    // MARK: Plugins

    private func startPlugins() {
        let model = controller.model
        plugins.actions = PluginActions(
            showHUD: { kind, duration, id in model.showHUD(kind, duration: duration, id: id) },
            canShow: { [weak self] kind in self?.controller.canShow(kind) ?? false },
            upsertActivity: { model.upsertActivity($0) },
            removeActivity: { id in model.endActivity(id: id) },
            removeAllActivities: { prefix in model.activities.filter { $0.id.hasPrefix(prefix) }.forEach { model.endActivity(id: $0.id) } },
            mediaCommand: { [weak self] action, seconds in
                switch action {
                case "toggle": self?.hub.send(.toggle)
                case "next": self?.hub.send(.next)
                case "previous": self?.hub.send(.previous)
                case "seek": if let seconds { self?.hub.seek(to: seconds) }
                default: break
                }
            },
            setVolume: { level in AudioControl.shared.setVolume(level) },
            currentVolume: { AudioControl.shared.volume() },
            open: { NSWorkspace.shared.open($0) })
        model.onOpenURL = { text in
            if let safe = JSONField.safeURL(text), let url = URL(string: safe) { NSWorkspace.shared.open(url) }
        }
        plugins.start()
    }

    // MARK: Health

    func collectDiagnostics() -> [ComponentStatus] {
        func status(_ name: String, ok: Bool, warn: Bool = false, _ detail: String) -> ComponentStatus {
            ComponentStatus(name: name, level: ok ? .ok : (warn ? .warning : .failure), detail: detail)
        }
        var list: [ComponentStatus] = []
        let geometry = controller.model.geometry
        list.append(status(L("Notch", "Notch"), ok: true,
                           geometry.hasHardwareNotch ? "\(Int(geometry.notchWidth))×\(Int(geometry.notchHeight)) pt" : L("donanım notch'u yok, simüle ediliyor", "no hardware notch, simulated")))

        if let media = systemMedia {
            let text = media.statusDescription
            let working = !text.hasPrefix("failed") && !text.hasPrefix("not running")
            list.append(status(L("Medya (tüm uygulamalar)", "Media (all apps)"), ok: working,
                               scriptingFallbackActive ? L("köprü çalışmıyor, Music/Spotify'a geçildi: ", "bridge down, using Music/Spotify scripting: ") + text : text))
        } else {
            list.append(status(L("Medya", "Media"), ok: true, warn: true, L("köprü pakette yok; yalnızca Music/Spotify", "bridge not bundled; Music/Spotify only")))
        }

        list.append(status(L("Erişilebilirlik izni", "Accessibility permission"), ok: system.hasAccessibility, warn: true,
                           system.hasAccessibility ? L("verildi", "granted") : L("verilmedi: macOS göstergeleri engellenemez", "not granted: macOS HUDs cannot be replaced")))
        list.append(status(L("Tuş yakalama", "Key capture"), ok: system.tapRunning || !system.hasAccessibility, warn: true,
                           system.tapRunning ? L("çalışıyor", "running") : L("kapalı", "off")))
        list.append(status(L("Ses kontrolü", "Volume control"), ok: AudioControl.shared.canControlVolume, warn: true,
                           AudioControl.shared.canControlVolume ? L("çalışıyor", "works") : L("bu çıkış cihazında ses ayarlanamıyor", "this output cannot be adjusted")))
        list.append(status(L("Parlaklık kontrolü", "Brightness control"), ok: BrightnessControl.shared.isAvailable, warn: true,
                           BrightnessControl.shared.isAvailable ? L("çalışıyor", "works") : L("DisplayServices kullanılamıyor", "DisplayServices unavailable")))

        switch notifications.access {
        case .granted:
            let problem = notifications.schemaProblem
            list.append(status(L("Bildirimler", "Notifications"), ok: problem == nil, problem ?? L("okunuyor", "readable")))
        case .denied:
            list.append(status(L("Bildirimler", "Notifications"), ok: false, warn: true, L("Tam Disk Erişimi gerekli", "Full Disk Access required")))
        case .missing:
            list.append(status(L("Bildirimler", "Notifications"), ok: false, L("veritabanı bulunamadı (macOS değişmiş olabilir)", "database not found (macOS may have changed)")))
        }

        list.append(status(L("Ekran kaydı algılama", "Screen recording detection"), ok: true, screenRecording.method))

        if focus.isReadable {
            list.append(status(L("Odak modları", "Focus modes"), ok: focus.problem == nil, focus.problem ?? L("okunuyor", "readable")))
        } else {
            list.append(status(L("Odak modları", "Focus modes"), ok: false, warn: true, L("Tam Disk Erişimi gerekli", "Full Disk Access required")))
        }
        list.append(status("API", ok: !Settings.shared.apiEnabled || api.isListening, warn: true,
                           Settings.shared.apiEnabled ? (api.isListening ? "127.0.0.1:\(Settings.shared.apiPort)" : L("dinlemiyor", "not listening")) : L("kapalı", "off")))
        return list
    }

    func refreshHealth() { health.statuses = collectDiagnostics() }

    /// After a macOS update, re-check every dependency and tell the user in the notch if something broke.
    private func checkAfterOSUpdate() {
        guard Diagnostics.osChangedSinceLastRun() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let statuses = self.collectDiagnostics()
                self.health.statuses = statuses
                let summary = Diagnostics.summary(statuses)
                self.controller.model.showHUD(.custom(symbol: summary.healthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                                                      text: summary.text, level: nil, tint: summary.healthy ? "#34C759" : "#FF9F0A"),
                                              duration: 5, id: "os-check")
                NSLog("DynamicNotch after macOS update:\n\(Diagnostics.report(statuses))")
            }
        }
    }

    /// A red dot and a running timer while the screen is being recorded, like the Dynamic Island on iPhone.
    private func handleRecording(_ event: ScreenRecordingStateMachine.Event) {
        let model = controller.model
        switch event {
        case .started: plugins.emit("recording", ["active": true])
        case .stopped(let duration): plugins.emit("recording", ["active": false, "seconds": duration])
        }
        guard Settings.shared.showScreenRecording else { model.endActivity(id: Activity.recordingID); return }
        switch event {
        case .started(let date):
            model.upsertActivity(Activity(id: Activity.recordingID, symbol: "record.circle.fill", text: L("Ekran kaydı", "Screen recording"),
                                          subtitle: nil, level: nil, tint: "#FF453A", startDate: date.addingTimeInterval(-1.6),
                                          expires: date.addingTimeInterval(86_400), countsUp: true))
        case .stopped(let duration):
            model.endActivity(id: Activity.recordingID)
            if duration > 3, controller.canShow(.custom(symbol: "", text: "", level: nil, tint: nil)) {
                model.showHUD(.custom(symbol: "stop.circle.fill", text: L("Ekran kaydı bitti", "Screen recording ended"), level: nil, tint: "#FF453A"),
                              duration: 2.2, id: "recording-ended")
            }
        }
    }

    private func handleTouchID(_ event: TouchIDStateMachine.Event) {
        let model = controller.model
        switch event {
        case .started: plugins.emit("touchid", ["phase": "waiting"])
        case .success: plugins.emit("touchid", ["phase": "success"])
        case .dismissed: plugins.emit("touchid", ["phase": "cancelled"])
        }
        guard Settings.shared.touchIDIndicator else { return }
        switch event {
        case .started:
            let kind = HUDKind.touchID(.waiting)
            guard controller.canShow(kind) else { return }
            model.showHUD(kind, duration: 30)   // stays until the dialog goes away
        case .success:
            // The same HUD turns into a checkmark, then leaves.
            model.showHUD(.touchID(.success), duration: TouchIDScan.successDuration)
        case .dismissed:
            model.dismissHUD(channel: "touchid")
        }
    }

    private func showFocus(_ event: FocusMonitor.Event) {
        let (mode, on): (FocusMode, Bool)
        switch event {
        case .on(let m): (mode, on) = (m, true)
        case .off(let m): (mode, on) = (m, false)
        }
        plugins.emit("focus", ["on": on, "name": mode.name, "id": mode.id])
        let kind = HUDKind.focus(name: mode.name, symbol: mode.symbol, tint: mode.tint, on: on)
        guard Settings.shared.focusToasts, controller.canShow(kind) else { return }
        controller.model.showHUD(kind, duration: 2.2, id: "focus")
    }

    /// Shows a macOS notification in the notch if it passes the user's filters.
    private func mirror(_ item: IncomingNotification) {
        let settings = Settings.shared
        if !item.bundleID.isEmpty {
            plugins.emit("notification", ["app": AppInfo.name(for: item.bundleID), "bundleId": item.bundleID,
                                          "title": item.title, "subtitle": item.subtitle, "body": item.body])
        }
        guard settings.notificationsEnabled, !controller.isSuspended, !item.bundleID.isEmpty else { return }
        if focus.activeMode != nil, !settings.notificationsDuringFocus { return }
        let app = AppInfo.name(for: item.bundleID)
        guard NotificationFilter.allows(bundleID: item.bundleID, appName: app, title: item.title, body: item.body,
                                        allApps: settings.notificationsAllApps) else { return }

        // Messaging apps put the sender in the title (or subtitle for group chats) and the text in the body.
        var title = item.title
        var body = item.body
        if !item.subtitle.isEmpty { title = title.isEmpty ? item.subtitle : "\(title) · \(item.subtitle)" }
        if !settings.notificationsShowBody { body = "" }
        controller.model.showHUD(.notification(bundleID: item.bundleID, app: app, title: title, body: body),
                                 duration: settings.notificationSeconds, id: "notif-\(item.bundleID)")
    }

    private func timerFinished(_ activity: Activity) {
        NSSound(named: "Glass")?.play()
        plugins.timerFinished(activityID: activity.id, label: activity.text)
        controller.model.showHUD(.custom(symbol: "bell.fill", text: "\(activity.text) · \(L("süre doldu", "time is up"))",
                                         level: nil, tint: "#FF9F0A"), duration: 5, id: "timer-done")
    }

    // MARK: Menu bar item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.button?.setAccessibilityLabel(AboutInfo.name)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func openSettings(page: SettingsPage? = nil) {
        if let page { settingsNavigation.page = page }
        if settingsWindow == nil {
            let view = SettingsView(settings: Settings.shared,
                                    navigation: settingsNavigation,
                                    accessibilityGranted: { [weak self] in self?.system.hasAccessibility ?? false },
                                    requestAccessibility: { [weak self] in self?.system.requestAccessibility() },
                                    testToast: { [weak self] in self?.testToast() },
                                    runDemo: { [weak self] in self?.demo.run("all") },
                                    notificationAccess: { [weak self] in self?.notifications.access ?? .denied },
                                    health: health,
                                    refreshHealth: { [weak self] in self?.refreshHealth() },
                                    plugins: plugins)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = L("Dynamic Notch Ayarları", "Dynamic Notch Settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 780, height: 580))
            window.minSize = NSSize(width: 720, height: 500)
            window.setFrameAutosaveName("DynamicNotchSettings")
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        refreshHealth()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func testToast() {
        controller.model.showHUD(.custom(symbol: "checkmark.circle.fill", text: L("Notch çalışıyor", "Notch is working"),
                                         level: nil, tint: "#34C759"))
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = Settings.shared

        func add(_ title: String, _ action: Selector, checked: Bool? = nil, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            if let checked { item.state = checked ? .on : .off }
            menu.addItem(item)
        }

        add(settings.notchEnabled ? L("Notch'u gizle", "Hide notch") : L("Notch'u göster", "Show notch"), #selector(toggleEnabled))
        menu.addItem(.separator())
        add(L("macOS ses/parlaklık göstergesini engelle", "Replace macOS volume/brightness HUD"),
            #selector(toggleIntercept), checked: settings.interceptSystemHUD)
        if !system.hasAccessibility { add(L("Erişilebilirlik izni ver…", "Grant Accessibility access…"), #selector(grantAccessibility)) }
        add(L("Girişte başlat", "Launch at login"), #selector(toggleLogin), checked: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add(L("Tüm durumları dene", "Try every state"), #selector(runDemo))
        add(L("Eklentiler klasörünü aç", "Open plugins folder"), #selector(openPlugins))
        add(L("Eklentileri yeniden yükle", "Reload plugins"), #selector(reloadPlugins))
        add(L("Ayarlar…", "Settings…"), #selector(showSettings), key: ",")
        let info = NSMenuItem(title: "API: 127.0.0.1:\(settings.apiPort)\(settings.apiEnabled ? "" : " (\(L("kapalı", "off")))")",
                              action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Çık", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleEnabled() { Settings.shared.notchEnabled.toggle() }
    @objc private func toggleIntercept() { Settings.shared.interceptSystemHUD.toggle() }
    @objc private func grantAccessibility() { system.requestAccessibility() }
    @objc private func showSettings() { openSettings() }
    @objc private func showAbout() { openSettings(page: .about) }
    @objc private func runDemo() { demo.run("all") }
    @objc private func openPlugins() { plugins.openFolder() }
    @objc private func reloadPlugins() { plugins.reload() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("DynamicNotch: login item change failed: \(error)")
        }
    }
}
