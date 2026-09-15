import Foundation

public enum PrefixError: Error, LocalizedError, Sendable {
    case invalidName(String)
    case alreadyExists(String)
    case notFound(String)
    case winetricksUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let n): return "\"\(n)\" is not a valid prefix name (letters, digits, space, . _ - only)."
        case .alreadyExists(let n): return "A prefix named \"\(n)\" already exists."
        case .notFound(let n): return "Prefix \"\(n)\" does not exist."
        case .winetricksUnavailable(let why): return "winetricks is not available: \(why)"
        }
    }
}

/// One key in a .reg import.
public struct RegistryEntry: Hashable, Sendable {
    public enum Value: Hashable, Sendable {
        case string(String)
        case dword(UInt32)
    }
    public var key: String              // e.g. HKEY_CLASSES_ROOT\gamename\shell\open\command
    public var values: [String: Value]  // "" is the default value (@)

    public init(key: String, values: [String: Value]) { self.key = key; self.values = values }
    public init(key: String, strings: [String: String]) {
        self.key = key
        self.values = strings.mapValues { .string($0) }
    }
}

/// GUI tools that can be opened inside a prefix from the UI.
public enum WineTool: String, CaseIterable, Sendable {
    case winecfg, regedit, explorer, taskmgr, control
    public var displayName: String {
        switch self {
        case .winecfg: return "Wine Configuration"
        case .regedit: return "Registry Editor"
        case .explorer: return "Explorer"
        case .taskmgr: return "Task Manager"
        case .control: return "Control Panel"
        }
    }
}

