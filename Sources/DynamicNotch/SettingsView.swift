import SwiftUI
import AppKit
import ServiceManagement

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, player, events, notifications, plugins, permissions, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("Genel", "General")
        case .player: return L("Oynatıcı", "Player")
        case .events: return L("Sistem göstergeleri", "System events")
        case .notifications: return L("Bildirimler", "Notifications")
        case .plugins: return L("Eklentiler", "Plugins")
        case .permissions: return L("İzinler", "Permissions")
        case .advanced: return L("Gelişmiş", "Advanced")
        case .about: return L("Hakkında", "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .player: return "play.rectangle"
        case .events: return "bolt.horizontal"
        case .notifications: return "bell.badge"
        case .plugins: return "puzzlepiece.extension"
        case .permissions: return "lock.shield"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

/// Lets the app jump to a page, e.g. About from the app menu.
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage? = .general
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var navigation: SettingsNavigation
    var accessibilityGranted: () -> Bool
    var requestAccessibility: () -> Void
    var testToast: () -> Void
    var runDemo: () -> Void
    var notificationAccess: () -> NotificationMonitor.Access
    @ObservedObject var health: HealthStore
    var refreshHealth: () -> Void
    @ObservedObject var plugins: PluginManager

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmReset = false
    /// Bumped by a timer so permission badges follow what the user does in System Settings.
    @State private var permissionTick = 0

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $navigation.page) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 184, max: 220)
        } detail: {
            let current = navigation.page ?? .general
            Form { content(for: current) }
                .formStyle(.grouped)
                .navigationTitle(current.title)
        }
        .frame(minWidth: 720, minHeight: 500)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            if navigation.page == .permissions { permissionTick += 1 }
        }
    }

    @ViewBuilder
    private func content(for page: SettingsPage) -> some View {
        switch page {
        case .general: generalPage
        case .player: playerPage
        case .events: eventsPage
        case .notifications: notificationsPage
        case .plugins: pluginsPage
        case .permissions: permissionsPage
        case .advanced: advancedPage
        case .about: aboutPage
        }
    }

    // MARK: General

    private var generalPage: some View {
        Group {
            Section {
                toggle(L("Dynamic Notch açık", "Dynamic Notch is on"),
                       L("Kapatınca notch hiçbir şey göstermez; uygulama menü çubuğunda kalır.",
                         "When off the notch shows nothing; the app stays in the menu bar."),
                       $settings.notchEnabled)
                Picker(L("Dil", "Language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }

            Section(L("Uygulama simgeleri", "App icons")) {
                toggle(L("Dock'ta göster", "Show in the Dock"),
                       L("Kapalıyken uygulama yalnızca menü çubuğunda yaşar.", "When off the app lives in the menu bar only."),
                       $settings.showInDock)
                    .disabled(settings.showInDock && !settings.showMenuBarIcon)
                toggle(L("Menü çubuğu simgesini göster", "Show the menu bar icon"), nil, $settings.showMenuBarIcon)
                    .disabled(settings.showMenuBarIcon && !settings.showInDock)
                Text(L("İkisinden biri her zaman açık kalır, böylece ayarlara her zaman ulaşabilirsin. Uygulamayı Finder'dan yeniden açmak da bu pencereyi getirir.",
                       "One of the two always stays on so you can always get back here. Opening the app again from Finder also brings up this window."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Başlangıç", "Startup")) {
                Toggle(L("Girişte başlat", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }

            Section {
                HStack {
                    Button(L("Deneme bildirimi", "Test toast"), action: testToast)
                    Button(L("Tüm durumları dene", "Try every state"), action: runDemo)
                    Spacer()
                    Button(L("Dynamic Notch'tan çık", "Quit Dynamic Notch")) { NSApp.terminate(nil) }
                }
            }
        }
    }

    // MARK: Player

    private var playerPage: some View {
        Group {
            Section(L("Etkileşim", "Interaction")) {
                toggle(L("Üzerine gelince oynatıcıyı aç", "Open the player on hover"), nil, $settings.expandOnHover)
                toggle(L("Kaydırma hareketleri", "Scroll gestures"),
                       L("Notch üstünde yukarı/aşağı kaydır = ses, oynatıcıda sağa/sola = şarkı atla.",
                         "Scroll up/down over the notch for volume, left/right on the player to skip."),
                       $settings.scrollGestures)
                toggle(L("Klavye kısayolları", "Keyboard shortcuts"),
                       L("⌃⌥ + Boşluk, ←, →, ↑, ↓, N", "⌃⌥ + Space, ←, →, ↑, ↓, N"), $settings.hotkeys)
                toggle(L("Şarkı adı çizgisi", "Title strip"),
                       L("Yeni şarkıda pill'in altında şarkı adı kısa süre görünür.", "The track title peeks out under the pill when a new track starts."),
                       $settings.showTitleStrip)
            }

            Section(L("Zamanlama", "Timing")) {
                slider(L("Animasyon hızı", "Animation speed"), $settings.animationSpeed, 0.6...1.8, format: "%.1f×")
                slider(L("Şarkı adı çizgisi (sn)", "Title strip (s)"), $settings.titleStripSeconds, 0.5...6, format: "%.1f")
                    .disabled(!settings.showTitleStrip)
                slider(L("Duraklatınca pill ne kadar kalsın (sn)", "Keep pill after pause (s)"), $settings.pauseLingerSeconds, 2...60, format: "%.0f")
                slider(L("Fare çıkınca kapanma gecikmesi (sn)", "Collapse delay (s)"), $settings.autoCollapseDelay, 0.05...2, format: "%.2f")
                slider(L("Varsayılan bildirim süresi (sn)", "Default toast length (s)"), $settings.defaultToastSeconds, 0.8...8, format: "%.1f")
            }
        }
    }

    // MARK: System events

    private var eventsPage: some View {
        Group {
            Section(L("Ses ve parlaklık", "Volume and brightness")) {
                toggle(L("macOS göstergesini notch ile değiştir", "Replace the macOS volume/brightness HUD"),
                       L("Ses, parlaklık ve medya tuşları notch'ta görünür. Erişilebilirlik izni gerekir.",
                         "Volume, brightness and media keys show in the notch. Needs Accessibility access."),
                       $settings.interceptSystemHUD)
                if settings.interceptSystemHUD && !accessibilityGranted() {
                    Button(L("Erişilebilirlik izni ver…", "Grant Accessibility access…"), action: requestAccessibility)
                }
                toggle(L("Medya tuşlarında bildirim göster", "Show media key toasts"), nil, $settings.showMediaKeyToasts)
                toggle(L("Ses çıkışı değişince göster", "Show output device changes"), nil, $settings.showOutputToasts)
            }

            Section(L("Donanım ve sistem", "Hardware and system")) {
                toggle(L("AirPods ve Bluetooth kulaklıklar", "AirPods and Bluetooth headphones"),
                       L("Bağlanınca ve çıkınca model ikonu ve pil seviyesiyle gösterir.", "Shows the model and battery when they connect or leave."),
                       $settings.showAccessoryToasts)
                toggle(L("Touch ID istenince göster", "Show when Touch ID is requested"), nil, $settings.touchIDIndicator)
                toggle(L("Ekran kaydı sürerken göster", "Show while the screen is being recorded"), nil, $settings.showScreenRecording)
                toggle(L("Şarj ve düşük pil bildirimleri", "Charging and low battery cards"), nil, $settings.showBatteryToasts)
                toggle(L("Odak modu açılıp kapanınca göster", "Show Focus turning on/off"),
                       L("Tam Disk Erişimi gerekir.", "Needs Full Disk Access."), $settings.focusToasts)
                toggle(L("Kilit ekranında göster", "Show on the lock screen"),
                       L("Ekran kilitliyken notch'ta bir asma kilit görünür, açınca kilit açılır. macOS'un belgelenmemiş bir özelliğini kullanır.",
                         "A padlock sits in the notch while the Mac is locked and opens on unlock. Uses an undocumented macOS feature."),
                       $settings.showLockIndicator)
            }
        }
    }

    // MARK: Notifications

    private var notificationsPage: some View {
        Group {
            Section {
                toggle(L("Bildirimleri notch'ta göster", "Show notifications in the notch"), nil, $settings.notificationsEnabled)
                Group {
                    toggle(L("Tüm uygulamalar", "All apps"),
                           L("Kapalıyken yalnızca WhatsApp, Instagram, Mesajlar, Telegram, Slack, Discord ve Mail.",
                             "When off only WhatsApp, Instagram, Messages, Telegram, Slack, Discord and Mail."),
                           $settings.notificationsAllApps)
                    toggle(L("Mesaj içeriğini göster", "Show message text"),
                           L("Kapalıyken yalnızca gönderen görünür.", "When off only the sender is shown."), $settings.notificationsShowBody)
                    toggle(L("Odak modundayken de göster", "Also show during a Focus"),
                           L("Kapalıyken Odak sırasında notch sessiz kalır.", "When off the notch stays quiet during a Focus."),
                           $settings.notificationsDuringFocus)
                    slider(L("Ekranda kalma süresi (sn)", "On-screen time (s)"), $settings.notificationSeconds, 2...20, format: "%.0f")
                }
                .disabled(!settings.notificationsEnabled)
            }

            Section {
                if settings.notificationsEnabled, notificationAccess() != .granted {
                    Text(L("Bildirimleri okumak için Tam Disk Erişimi gerekir.", "Reading notifications needs Full Disk Access."))
                        .font(.caption).foregroundStyle(.orange)
                    Button(L("Tam Disk Erişimi ayarını aç…", "Open Full Disk Access settings…")) { SettingsLinks.open(.fullDiskAccess) }
                }
                Button(L("macOS bildirim ayarlarını aç…", "Open macOS notification settings…")) { SettingsLinks.open(.notifications) }
                Text(L("macOS'un kendi afişini kaldırmak için o uygulamanın bildirim stilini \"Hiçbiri\" yap; bildirim yine Bildirim Merkezi'ne düşer ve burada görünür.",
                       "To hide macOS's own banner set that app's alert style to \"None\"; it still reaches Notification Center and shows up here."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Plugins

    private var pluginsPage: some View {
        Group {
            Section {
                if plugins.plugins.isEmpty {
                    Text(L("Henüz eklenti yok. Örnekleri ekleyip içlerine bakabilir, kendi eklentini aynı klasöre yazabilirsin.",
                           "No plugins yet. Add the examples, then write your own in the same folder."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(plugins.plugins) { plugin in PluginRow(plugin: plugin, manager: plugins) }
            }
            Section {
                HStack {
                    Button(L("Klasörü aç", "Open folder")) { plugins.openFolder() }
                    Button(L("Yeniden yükle", "Reload")) { plugins.reload() }
                    Spacer()
                    Button(L("Örnek eklentileri ekle", "Add example plugins")) { plugins.installExamples() }
                }
            }
        }
    }

    // MARK: Permissions

    private var permissionsPage: some View {
        let _ = permissionTick
        return Group {
            Section {
                permissionRow(symbol: "hand.tap", title: L("Erişilebilirlik", "Accessibility"),
                              detail: L("Ses, parlaklık ve medya tuşlarını yakalamak için.", "To capture the volume, brightness and media keys."),
                              granted: accessibilityGranted()) {
                    if accessibilityGranted() { SettingsLinks.open(.accessibility) } else { requestAccessibility() }
                }
                permissionRow(symbol: "externaldrive", title: L("Tam Disk Erişimi", "Full Disk Access"),
                              detail: L("Bildirimleri ve Odak modunu okumak için.", "To read notifications and Focus changes."),
                              granted: notificationAccess() == .granted) {
                    SettingsLinks.open(.fullDiskAccess)
                }
                permissionRow(symbol: "applescript", title: L("Otomasyon", "Automation"),
                              detail: L("Music ve Spotify'ı doğrudan denetlemek için; ilk kullanımda macOS kendisi sorar.",
                                        "To control Music and Spotify directly; macOS asks the first time it is needed."),
                              granted: nil) {
                    SettingsLinks.open(.automation)
                }
            }
            Section {
                Text(L("Hiçbir izin verilmezse de uygulama çalışır; yalnızca ilgili özellikler kapalı kalır.",
                       "The app works without any of them; only the matching features stay off."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(symbol: String, title: String, detail: String, granted: Bool?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 26).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let granted {
                Label(granted ? L("Verildi", "Granted") : L("Verilmedi", "Not granted"),
                      systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .labelStyle(.titleAndIcon).font(.caption)
                    .foregroundStyle(granted ? Color.green : Color.orange)
            }
            Button(granted == true ? L("Ayarlar…", "Settings…") : L("İzin ver…", "Allow…"), action: action)
        }
    }

    // MARK: Advanced

    private var advancedPage: some View {
        Group {
            Section("API") {
                toggle(L("Yerel HTTP API", "Local HTTP API"),
                       L("İsteğe bağlı; eklentiler yeterliyse kapalı kalsın. Yalnızca bu Mac'ten erişilir.",
                         "Optional; leave it off if plugins are enough. Only reachable from this Mac."),
                       $settings.apiEnabled)
                Group {
                    LabeledContent(L("Port", "Port")) {
                        TextField("", value: Binding(get: { Int(settings.apiPort) }, set: { settings.setAPIPort($0) }),
                                  format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 90).multilineTextAlignment(.trailing)
                    }
                    SecureField(L("İsteğe bağlı erişim anahtarı (Bearer)", "Optional access token (Bearer)"), text: $settings.apiToken)
                    Text("http://127.0.0.1:\(String(settings.apiPort))/v1").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .disabled(!settings.apiEnabled)
            }

            Section(L("Uyumluluk ve sağlık", "Compatibility and health")) {
                ForEach(health.statuses, id: \.name) { status in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: status.level == .ok ? "checkmark.circle.fill" : status.level == .warning ? "exclamationmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(status.level == .ok ? Color.green : status.level == .warning ? Color.orange : Color.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(status.name)
                            Text(status.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Text("macOS \(Diagnostics.osVersion)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Yeniden kontrol et", "Check again"), action: refreshHealth)
                    Button(L("Raporu kopyala", "Copy report")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Diagnostics.report(health.statuses), forType: .string)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button(L("Varsayılanlara dön", "Reset to defaults"), role: .destructive) { confirmReset = true }
                }
            }
            .confirmationDialog(L("Tüm ayarlar varsayılana dönsün mü?", "Reset every setting to its default?"),
                                isPresented: $confirmReset) {
                Button(L("Varsayılanlara dön", "Reset to defaults"), role: .destructive) { settings.resetToDefaults() }
            }
        }
    }

    // MARK: About

    private var aboutPage: some View {
        Group {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 92, height: 92)
                    Text(AboutInfo.name).font(.title2.weight(.semibold))
                    Text(L("Sürüm ", "Version ") + AboutInfo.version).font(.caption).foregroundStyle(.secondary)
                    Text(L("MacBook'un notch'unu Dynamic Island'a çevirir.", "Turns the MacBook notch into a Dynamic Island."))
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 2)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            Section {
                if let repository = AboutInfo.repository {
                    Link(L("GitHub'da aç", "View on GitHub"), destination: repository)
                    if let issues = AboutInfo.issuesURL { Link(L("Hata bildir veya özellik öner", "Report a bug or suggest a feature"), destination: issues) }
                }
                Text(L("Açık kaynak, MIT lisanslı.", "Open source under the MIT license."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("Medya, parlaklık ve bildirim özellikleri macOS'un belgelenmemiş arayüzlerini kullanır; macOS güncellemeleri bunları bozabilir. Durum \"Gelişmiş\" sayfasında görünür.",
                       "Media, brightness and notification features rely on undocumented macOS interfaces that a macOS update can break. Their status is shown on the Advanced page."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private func toggle(_ title: String, _ detail: String?, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}

/// Deep links into System Settings.
enum SettingsLinks {
    case fullDiskAccess, accessibility, automation, notifications

    static func open(_ link: SettingsLinks) {
        let text: String
        switch link {
        case .fullDiskAccess: text = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .accessibility: text = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .automation: text = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .notifications: text = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        }
        if let url = URL(string: text) { NSWorkspace.shared.open(url) }
    }
}

private struct PluginRow: View {
    let plugin: PluginStatus
    let manager: PluginManager
    @State private var showLog = false

    private var stateText: String {
        switch plugin.state {
        case .running: return L("Çalışıyor", "Running")
        case .disabled: return L("Kapalı", "Off")
        case .needsApproval: return L("Onay bekliyor", "Needs approval")
        case .denied: return L("İzin verilmedi", "Not allowed")
        case .failed(let message): return L("Hata: ", "Error: ") + message
        }
    }

    private var color: Color {
        switch plugin.state {
        case .running: return .green
        case .disabled: return .gray
        case .needsApproval, .denied: return .orange
        case .failed: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(plugin.name).fontWeight(.semibold)
                if !plugin.version.isEmpty { Text("v\(plugin.version)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if plugin.state == .denied {
                    Button(L("İzin sor", "Ask again")) { manager.reconsider(plugin.id) }
                } else if !plugin.id.hasPrefix("invalid:") {
                    Toggle("", isOn: Binding(get: { plugin.state != .disabled }, set: { manager.setEnabled(plugin.id, $0) })).labelsHidden()
                }
            }
            if !plugin.description.isEmpty { Text(plugin.description).font(.caption).foregroundStyle(.secondary) }
            Text(stateText).font(.caption).foregroundStyle(color)
            if !plugin.permissions.isEmpty {
                Text(L("İzinler: ", "Permissions: ") + plugin.permissions.map(\.title).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
            }
            if !plugin.log.isEmpty {
                Button(showLog ? L("Günlüğü gizle", "Hide log") : L("Günlüğü göster", "Show log")) { showLog.toggle() }
                    .buttonStyle(.link).font(.caption)
                if showLog {
                    Text(plugin.log.suffix(12).joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
