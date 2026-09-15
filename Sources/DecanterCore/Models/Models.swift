import Foundation

// MARK: - Runners

/// Which Gcenx build line a runner comes from. Raw value matches the asset prefix
/// (`wine-stable-<tag>-osx64.tar.xz`).
public enum RunnerKind: String, Codable, CaseIterable, Hashable, Sendable {
    case stable  = "wine-stable"
    case staging = "wine-staging"
    case devel   = "wine-devel"

    public var displayName: String {
        switch self {
        case .stable:  return "Wine Stable"
        case .staging: return "Wine Staging"
        case .devel:   return "Wine Devel"
        }
    }
}

/// Where an installed runner came from.
public enum RunnerSource: String, Codable, Hashable, Sendable {
    case bundled   // Vendor/runners in the source checkout (offline install)
    case github    // downloaded from Gcenx releases
    case local     // user-supplied .tar.xz
    case unknown   // found on disk without metadata
}

/// An installed Wine runner: `runners/<id>/<Wine Stable.app>`.
public struct Runner: Codable, Identifiable, Hashable, Sendable {
    public var id: String { Runner.makeID(kind: kind, version: version) }
    public var kind: RunnerKind
    /// Gcenx release tag, e.g. "11.0_1".
    public var version: String
    public var appPath: URL
    public var source: RunnerSource
    public var installedAt: Date
    public var sha256: String?

    public init(kind: RunnerKind, version: String, appPath: URL, source: RunnerSource = .unknown,
                installedAt: Date = Date(), sha256: String? = nil) {
        self.kind = kind
        self.version = version
        self.appPath = appPath
        self.source = source
        self.installedAt = installedAt
        self.sha256 = sha256
    }

    public static func makeID(kind: RunnerKind, version: String) -> String { "\(kind.rawValue)-\(version)" }

    public var displayName: String { "\(kind.displayName) \(version)" }
    public var directory: URL { appPath.deletingLastPathComponent() }
    public var binDir: URL { appPath.appendingPathComponent("Contents/Resources/wine/bin", isDirectory: true) }
    public var wine: URL { binDir.appendingPathComponent("wine") }
    public var wineserver: URL { binDir.appendingPathComponent("wineserver") }
    public var wineVersion: WineVersion { WineVersion(version) }
}

/// Parsed Gcenx tag ("11.0_1" -> [11, 0, 1]) so runners sort numerically.
public struct WineVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
        self.components = raw.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { Int($0.filter { $0.isNumber }) ?? 0 }
    }

    public var description: String { raw }

    public static func < (lhs: WineVersion, rhs: WineVersion) -> Bool {
        let n = max(lhs.components.count, rhs.components.count)
        for i in 0..<n {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }
}

/// A downloadable runner from the Gcenx GitHub releases feed.
public struct RunnerRelease: Identifiable, Hashable, Sendable {
    public var id: String { Runner.makeID(kind: kind, version: version) }
    public var kind: RunnerKind
    public var version: String
    public var assetName: String
    public var downloadURL: URL
    public var size: Int64
    public var publishedAt: Date?
    public var prerelease: Bool

    public init(kind: RunnerKind, version: String, assetName: String, downloadURL: URL,
                size: Int64, publishedAt: Date?, prerelease: Bool) {
        self.kind = kind; self.version = version; self.assetName = assetName
        self.downloadURL = downloadURL; self.size = size; self.publishedAt = publishedAt
        self.prerelease = prerelease
    }
}

// MARK: - Vendored (offline) install manifest: Vendor/runners/manifest.json

public struct BundledManifest: Codable, Hashable, Sendable {
    public var runners: [BundledRunner]
    public var winetricks: BundledFile?
}

/// A runner tarball vendored in the repo, split into parts so each file stays
/// under GitHub's 100 MB limit. Parts are concatenated in order and must hash to `sha256`.
public struct BundledRunner: Codable, Identifiable, Hashable, Sendable {
    public var id: String { Runner.makeID(kind: kind, version: version) }
    public var kind: RunnerKind
    public var version: String
    public var asset: String
    public var sha256: String
    public var size: Int64
    public var parts: [String]
    public var sourceURL: String?

    enum CodingKeys: String, CodingKey {
        case kind, version, asset, sha256, size, parts
        case sourceURL = "source_url"
    }
}

public struct BundledFile: Codable, Hashable, Sendable {
    public var file: String
    public var sha256: String
    public var version: String?
    public var sourceURL: String?

    enum CodingKeys: String, CodingKey {
        case file, sha256, version
        case sourceURL = "source_url"
    }
}

// MARK: - Prefixes

public enum WindowsVersion: String, Codable, CaseIterable, Hashable, Sendable {
    case winxp, win7, win8, win81, win10, win11

    public var displayName: String {
        switch self {
        case .winxp: return "Windows XP"
        case .win7:  return "Windows 7"
        case .win8:  return "Windows 8"
        case .win81: return "Windows 8.1"
        case .win10: return "Windows 10"
        case .win11: return "Windows 11"
        }
    }
}

/// `prefixes/<name>/` plus the `prefix.json` metadata Decanter writes next to `drive_c`.
public struct WinePrefix: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var runnerID: String
    public var arch: String
    public var windowsVersion: WindowsVersion
    public var createdAt: Date

    public init(name: String, runnerID: String, arch: String = "win64",
                windowsVersion: WindowsVersion = .win7, createdAt: Date = Date()) {
        self.name = name; self.runnerID = runnerID; self.arch = arch
        self.windowsVersion = windowsVersion; self.createdAt = createdAt
    }

    public var url: URL { Paths.prefixes.appendingPathComponent(name, isDirectory: true) }
    public var driveC: URL { url.appendingPathComponent("drive_c", isDirectory: true) }
}

// MARK: - Library

public struct Game: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var prefixName: String
    public var runnerID: String
    /// Relative to the prefix ("drive_c/Program Files/x/y.exe") or an absolute path.
    public var exePath: String
    public var args: [String]
    public var env: [String: String]
    public var lastPlayed: Date?
    public var playtimeSeconds: Int
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, prefixName: String, runnerID: String, exePath: String,
                args: [String] = [], env: [String: String] = [:], lastPlayed: Date? = nil,
                playtimeSeconds: Int = 0, addedAt: Date = Date()) {
        self.id = id; self.name = name; self.prefixName = prefixName; self.runnerID = runnerID
        self.exePath = exePath; self.args = args; self.env = env; self.lastPlayed = lastPlayed
        self.playtimeSeconds = playtimeSeconds; self.addedAt = addedAt
    }

    /// Absolute path of the executable given the prefix it lives in.
    public func resolvedExe(in prefix: WinePrefix) -> URL {
        if exePath.hasPrefix("/") { return URL(fileURLWithPath: exePath) }
        return prefix.url.appendingPathComponent(exePath)
    }

    /// Stores `absolute` relative to the prefix when it is inside it, absolute otherwise.
    public static func storedExePath(for absolute: URL, in prefix: WinePrefix) -> String {
        let base = prefix.url.standardizedFileURL.path
        let full = absolute.standardizedFileURL.path
        if full.hasPrefix(base + "/") { return String(full.dropFirst(base.count + 1)) }
        return full
    }
}
