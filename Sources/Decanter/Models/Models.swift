import Foundation

struct Runner: Codable, Identifiable, Hashable {
    var id: String { version }
    var version: String
    var kind: String            // wine-stable | wine-staging | wine-devel
    var appPath: URL            // .../Wine Stable.app
    var wine: URL { appPath.appendingPathComponent("Contents/Resources/wine/bin/wine") }
    var wineserver: URL { appPath.appendingPathComponent("Contents/Resources/wine/bin/wineserver") }
}

struct Game: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var prefixName: String
    var runnerVersion: String
    var exePath: String         // relative to prefix, e.g. "drive_c/Program Files/x/y.exe"
    var args: [String] = []
    var env: [String: String] = [:]
    var lastPlayed: Date?
    var playtimeSeconds = 0
}
