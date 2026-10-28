import Foundation
import CryptoKit

/// What a plugin may ask for. Reading media state and showing things on the notch needs no permission.
enum PluginPermission: String, CaseIterable, Codable {
    /// `notch.http` / `notch.fetch`
    case network
    /// `notch.shell.run`
    case shell
    /// Media commands, setting the volume, opening URLs and apps
    case control
    /// Receiving the text of macOS notifications
    case notifications

    var title: String {
        switch self {
        case .network: return L("İnternete erişim", "Network access")
        case .shell: return L("Komut çalıştırma", "Run commands")
        case .control: return L("Medya/ses kontrolü ve bağlantı açma", "Control media and volume, open links")
        case .notifications: return L("Bildirim içeriğini okuma", "Read notification contents")
        }
    }
}

/// `plugin.json`
struct PluginManifest: Codable, Equatable {
    var id: String
    var name: String
    var version: String = "1.0"
    var description: String = ""
    var author: String = ""
    var main: String = "main.js"
    var permissions: [String] = []

    enum ManifestError: Error, Equatable, CustomStringConvertible {
        case invalid(String)
        var description: String { if case .invalid(let message) = self { return message } else { return "" } }
    }

    /// Only `id` and `name` are required; everything else has a default.
    init(id: String, name: String, version: String = "1.0", description: String = "", author: String = "",
         main: String = "main.js", permissions: [String] = []) {
        self.id = id; self.name = name; self.version = version; self.description = description
        self.author = author; self.main = main; self.permissions = permissions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        main = try c.decodeIfPresent(String.self, forKey: .main) ?? "main.js"
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
    }

    /// Every rule a manifest has to follow; a bad one never gets as far as running code.
    static func parse(_ data: Data) throws -> PluginManifest {
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) }
        catch { throw ManifestError.invalid("plugin.json: \(error.localizedDescription)") }

        guard (3...80).contains(manifest.id.count),
              manifest.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
            throw ManifestError.invalid("id must be 3-80 characters: letters, digits, - _ .")
        }
        guard !manifest.name.isEmpty, manifest.name.count <= 60 else { throw ManifestError.invalid("name is required (max 60 characters)") }
        // The script must live inside the plugin folder.
        guard !manifest.main.isEmpty, !manifest.main.hasPrefix("/"), !manifest.main.contains(".."), manifest.main.hasSuffix(".js") else {
            throw ManifestError.invalid("main must be a relative .js file inside the plugin folder")
        }
        for name in manifest.permissions where PluginPermission(rawValue: name) == nil {
            throw ManifestError.invalid("unknown permission \"\(name)\"")
        }
        return manifest
    }

    var permissionSet: Set<PluginPermission> { Set(permissions.compactMap(PluginPermission.init(rawValue:))) }
}

/// Remembers which plugins the user trusted. Trust is tied to a digest of the plugin's files, so changing the
/// code of a plugin that holds permissions asks again.
struct PluginTrust {
    enum Decision: String { case allowed, denied }

    private let defaults: UserDefaults
    private let key = "pluginTrust"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func digest(manifest: Data, script: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: manifest)
        hasher.update(data: Data([0]))
        hasher.update(data: script)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func decision(id: String, digest: String) -> Decision? {
        guard let entry = (defaults.dictionary(forKey: key) as? [String: [String: String]])?[id], entry["digest"] == digest else { return nil }
        return Decision(rawValue: entry["decision"] ?? "")
    }

    func record(id: String, digest: String, _ decision: Decision) {
        var all = (defaults.dictionary(forKey: key) as? [String: [String: String]]) ?? [:]
        all[id] = ["digest": digest, "decision": decision.rawValue]
        defaults.set(all, forKey: key)
    }

    func forget(id: String) {
        var all = (defaults.dictionary(forKey: key) as? [String: [String: String]]) ?? [:]
        all[id] = nil
        defaults.set(all, forKey: key)
    }
}

/// At most `limit` events per `window` seconds; the rest are dropped.
struct RateLimiter {
    let limit: Int
    let window: TimeInterval
    private var stamps: [Date] = []

    init(limit: Int, window: TimeInterval) { self.limit = limit; self.window = window }

    mutating func allow(now: Date = Date()) -> Bool {
        stamps.removeAll { now.timeIntervalSince($0) > window }
        guard stamps.count < limit else { return false }
        stamps.append(now)
        return true
    }
}

/// Tiny per-plugin key/value store, kept as a JSON file in Application Support.
final class PluginStorage {
    static let maxBytes = 64 * 1024

    private let url: URL
    private var values: [String: String] = [:]   // JSON text per key

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([String: String].self, from: data) { values = stored }
    }

    func get(_ key: String) -> String? { values[key] }

    /// Returns false when the store would grow beyond the limit.
    @discardableResult
    func set(_ key: String, json: String?) -> Bool {
        var copy = values
        copy[key] = json
        guard let data = try? JSONEncoder().encode(copy), data.count <= Self.maxBytes else { return false }
        values = copy
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        return true
    }
}

/// What the settings window shows for each plugin.
struct PluginStatus: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case disabled
        case needsApproval
        case denied
        case failed(String)
    }

    var id: String
    var name: String
    var version: String
    var description: String
    var permissions: [PluginPermission]
    var state: State
    var directory: URL
    var log: [String] = []
    var lastError: String?
}
