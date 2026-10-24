import Foundation

struct TranslationCredentials: Codable, Equatable {
    var model: String
    var baidu: String
}

/// Local file storage for development and installed apps; never uses Keychain.
/// An existing file is authoritative, including empty keys.
struct ProjectCredentials {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("credentials.json") }

    func load() throws -> TranslationCredentials {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Surface unreadable/corrupt data rather than silently replacing saved keys.
            return try JSONDecoder().decode(TranslationCredentials.self, from: Data(contentsOf: fileURL))
        }
        return TranslationCredentials(model: "", baidu: "")
    }

    func save(_ credentials: TranslationCredentials) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // The private directory also protects the temporary file used for atomic replacement.
        try encoder.encode(credentials).write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
