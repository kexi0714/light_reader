import Foundation

/// The schema version is independent of the app's release/build version.
/// Keep fields flat so pre-versioned builds can still read compatible settings.
struct StoredSettings: Codable {
    static let currentVersion = 1
    let configuration: TranslationConfiguration
    private enum CodingKeys: String, CodingKey { case schemaVersion }

    init(configuration: TranslationConfiguration) { self.configuration = configuration }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard (0...Self.currentVersion).contains(version) else {
            throw SettingsFileError.unsupportedVersion(version)
        }
        // Version 0 is the original unversioned configuration. Its fields map
        // directly to version 1; new optional fields supply their own defaults.
        configuration = try TranslationConfiguration(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .schemaVersion)
        try configuration.encode(to: encoder)
    }
}

enum SettingsFileError: LocalizedError {
    case unsupportedVersion(Int)
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "此配置由更新版本的软件创建（格式版本 \(version)），请升级 Light Reader。原配置未被修改。"
        }
    }
}

struct SettingsFile {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("settings.json") }
    var backupURL: URL { directory.appendingPathComponent("settings.previous.json") }

    func load() throws -> TranslationConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .init() }
        return try JSONDecoder().decode(StoredSettings.self, from: Data(contentsOf: fileURL)).configuration
    }

    func save(_ configuration: TranslationConfiguration) throws {
        // Never replace corrupt settings or a schema this build cannot understand.
        _ = try load()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fm.fileExists(atPath: fileURL.path) {
            try Data(contentsOf: fileURL).write(to: backupURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(StoredSettings(configuration: configuration)).write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
