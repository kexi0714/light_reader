import Foundation
@testable import LightReaderKit

final class SettingsTests {
    func testStorageLocations() throws {
        let support = URL(fileURLWithPath: "/Users/example/Library/Application Support", isDirectory: true)
        let project = URL(fileURLWithPath: "/Users/example/Projects/light_reader", isDirectory: true)
        let cwd = URL(fileURLWithPath: "/Volumes/Light Reader", isDirectory: true)
        let installed = LocalStorage.resolveDirectory(projectRoot: nil, isAppBundle: true,
            applicationSupport: support, workingDirectory: cwd)
        expectEqual(installed.path, support.appendingPathComponent("Light Reader").path)
        expectEqual(LocalStorage.resolveDirectory(projectRoot: nil, isAppBundle: true,
            applicationSupport: support, workingDirectory: project), installed)
        expectEqual(LocalStorage.resolveDirectory(projectRoot: project.path, isAppBundle: true,
            applicationSupport: support, workingDirectory: cwd).path,
            project.appendingPathComponent(".local").path)
        expectEqual(LocalStorage.resolveDirectory(projectRoot: nil, isAppBundle: false,
            applicationSupport: support, workingDirectory: project).path,
            project.appendingPathComponent(".local").path)
    }

    func testSettingsMigrationAndFutureVersionProtection() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/migration-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = SettingsFile(directory: directory)
        let legacy = Data(#"{"provider":"model","endpoint":"https://example.com/v1","model":"test-model"}"#.utf8)
        try legacy.write(to: file.fileURL)
        var loaded = try file.load()
        expectEqual(loaded.provider, .model)
        expectEqual(loaded.model, "test-model")
        expectEqual(loaded.baiduAppID, "")
        // Reading an old format is non-destructive; migration occurs on save.
        try expectEqual(Data(contentsOf: file.fileURL), legacy)
        loaded.baiduAppID = "test-app-id"
        try file.save(loaded)
        try expectEqual(file.load(), loaded)
        try expectEqual(Data(contentsOf: file.backupURL), legacy)
        let saved = try Data(contentsOf: file.fileURL)
        let object = try require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        expectEqual(object["schemaVersion"] as? Int, StoredSettings.currentVersion)
        // Flat fields remain readable through the original configuration type.
        try expectEqual(JSONDecoder().decode(TranslationConfiguration.self, from: saved), loaded)
        let future = Data(#"{"schemaVersion":999,"provider":"baidu"}"#.utf8)
        try future.write(to: file.fileURL)
        expectThrows(try file.load())
        expectThrows(try file.save(loaded))
        try expectEqual(Data(contentsOf: file.fileURL), future)
        try expectEqual(Data(contentsOf: file.backupURL), legacy)
        let corrupt = Data("invalid JSON".utf8)
        try corrupt.write(to: file.fileURL)
        expectThrows(try file.save(loaded))
        try expectEqual(Data(contentsOf: file.fileURL), corrupt)
    }

    func testPersistenceAndPermissions() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/settings-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectCredentials(directory: directory)
        try expectEqual(store.load(), TranslationCredentials(model: "", baidu: ""))
        let initial = TranslationCredentials(model: "fake-model", baidu: "fake-baidu")
        try store.save(initial)
        try expectEqual(store.load(), initial)
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        expectEqual(fileMode?.intValue, 0o600)
        expectEqual(directoryMode?.intValue, 0o700)
        let changed = TranslationCredentials(model: "", baidu: "updated-fake-baidu")
        try store.save(changed)
        let reloaded = try ProjectCredentials(directory: directory).load()
        expectEqual(reloaded, changed)
        try Data("invalid JSON".utf8).write(to: store.fileURL)
        expectThrows(try store.load())
    }
}
