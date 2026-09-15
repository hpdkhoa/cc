import Foundation

/// `library.json`: the list of games. Written atomically, ISO-8601 dates, sorted keys.
public enum LibraryStore {
    public static func load(from url: URL = Paths.library) throws -> [Game] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryFile.self, from: data).games
    }

    public static func save(_ games: [Game], to url: URL = Paths.library) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(LibraryFile(version: 1, games: games))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    struct LibraryFile: Codable {
        var version: Int
        var games: [Game]
    }
}

/// `settings.json`: small app-wide preferences.
public struct Settings: Codable, Hashable, Sendable {
    public var defaultRunnerID: String?

    public init(defaultRunnerID: String? = nil) { self.defaultRunnerID = defaultRunnerID }

    public static func load(from url: URL = Paths.settings) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save(to url: URL = Paths.settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
