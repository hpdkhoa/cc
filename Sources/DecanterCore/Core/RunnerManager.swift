import Foundation

public struct InstallProgress: Sendable, Equatable {
    public var phase: String
    public var fraction: Double?   // nil = indeterminate
    public init(_ phase: String, fraction: Double? = nil) { self.phase = phase; self.fraction = fraction }
}

public enum RunnerError: Error, LocalizedError, Sendable {
    case alreadyInstalled(String)
    case noAppInArchive(URL)
    case wineBinaryMissing(URL)
    case checksumMismatch(expected: String, actual: String)
    case bundledPartMissing(String)
    case noVendorDir
    case badAssetName(String)
    case notInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyInstalled(let id): return "Runner \(id) is already installed."
        case .noAppInArchive(let url): return "No Wine .app found inside \(url.lastPathComponent)."
        case .wineBinaryMissing(let url): return "\(url.path) has no Contents/Resources/wine/bin/wine."
        case .checksumMismatch(let e, let a): return "SHA-256 mismatch.\nexpected \(e)\nactual   \(a)"
        case .bundledPartMissing(let p): return "Vendored file missing: \(p)"
        case .noVendorDir: return "No Vendor/ directory found (set DECANTER_VENDOR_DIR or run from the source checkout)."
        case .badAssetName(let n): return "Unrecognised runner archive name: \(n)"
        case .notInstalled(let id): return "Runner \(id) is not installed."
        }
    }
}

