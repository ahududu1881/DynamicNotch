import Foundation

enum AboutInfo {
    static let name = "Dynamic Notch"

    /// The project's GitHub page, e.g. "https://github.com/<user>/DynamicNotch". The About page shows
    /// the repository, issue and license links only when this is set.
    static let repositoryURL = "https://github.com/ahududu1881/DynamicNotch"

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    static var issuesURL: URL? { URL(string: repositoryURL + "/issues") }
    static var repository: URL? { repositoryURL.isEmpty ? nil : URL(string: repositoryURL) }
}

/// Carries data over from the app's earlier name so nobody loses settings or plugins.
/// Runs once, before anything reads a setting.
enum LegacyMigration {
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromLegacyName") else { return }
        defaults.set(true, forKey: "migratedFromLegacyName")

        if let old = defaults.persistentDomain(forName: "com.lausiee.DynamicNotch") {
            for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldFolder = support.appendingPathComponent("LausieeDynamicNotch", isDirectory: true)
        let newFolder = support.appendingPathComponent("DynamicNotch", isDirectory: true)
        if FileManager.default.fileExists(atPath: oldFolder.path), !FileManager.default.fileExists(atPath: newFolder.path) {
            try? FileManager.default.moveItem(at: oldFolder, to: newFolder)
        }
    }
}