/// Creates and mutates Wine prefixes under `prefixes/`.
public actor PrefixManager {
    static let metadataFile = "prefix.json"
    public static let winetricksURL = URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks")!

    private let fm = FileManager.default

    public init() {}

    // MARK: Listing

    public func list() -> [WinePrefix] {
        guard let entries = try? fm.contentsOfDirectory(at: Paths.prefixes, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [WinePrefix] = []
        for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if dir.lastPathComponent.hasPrefix(".") { continue }
            if let p = readMetadata(in: dir) {
                out.append(p)
            } else if fm.fileExists(atPath: dir.appendingPathComponent("drive_c").path) {
                out.append(WinePrefix(name: dir.lastPathComponent, runnerID: "", arch: "win64", windowsVersion: .win7,
                                      createdAt: (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func prefix(named name: String) -> WinePrefix? { list().first { $0.name == name } }

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, !name.hasPrefix("."), name != "..",
              name.trimmingCharacters(in: .whitespaces) == name else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || " ._-".contains($0) }
    }

    private func readMetadata(in dir: URL) -> WinePrefix? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.metadataFile)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var p = try? decoder.decode(WinePrefix.self, from: data) else { return nil }
        p.name = dir.lastPathComponent
        return p
    }

    private func writeMetadata(_ prefix: WinePrefix) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(prefix).write(to: prefix.url.appendingPathComponent(Self.metadataFile), options: .atomic)
    }

    // MARK: Create / destroy

    /// `wineboot -u` into a fresh directory, then set the Windows version.
    public func create(name: String, runner: Runner, windowsVersion: WindowsVersion = .win7) async throws -> WinePrefix {
        guard Self.isValidName(name) else { throw PrefixError.invalidName(name) }
        let prefix = WinePrefix(name: name, runnerID: runner.id, arch: "win64", windowsVersion: windowsVersion)
        if fm.fileExists(atPath: prefix.url.path) { throw PrefixError.alreadyExists(name) }
        try fm.createDirectory(at: prefix.url, withIntermediateDirectories: true)
        Log.shared.info("prefix", "creating \(name) with \(runner.id)")
        do {
            try await WineProcess.run(WineProcess.wine(runner: runner, prefix: prefix.url, arguments: ["wineboot", "-u"], label: "wineboot"))
            try await WineProcess.run(WineProcess.wineserver(runner: runner, prefix: prefix.url, arguments: ["-w"]), check: false)
            try await setWindowsVersion(windowsVersion, prefix: prefix, runner: runner)
        } catch {
            try? fm.removeItem(at: prefix.url)
            throw error
        }
        try writeMetadata(prefix)
        Log.shared.info("prefix", "created \(prefix.url.path)")
        return prefix
    }

    /// Kills everything running in the prefix, then deletes the directory.
    public func destroy(_ prefix: WinePrefix, runner: Runner?) async throws {
        if let runner {
            _ = try? await WineProcess.run(WineProcess.wineserver(runner: runner, prefix: prefix.url, arguments: ["-k"]), check: false)
        }
        try fm.removeItem(at: prefix.url)
        Log.shared.info("prefix", "destroyed \(prefix.name)")
    }

    // MARK: Configuration

    public func setWindowsVersion(_ version: WindowsVersion, prefix: WinePrefix, runner: Runner) async throws {
        try await WineProcess.run(WineProcess.wine(runner: runner, prefix: prefix.url, arguments: ["winecfg", "/v", version.rawValue], label: "winecfg"))
        var updated = prefix
        updated.windowsVersion = version
        if fm.fileExists(atPath: prefix.url.appendingPathComponent(Self.metadataFile).path) { try writeMetadata(updated) }
    }

    /// `wine regedit /S file.reg`
    public func importRegistry(file: URL, prefix: WinePrefix, runner: Runner) async throws {
        try await WineProcess.run(WineProcess.wine(runner: runner, prefix: prefix.url, arguments: ["regedit", "/S", file.path], label: "regedit"))
        try await WineProcess.run(WineProcess.wineserver(runner: runner, prefix: prefix.url, arguments: ["-w"]), check: false)
    }

    /// Write the entries to a temporary .reg and import them.
    public func importRegistry(entries: [RegistryEntry], prefix: WinePrefix, runner: Runner) async throws {
        try fm.createDirectory(at: Paths.cache, withIntermediateDirectories: true)
        let file = Paths.cache.appendingPathComponent("decanter-\(UUID().uuidString.prefix(8)).reg")
        try Self.regFileText(entries).data(using: .utf8)!.write(to: file)
        defer { try? fm.removeItem(at: file) }
        Log.shared.info("regedit", "importing \(entries.count) key(s): " + entries.map(\.key).joined(separator: ", "))
        try await importRegistry(file: file, prefix: prefix, runner: runner)
    }

    /// Regedit 5.00 text (CRLF). Strings are escaped for the .reg format.
    public static func regFileText(_ entries: [RegistryEntry]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        var lines = ["Windows Registry Editor Version 5.00", ""]
        for e in entries {
            lines.append("[\(e.key)]")
            for name in e.values.keys.sorted() {
                let lhs = name.isEmpty ? "@" : "\"\(esc(name))\""
                switch e.values[name]! {
                case .string(let s): lines.append("\(lhs)=\"\(esc(s))\"")
                case .dword(let d): lines.append("\(lhs)=dword:" + String(format: "%08x", d))
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: winetricks

    /// `cache/winetricks`: copied from the vendored copy (checksum-verified) or downloaded.
    public func ensureWinetricks() async throws -> URL {
        let dest = Paths.cache.appendingPathComponent("winetricks")
        try fm.createDirectory(at: Paths.cache, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { return dest }

        if let vendor = Paths.vendorDir,
           let data = try? Data(contentsOf: vendor.appendingPathComponent("runners/manifest.json")),
           let manifest = try? JSONDecoder().decode(BundledManifest.self, from: data),
           let bundled = manifest.winetricks {
            let src = vendor.appendingPathComponent(bundled.file)
            if fm.fileExists(atPath: src.path) {
                let actual = try SHA256Digest.hex(ofFile: src)
                guard actual == bundled.sha256 else { throw RunnerError.checksumMismatch(expected: bundled.sha256, actual: actual) }
                try fm.copyItem(at: src, to: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                Log.shared.info("winetricks", "using vendored winetricks \(bundled.version ?? "")")
                return dest
            }
        }
        try await Downloader.download(Self.winetricksURL, to: dest) { _ in }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest
    }

    public func winetricks(verbs: [String], prefix: WinePrefix, runner: Runner) async throws {
        let verbs = verbs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !verbs.isEmpty else { return }
        let script = try await ensureWinetricks()
        try await WineProcess.run(WineProcess.winetricks(script: script, runner: runner, prefix: prefix.url, verbs: verbs))
    }

    // MARK: Tools

    /// Open a Wine GUI tool in the prefix; returns immediately.
    @discardableResult
    public func open(tool: WineTool, prefix: WinePrefix, runner: Runner) throws -> RunningProcess {
        try WineProcess.spawn(WineProcess.wine(runner: runner, prefix: prefix.url, arguments: [tool.rawValue], label: tool.rawValue))
    }
}
