import Foundation

/// All on-disk locations Decanter uses. Everything lives under the data dir
/// (`~/Library/Application Support/Decanter/`) unless the user picked a path.
public enum Paths {
    /// Override with `DECANTER_DATA_DIR=/some/dir` (used by tests and headless runs).
    public static let dataDir: URL = {
        if let override = ProcessInfo.processInfo.environment["DECANTER_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Decanter", isDirectory: true)
    }()

    public static let runners  = dataDir.appendingPathComponent("runners", isDirectory: true)
    public static let prefixes = dataDir.appendingPathComponent("prefixes", isDirectory: true)
    public static let recipes  = dataDir.appendingPathComponent("recipes", isDirectory: true)
    public static let cache    = dataDir.appendingPathComponent("cache", isDirectory: true)
    public static let library  = dataDir.appendingPathComponent("library.json")
    public static let settings = dataDir.appendingPathComponent("settings.json")

    /// Directory with the vendored offline-install files (`Vendor/` in the source checkout):
    /// the Wine runner tarball (split into <50 MB parts), winetricks, and the Yams package.
    /// Resolution order: `DECANTER_VENDOR_DIR`, the source tree this binary was built from,
    /// any ancestor of the executable, then the current working directory.
    public static var vendorDir: URL? {
        let fm = FileManager.default
        func isVendor(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent("runners/manifest.json").path)
        }
        if let override = ProcessInfo.processInfo.environment["DECANTER_VENDOR_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if isVendor(url) { return url }
        }
        // Sources/DecanterCore/Core/Paths.swift -> repo root
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fromSource = sourceRoot.appendingPathComponent("Vendor", isDirectory: true)
        if isVendor(fromSource) { return fromSource }

        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let d = dir else { break }
            let candidate = d.appendingPathComponent("Vendor", isDirectory: true)
            if isVendor(candidate) { return candidate }
            dir = d.deletingLastPathComponent()
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Vendor", isDirectory: true)
        if isVendor(cwd) { return cwd }
        return nil
    }

    /// Create the data directory tree. Safe to call repeatedly.
    public static func bootstrap() throws {
        for dir in [dataDir, runners, prefixes, recipes, cache] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