/// Lists, installs (from GitHub, from the vendored offline copy, or from a local
/// .tar.xz), verifies and deletes Wine runners under `runners/`.
public actor RunnerManager {
    public static let releasesURL = URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases?per_page=30")!
    static let metadataFile = "runner.json"

    private let fm = FileManager.default

    public init() {}

    // MARK: Installed runners

    public func installed() -> [Runner] {
        guard let entries = try? fm.contentsOfDirectory(at: Paths.runners, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var runners: [Runner] = []
        for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if dir.lastPathComponent.hasPrefix(".") { continue }
            if let r = readMetadata(in: dir) {
                runners.append(r)
            } else if let r = detect(in: dir) {
                runners.append(r)
            }
        }
        return runners.sorted { ($0.kind == .stable ? 0 : 1, $1.wineVersion) < ($1.kind == .stable ? 0 : 1, $0.wineVersion) }
    }

    public func runner(id: String) -> Runner? { installed().first { $0.id == id } }

    public func defaultRunner() -> Runner? {
        let all = installed()
        if let id = Settings.load().defaultRunnerID, let r = all.first(where: { $0.id == id }) { return r }
        return all.first
    }

    public func setDefault(_ runner: Runner) throws {
        var s = Settings.load()
        s.defaultRunnerID = runner.id
        try s.save()
        Log.shared.info("runners", "default runner: \(runner.id)")
    }

    public func delete(_ runner: Runner) throws {
        try fm.removeItem(at: runner.directory)
        Log.shared.info("runners", "deleted \(runner.id) (\(runner.directory.path))")
    }

    /// True when the runner's wine binary exists and is executable.
    public func verify(_ runner: Runner) -> Bool {
        fm.isExecutableFile(atPath: runner.wine.path) && fm.isExecutableFile(atPath: runner.wineserver.path)
    }

    private func readMetadata(in dir: URL) -> Runner? {
        let url = dir.appendingPathComponent(Self.metadataFile)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var r = try? decoder.decode(Runner.self, from: data) else { return nil }
        // Data dir may have moved; trust the on-disk location over the stored one.
        if let app = findApp(in: dir) { r.appPath = app }
        return r
    }

    /// A runner directory without runner.json (e.g. unpacked by hand). Name must be `<kind>-<version>`.
    private func detect(in dir: URL) -> Runner? {
        guard let app = findApp(in: dir) else { return nil }
        let name = dir.lastPathComponent
        for kind in RunnerKind.allCases where name.hasPrefix(kind.rawValue + "-") {
            let version = String(name.dropFirst(kind.rawValue.count + 1))
            return Runner(kind: kind, version: version, appPath: app, source: .unknown,
                          installedAt: (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date())
        }
        return Runner(kind: .stable, version: name, appPath: app, source: .unknown)
    }

    private func findApp(in dir: URL) -> URL? {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for item in items where item.pathExtension == "app" {
            let wine = item.appendingPathComponent("Contents/Resources/wine/bin/wine")
            if fm.fileExists(atPath: wine.path) { return item }
        }
        // one level deeper (archive with a wrapper folder)
        for sub in items where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && sub.pathExtension != "app" {
            if let items2 = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) {
                for item in items2 where item.pathExtension == "app" {
                    if fm.fileExists(atPath: item.appendingPathComponent("Contents/Resources/wine/bin/wine").path) { return item }
                }
            }
        }
        return nil
    }

    private func writeMetadata(_ runner: Runner) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(runner).write(to: runner.directory.appendingPathComponent(Self.metadataFile), options: .atomic)
    }

    // MARK: GitHub releases (online)

    public func fetchReleases() async throws -> [RunnerRelease] {
        Log.shared.info("runners", "fetching release list from GitHub")
        let data = try await Downloader.fetchData(Self.releasesURL, accept: "application/vnd.github+json")
        let releases = try Self.parseReleases(data)
        Log.shared.info("runners", "\(releases.count) downloadable runners")
        return releases
    }

    /// Download the asset to `cache/` (reusing a previous download of the same asset) and install it.
    public func install(release: RunnerRelease, progress: @escaping @Sendable (InstallProgress) -> Void) async throws -> Runner {
        let id = release.id
        if installed().contains(where: { $0.id == id }) { throw RunnerError.alreadyInstalled(id) }
        let archive = Paths.cache.appendingPathComponent(release.assetName)
        let existingSize = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? -1
        if existingSize != release.size {
            try fm.createDirectory(at: Paths.cache, withIntermediateDirectories: true)
            progress(InstallProgress("Downloading \(release.assetName)", fraction: 0))
            try await Downloader.download(release.downloadURL, to: archive) { p in
                progress(InstallProgress("Downloading \(release.assetName)", fraction: p.fraction))
            }
        } else {
            Log.shared.info("runners", "reusing cached \(release.assetName)")
        }
        return try await install(archive: archive, kind: release.kind, version: release.version,
                                 source: .github, expectedSHA256: nil, progress: progress)
    }

    // MARK: Vendored runners (offline)

    public func bundledManifest() throws -> (dir: URL, manifest: BundledManifest) {
        guard let vendor = Paths.vendorDir else { throw RunnerError.noVendorDir }
        let data = try Data(contentsOf: vendor.appendingPathComponent("runners/manifest.json"))
        return (vendor, try JSONDecoder().decode(BundledManifest.self, from: data))
    }

    public func bundledRunners() -> [BundledRunner] {
        (try? bundledManifest().manifest.runners) ?? []
    }

    /// Reassemble the split tarball into `cache/`, check its SHA-256, then install.
    public func installBundled(_ bundled: BundledRunner, progress: @escaping @Sendable (InstallProgress) -> Void) async throws -> Runner {
        if installed().contains(where: { $0.id == bundled.id }) { throw RunnerError.alreadyInstalled(bundled.id) }
        let (vendor, _) = try bundledManifest()
        let partsDir = vendor.appendingPathComponent("runners", isDirectory: true)
        let archive = Paths.cache.appendingPathComponent(bundled.asset)
        try fm.createDirectory(at: Paths.cache, withIntermediateDirectories: true)

        var reuse = false
        if let size = try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int64, size == bundled.size {
            progress(InstallProgress("Verifying cached \(bundled.asset)"))
            reuse = (try? SHA256Digest.hex(ofFile: archive)) == bundled.sha256
        }
        if !reuse {
            progress(InstallProgress("Assembling \(bundled.asset)", fraction: 0))
            try Self.join(parts: bundled.parts.map { partsDir.appendingPathComponent($0) }, into: archive) { done in
                progress(InstallProgress("Assembling \(bundled.asset)", fraction: Double(done) / Double(max(bundled.size, 1))))
            }
        }
        return try await install(archive: archive, kind: bundled.kind, version: bundled.version, source: .bundled,
                                 expectedSHA256: reuse ? nil : bundled.sha256, progress: progress)
    }

    /// Concatenate `parts` into `destination` (streamed, 4 MiB at a time).
    public static func join(parts: [URL], into destination: URL, progress: ((Int64) -> Void)? = nil) throws {
        let fm = FileManager.default
        for p in parts where !fm.fileExists(atPath: p.path) { throw RunnerError.bundledPartMissing(p.path) }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var total: Int64 = 0
        for part in parts {
            Log.shared.info("runners", "joining \(part.lastPathComponent)")
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while true {
                let chunk = try input.read(upToCount: 4 << 20) ?? Data()
                if chunk.isEmpty { break }
                try out.write(contentsOf: chunk)
                total += Int64(chunk.count)
                progress?(total)
            }
        }
    }

    // MARK: Local archive

    /// Install from any `wine-<kind>-<version>-osx64.tar.xz`. `kind`/`version` default to
    /// values parsed from the file name.
    public func install(archive: URL, kind: RunnerKind? = nil, version: String? = nil, source: RunnerSource = .local,
                        expectedSHA256: String? = nil,
                        progress: @escaping @Sendable (InstallProgress) -> Void) async throws -> Runner {
        let parsed = Self.parseAssetName(archive.lastPathComponent)
        guard let kind = kind ?? parsed?.kind, let version = version ?? parsed?.version else {
            throw RunnerError.badAssetName(archive.lastPathComponent)
        }
        let id = Runner.makeID(kind: kind, version: version)
        let dest = Paths.runners.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { throw RunnerError.alreadyInstalled(id) }
        try fm.createDirectory(at: Paths.runners, withIntermediateDirectories: true)

        var sha = expectedSHA256
        if let expected = expectedSHA256 {
            progress(InstallProgress("Verifying \(archive.lastPathComponent)", fraction: 0))
            let size = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
            let actual = try SHA256Digest.hex(ofFile: archive) { done in
                progress(InstallProgress("Verifying \(archive.lastPathComponent)", fraction: size > 0 ? Double(done) / Double(size) : nil))
            }
            guard actual == expected else { throw RunnerError.checksumMismatch(expected: expected, actual: actual) }
            Log.shared.info("runners", "sha256 OK \(actual)")
        } else {
            sha = try? SHA256Digest.hex(ofFile: archive)
        }

        let tmp = Paths.runners.appendingPathComponent(".tmp-\(id)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        progress(InstallProgress("Unpacking \(archive.lastPathComponent)"))
        try await WineProcess.run(CommandSpec(path: "/usr/bin/tar", arguments: ["-xf", archive.path, "-C", tmp.path], label: "tar"))

        guard let app = findApp(in: tmp) else { throw RunnerError.noAppInArchive(archive) }
        let wineBin = app.appendingPathComponent("Contents/Resources/wine/bin/wine")
        guard fm.fileExists(atPath: wineBin.path) else { throw RunnerError.wineBinaryMissing(app) }

        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let finalApp = dest.appendingPathComponent(app.lastPathComponent)
        try fm.moveItem(at: app, to: finalApp)

        #if os(macOS)
        progress(InstallProgress("Removing quarantine"))
        // Unsigned personal build: strip Gatekeeper quarantine so the binaries can run.
        try await WineProcess.run(CommandSpec(path: "/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", finalApp.path], label: "xattr"), check: false)
        #endif

        let runner = Runner(kind: kind, version: version, appPath: finalApp, source: source, installedAt: Date(), sha256: sha)
        try writeMetadata(runner)
        Log.shared.info("runners", "installed \(runner.id) at \(finalApp.path)")
        progress(InstallProgress("Installed \(runner.displayName)", fraction: 1))
        return runner
    }

    // MARK: Parsing (pure, testable)

    /// "wine-stable-11.0_1-osx64.tar.xz" -> (.stable, "11.0_1")
    public static func parseAssetName(_ name: String) -> (kind: RunnerKind, version: String)? {
        let suffixes = ["-osx64.tar.xz", "-osx64.tar.gz"]
        guard let suffix = suffixes.first(where: { name.hasSuffix($0) }) else { return nil }
        let stem = String(name.dropLast(suffix.count))
        for kind in RunnerKind.allCases where stem.hasPrefix(kind.rawValue + "-") {
            let version = String(stem.dropFirst(kind.rawValue.count + 1))
            return version.isEmpty ? nil : (kind, version)
        }
        return nil
    }

    /// Parse the GitHub releases JSON into runner assets, newest first.
    public static func parseReleases(_ data: Data) throws -> [RunnerRelease] {
        struct GHAsset: Decodable { let name: String; let size: Int64; let browser_download_url: String }
        struct GHRelease: Decodable {
            let tag_name: String; let prerelease: Bool; let published_at: String?; let assets: [GHAsset]
        }
        let releases = try JSONDecoder().decode([GHRelease].self, from: data)
        let iso = ISO8601DateFormatter()
        var out: [RunnerRelease] = []
        for r in releases {
            for a in r.assets {
                guard let parsed = parseAssetName(a.name), let url = URL(string: a.browser_download_url) else { continue }
                out.append(RunnerRelease(kind: parsed.kind, version: parsed.version, assetName: a.name, downloadURL: url,
                                         size: a.size, publishedAt: r.published_at.flatMap { iso.date(from: $0) },
                                         prerelease: r.prerelease))
            }
        }
        return out.sorted { a, b in
            if a.wineVersionValue != b.wineVersionValue { return a.wineVersionValue > b.wineVersionValue }
            return a.kind.rawValue < b.kind.rawValue
        }
    }
}

extension RunnerRelease {
    var wineVersionValue: WineVersion { WineVersion(version) }
}
