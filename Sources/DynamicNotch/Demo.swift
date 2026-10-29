import AppKit

/// Plays every notch state in a row so the whole design can be reviewed (menu: "Tüm durumları dene", API: POST /v1/demo).
@MainActor
final class DemoRunner {
    struct Step {
        var name: String
        var run: (NotchModel) -> Void
        var seconds: Double
    }

    static let names = ["toast", "volume", "brightness", "focus", "airpodspro", "airpods4", "airpodsmax", "beats", "beatsbuds", "output", "charging", "battery", "critical",
                        "notification", "touchid", "timer", "recording", "lock"]

    private let model: NotchModel
    private var task: Task<Void, Never>?
    var isRunning: Bool { task != nil }

    init(model: NotchModel) { self.model = model }

    func steps(for name: String) -> [Step]? {
        switch name {
        case "toast":
            return [Step(name: name, run: { $0.showHUD(.custom(symbol: "checkmark.circle.fill", text: L("Kaydedildi", "Saved"), level: nil, tint: "#34C759"), duration: 2.4, id: "demo") }, seconds: 3)]
        case "volume":
            return [Step(name: name, run: { $0.showHUD(.volume(level: 0.3, muted: false), duration: 1.4) }, seconds: 0.9),
                    Step(name: name, run: { $0.showHUD(.volume(level: 0.7, muted: false), duration: 1.4) }, seconds: 0.9),
                    Step(name: name, run: { $0.showHUD(.volume(level: 0, muted: true), duration: 1.4) }, seconds: 2.4)]
        case "brightness":
            return [Step(name: name, run: { $0.showHUD(.brightness(level: 0.4), duration: 1.4) }, seconds: 0.9),
                    Step(name: name, run: { $0.showHUD(.brightness(level: 0.85), duration: 1.4) }, seconds: 2.4)]
        case "focus":
            return [Step(name: name, run: { $0.showHUD(.focus(name: L("İş", "Work"), symbol: "briefcase.fill", tint: "#0A84FF", on: true), duration: 2.2, id: "focus") }, seconds: 3.2),
                    Step(name: name, run: { $0.showHUD(.focus(name: L("İş", "Work"), symbol: "briefcase.fill", tint: "#0A84FF", on: false), duration: 2.2, id: "focus") }, seconds: 3.2)]
        case "airpods", "airpods3", "airpods4", "airpodspro", "airpodsmax", "beats", "beatsbuds", "powerbeats", "jbl", "jblbuds", "jblspeaker":
            let (title, model, battery): (String, AccessoryModel, AccessoryBattery) = {
                switch name {
                case "airpodsmax": return ("AirPods Max", .airpodsMax, AccessoryBattery(main: 64))
                case "airpods": return ("AirPods", .airpods, AccessoryBattery(left: 92, right: 88, box: 70))
                case "airpods3": return ("AirPods (3rd generation)", .airpods3, AccessoryBattery(left: 70, right: 72, box: 40))
                case "airpods4": return ("AirPods 4", .airpods4, AccessoryBattery(left: 92, right: 88, box: 70))
                case "jbl": return ("JBL Tune 770NC", .jblHeadphones, AccessoryBattery(main: 72))
                case "jblbuds": return ("JBL Live Buds 3", .jblEarbuds, AccessoryBattery(left: 84, right: 80, box: 60))
                case "jblspeaker": return ("JBL Flip 6", .jblSpeaker, AccessoryBattery(main: 55))
                case "powerbeats": return ("Powerbeats Pro", .powerbeatsPro, AccessoryBattery(left: 60, right: 58, box: 35))
                case "beats": return ("Beats Studio Pro", .beatsHeadphones, AccessoryBattery(main: 41))
                case "beatsbuds": return ("Beats Fit Pro", .beatsFitPro, AccessoryBattery(left: 18, right: 22, box: 85))
                default: return ("AirPods Pro", .airpodsPro, AccessoryBattery(left: 80, right: 78, box: 55))
                }
            }()
            return [Step(name: name, run: { m in
                        m.showHUD(.accessory(name: title, model: model, connected: true, battery: nil), duration: 4.6)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            MainActor.assumeIsolated { m.updateHUD(channel: "accessory", to: .accessory(name: title, model: model, connected: true, battery: battery)) }
                        }
                    }, seconds: 5.4),
                    Step(name: name, run: { $0.showHUD(.accessory(name: title, model: model, connected: false, battery: nil), duration: 2.8) }, seconds: 3.6)]
        case "output":
            return [Step(name: name, run: { $0.showHUD(.output(name: "MacBook Pro Hoparlörleri", symbol: "laptopcomputer"), duration: 2.2) }, seconds: 3.2)]
        case "charging":
            return [Step(name: name, run: { $0.showHUD(.power(percent: 78, charging: true, plugged: true), duration: 3.4) }, seconds: 4.4)]
        case "battery":
            return [Step(name: name, run: { $0.showHUD(.power(percent: 20, charging: false, plugged: false), duration: 4) }, seconds: 5)]
        case "critical":
            return [Step(name: name, run: { $0.showHUD(.power(percent: 5, charging: false, plugged: false), duration: 4) }, seconds: 5)]
        case "notification":
            return [Step(name: name, run: { $0.showHUD(.notification(bundleID: "net.whatsapp.WhatsApp", app: "WhatsApp", title: "Ayşe", body: L("Akşam yemeğe geliyor musun? Saat 8'de buluşuyoruz.", "Are you coming to dinner? We meet at 8.")), duration: 4, id: "demo-notif") }, seconds: 5)]
        case "touchid":
            return [Step(name: name, run: { $0.showHUD(.touchID(.waiting), duration: 30) }, seconds: 2.6),
                    Step(name: name, run: { $0.showHUD(.touchID(.success), duration: TouchIDScan.successDuration) }, seconds: 3.6)]
        case "timer":
            return [Step(name: name, run: { m in
                        let now = Date()
                        m.upsertActivity(Activity(id: "demo-timer", symbol: "timer", text: L("Çay", "Tea"), subtitle: nil, level: nil, tint: "#FF9F0A",
                                                  startDate: now, endDate: now.addingTimeInterval(5), expires: now.addingTimeInterval(10)))
                    }, seconds: 7)]
        case "lock":
            return [Step(name: name, run: { $0.showHUD(.lock(locked: true), duration: 30, id: "demo-lock") }, seconds: 2.4),
                    Step(name: name, run: { $0.showHUD(.lock(locked: false), duration: 1.3, id: "demo-lock") }, seconds: 2.2)]
        case "recording":
            return [Step(name: name, run: { m in
                        m.upsertActivity(Activity(id: Activity.recordingID, symbol: "record.circle.fill", text: L("Ekran kaydı", "Screen recording"), subtitle: nil,
                                                  level: nil, tint: "#FF453A", expires: Date().addingTimeInterval(60), countsUp: true))
                    }, seconds: 7),
                    Step(name: name, run: { $0.endActivity(id: Activity.recordingID) }, seconds: 1)]
        default: return nil
        }
    }

    /// Runs one state (`name`) or all of them (`"all"`). Returns false for an unknown name.
    @discardableResult
    func run(_ name: String) -> Bool {
        let list = name == "all" ? Self.names : [name]
        guard list.allSatisfy({ steps(for: $0) != nil }) else { return false }
        task?.cancel()
        task = Task { [weak self] in
            for item in list {
                for step in self?.steps(for: item) ?? [] {
                    guard !Task.isCancelled, let self else { return }
                    step.run(self.model)
                    try? await Task.sleep(nanoseconds: UInt64(step.seconds * 1_000_000_000))
                }
            }
            self?.task = nil
        }
        return true
    }
}
