import Foundation

enum Paths {
    static let dataDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Decanter")
    static let runners  = dataDir.appendingPathComponent("runners")
    static let prefixes = dataDir.appendingPathComponent("prefixes")
    static let recipes  = dataDir.appendingPathComponent("recipes")
    static let cache    = dataDir.appendingPathComponent("cache")
    static let library  = dataDir.appendingPathComponent("library.json")

    static func bootstrap() throws {
        for dir in [runners, prefixes, recipes, cache] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
