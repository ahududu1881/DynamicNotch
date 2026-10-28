import Foundation

/// Model / name helpers for Bluetooth audio accessories (AirPods, Beats, speakers...).
enum AccessoryInfo {
    /// Apple Bluetooth product ids; they identify the model even when the user renamed the device.
    private static let productSymbols: [String: String] = [
        "2002": "airpods", "200f": "airpods", "2013": "airpods.gen3",
        "200e": "airpods.pro", "2014": "airpods.pro", "2024": "airpods.pro", "2027": "airpods.pro",
        "200a": "airpods.max", "201f": "airpods.max",
        "2019": "airpods.gen4", "201b": "airpods.gen4",
    ]

    static func symbol(name: String, productID: String? = nil) -> String {
        if let id = productID?.lowercased().replacingOccurrences(of: "0x", with: ""),
           let known = productSymbols[id] {
            return JSONField.symbol(known, fallback: "airpods")
        }
        let lower = name.lowercased()
        if lower.contains("airpods max") { return JSONField.symbol("airpods.max", fallback: "headphones") }
        if lower.contains("airpods pro") { return JSONField.symbol("airpods.pro", fallback: "airpods") }
        if lower.contains("airpods") { return JSONField.symbol("airpods", fallback: "headphones") }
        if lower.contains("beats") { return JSONField.symbol("beats.headphones", fallback: "headphones") }
        if lower.contains("speaker") || lower.contains("hoparlör") || lower.contains("soundbar") { return "hifispeaker.fill" }
        return "headphones"
    }

    /// Which device drawing fits an accessory. The Apple product id wins over the (user editable) name.
    static func model(name: String, productID: String? = nil) -> AccessoryModel {
        if let id = productID?.lowercased().replacingOccurrences(of: "0x", with: "") {
            switch id {
            case "200a", "201f": return .airpodsMax
            case "200e", "2014", "2024", "2027": return .airpodsPro
            case "2002", "200f": return .airpods
            case "2013": return .airpods3
            case "2019", "201b": return .airpods4
            case "200b": return .powerbeatsPro
            default: break
            }
        }
        let lower = name.lowercased()
        if lower.contains("airpods max") { return .airpodsMax }
        if lower.contains("airpods pro") { return .airpodsPro }
        if lower.contains("airpods") {
            if lower.contains("4") { return .airpods4 }
            if lower.contains("3") { return .airpods3 }
            return .airpods
        }
        if lower.contains("beats") {
            if lower.contains("fit pro") { return .beatsFitPro }
            if lower.contains("studio buds") || lower.contains("studiobuds") { return .beatsStudioBuds }
            if lower.contains("powerbeats pro") { return .powerbeatsPro }
            if lower.contains("powerbeats") { return .powerbeats }
            if ["buds", "flex", "tour", "beats x", "beats solo buds"].contains(where: { lower.contains($0) }) { return .beatsEarphones }
            return .beatsHeadphones
        }

        // Other brands: decide by what the product is. JBL gets its own accent colour.
        let isJBL = lower.contains("jbl")
        let earbudHints = ["buds", "earbud", "tws", "wf-", "freebuds", "airdots", "liberty", "true wireless", "pods"]
        let speakerHints = ["speaker", "hoparlör", "soundbar", "homepod", "flip", "charge", "boombox", "partybox", "xtreme", "pulse", "clip",
                            "wonderboom", "megaboom", "soundlink", "go 2", "go 3", "go 4"]
        if earbudHints.contains(where: lower.contains) { return isJBL ? .jblEarbuds : .earbuds }
        if speakerHints.contains(where: lower.contains) { return isJBL ? .jblSpeaker : .speaker }
        if isJBL { return .jblHeadphones }
        return .headphones
    }

    /// "Ahmet Can’s AirPods Pro" -> "AirPods Pro".
    static func displayName(_ name: String) -> String {
        for marker in ["’s ", "'s ", "’ ", "' "] {
            if let range = name.range(of: marker), name.lowercased().contains("airpods") || name.lowercased().contains("beats") {
                let rest = String(name[range.upperBound...])
                if !rest.isEmpty { return rest }
            }
        }
        return name
    }
}

struct BluetoothDeviceInfo: Equatable {
    var name: String
    var productID: String?
    var battery: AccessoryBattery?
}

enum BluetoothInfo {
    /// Finds a connected device in `system_profiler SPBluetoothDataType -json` output.
    static func parse(_ data: Data, matching name: String) -> BluetoothDeviceInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let section = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = section["device_connected"] as? [[String: Any]] else { return nil }

        let wanted = name.lowercased()
        for entry in connected {
            for (deviceName, rawInfo) in entry {
                let candidate = deviceName.lowercased()
                guard candidate == wanted || candidate.contains(wanted) || wanted.contains(candidate),
                      let info = rawInfo as? [String: Any] else { continue }
                return BluetoothDeviceInfo(name: deviceName, productID: info["device_productID"] as? String, battery: battery(from: info))
            }
        }
        return nil
    }

    static func battery(from info: [String: Any]) -> AccessoryBattery? {
        func level(_ key: String) -> Int? {
            guard let text = info[key] as? String, text.contains("%") else { return nil }
            return Int(text.filter(\.isNumber))
        }
        // Single-battery devices (speakers, most non-Apple headphones) report one level under either key.
        let battery = AccessoryBattery(left: level("device_batteryLevelLeft"), right: level("device_batteryLevelRight"),
                                       box: level("device_batteryLevelCase"),
                                       main: level("device_batteryLevelMain") ?? level("device_batteryLevel"))
        return battery.isEmpty ? nil : battery
    }

    /// Runs system_profiler off the main thread (it takes about a second) with a hard timeout.
    static func fetch(matching name: String, timeout: TimeInterval = 6, completion: @escaping @Sendable (BluetoothDeviceInfo?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            task.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return completion(nil) }

            let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            killer.cancel()
            completion(parse(data, matching: name))
        }
    }
}
