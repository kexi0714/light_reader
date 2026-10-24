import AppKit
import SwiftUI

public enum LocalStorage {
    public static var directory: URL {
        resolveDirectory(
            projectRoot: Bundle.main.object(forInfoDictionaryKey: "LightReaderProjectRoot") as? String,
            isAppBundle: Bundle.main.bundleURL.pathExtension == "app",
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
    }

    static func resolveDirectory(projectRoot: String?, isAppBundle: Bool,
                                 applicationSupport: URL, workingDirectory: URL) -> URL {
        if let projectRoot, !projectRoot.isEmpty {
            return URL(fileURLWithPath: projectRoot).appendingPathComponent(".local", isDirectory: true)
        }
        if isAppBundle {
            return applicationSupport.appendingPathComponent("Light Reader", isDirectory: true)
        }
        // Command-line development runs keep data inside the checkout.
        return workingDirectory.appendingPathComponent(".local", isDirectory: true)
    }
    static func write<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    static func read<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    @Published private(set) var configuration: TranslationConfiguration
    private let settings = SettingsFile(directory: LocalStorage.directory)
    private let credentials = ProjectCredentials(directory: LocalStorage.directory)
    private let loadError: Error?
    private init() {
        do {
            configuration = try settings.load()
            loadError = nil
        } catch {
            configuration = .init()
            loadError = error
        }
    }
    func secret(for provider: TranslationProvider) throws -> String {
        if let loadError { throw loadError }
        let saved = try credentials.load()
        return provider == .model ? saved.model : saved.baidu
    }
    func save(_ configuration: TranslationConfiguration, modelSecret: String, baiduSecret: String) throws {
        if let loadError { throw loadError }
        _ = try settings.load()
        try credentials.save(.init(model: modelSecret.trimmingCharacters(in: .whitespacesAndNewlines),
                                   baidu: baiduSecret.trimmingCharacters(in: .whitespacesAndNewlines)))
        try settings.save(configuration)
        self.configuration = configuration
    }
}

struct ReadingPosition: Codable {
    var page: Int
    var scale: CGFloat
    var autoScale: Bool
}

final class ReadingHistory {
    static let shared = ReadingHistory()
    private var entries: [String: ReadingPosition] = LocalStorage.read([String: ReadingPosition].self, name: "reading-positions.json") ?? [:]
    func position(for url: URL?) -> ReadingPosition? { url.flatMap { entries[$0.standardizedFileURL.path] } }
    func save(_ position: ReadingPosition, for url: URL?) {
        guard let url else { return }
        entries[url.standardizedFileURL.path] = position
        try? LocalStorage.write(entries, name: "reading-positions.json")
    }
}
