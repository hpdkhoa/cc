import XCTest
@testable import DecanterCore

/// End-to-end checks against a fake `wine`/`wineserver` (shell scripts that record
/// their argv and mimic wineboot). They write under `DECANTER_DATA_DIR`, so they only
/// run when that variable points at a scratch directory:
///   DECANTER_DATA_DIR=/tmp/decanter-test swift test --filter IntegrationTests
final class IntegrationTests: XCTestCase {
    var fm: FileManager { .default }
    var scratch: URL!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["DECANTER_DATA_DIR"], !dir.isEmpty else {
            throw XCTSkip("set DECANTER_DATA_DIR to a scratch directory to run integration tests")
        }
        XCTAssertEqual(Paths.dataDir.path, URL(fileURLWithPath: dir, isDirectory: true).path)
        try? fm.removeItem(at: Paths.dataDir)
        try Paths.bootstrap()
        scratch = Paths.dataDir.appendingPathComponent("scratch", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    // MARK: Fake runner

    /// Builds `Wine Stable.app` with shell-script `wine` and `wineserver` that append their
    /// argv to `$WINEPREFIX/calls.log`; `wine wineboot` also creates drive_c.
    private func makeFakeApp(in dir: URL) throws -> URL {
        let app = dir.appendingPathComponent("Wine Stable.app", isDirectory: true)
        let bin = app.appendingPathComponent("Contents/Resources/wine/bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = """
        #!/bin/sh
        echo "wine $*" >> "$WINEPREFIX/calls.log"
        echo "fake wine: $*"
        case "$1" in
          wineboot) mkdir -p "$WINEPREFIX/drive_c/windows" ;;
          winecfg) echo "$3" > "$WINEPREFIX/winver" ;;
          regedit) cp "$3" "$WINEPREFIX/imported.reg" ;;
          start) echo "start:$2" >> "$WINEPREFIX/started" ;;
          *.exe|/*) echo "exe:$1 cwd:$(pwd) extra:$DECANTER_GAME_ENV" >> "$WINEPREFIX/launched"; sleep 1 ;;
        esac
        exit 0
        """
        let wineserver = """
        #!/bin/sh
        echo "wineserver $*" >> "$WINEPREFIX/calls.log"
        exit 0
        """
        try wine.write(to: bin.appendingPathComponent("wine"), atomically: true, encoding: .utf8)
        try wineserver.write(to: bin.appendingPathComponent("wineserver"), atomically: true, encoding: .utf8)
        for f in ["wine", "wineserver"] {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent(f).path)
        }
        return app
    }

    private func makeArchive(named name: String, in dir: URL) throws -> URL {
        let stage = dir.appendingPathComponent("stage-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        _ = try makeFakeApp(in: stage)
        let archive = dir.appendingPathComponent(name)
        _ = try runSync("/usr/bin/tar", ["-cJf", archive.path, "-C", stage.path, "Wine Stable.app"])
        return archive
    }

    @discardableResult
    private func runSync(_ path: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: Tests

    func testInstallLocalArchiveThenPrefixThenLaunch() async throws {
        let archive = try makeArchive(named: "wine-stable-11.0_1-osx64.tar.xz", in: scratch)
        let manager = RunnerManager()
        var phases: [String] = []
        let collector = PhaseCollector()
        let runner = try await manager.install(archive: archive) { p in collector.add(p.phase) }
        phases = collector.phases
        XCTAssertEqual(runner.id, "wine-stable-11.0_1")
        XCTAssertEqual(runner.source, .local)
        XCTAssertTrue(fm.isExecutableFile(atPath: runner.wine.path), runner.wine.path)
        XCTAssertEqual(runner.directory.lastPathComponent, "wine-stable-11.0_1")
        XCTAssertTrue(fm.fileExists(atPath: runner.directory.appendingPathComponent("runner.json").path))
        XCTAssertTrue(phases.contains { $0.hasPrefix("Unpacking") })
        let installedIDs = await manager.installed().map(\.id)
        XCTAssertEqual(installedIDs, ["wine-stable-11.0_1"])

        // Second install of the same id is refused
        do {
            _ = try await manager.install(archive: archive) { _ in }
            XCTFail("expected alreadyInstalled")
        } catch RunnerError.alreadyInstalled(let id) { XCTAssertEqual(id, "wine-stable-11.0_1") }

        try await manager.setDefault(runner)
        let defaultID = await manager.defaultRunner()?.id
        XCTAssertEqual(defaultID, runner.id)

        // Prefix creation drives wineboot, wineserver -w, winecfg /v
        let prefixes = PrefixManager()
        let prefix = try await prefixes.create(name: "browser-game", runner: runner, windowsVersion: .win7)
        XCTAssertTrue(fm.fileExists(atPath: prefix.driveC.path))
        let calls = try String(contentsOf: prefix.url.appendingPathComponent("calls.log"))
        XCTAssertEqual(calls.split(separator: "\n").map(String.init), ["wine wineboot -u", "wineserver -w", "wine winecfg /v win7"])
        XCTAssertEqual(try String(contentsOf: prefix.url.appendingPathComponent("winver")).trimmingCharacters(in: .newlines), "win7")
        let listed = await prefixes.list()
        XCTAssertEqual(listed.map(\.name), ["browser-game"])
        XCTAssertEqual(listed.first?.runnerID, runner.id)

        do {
            _ = try await prefixes.create(name: "browser-game", runner: runner)
            XCTFail("expected alreadyExists")
        } catch PrefixError.alreadyExists { }

        // Registry import writes a .reg and runs regedit /S on it
        try await prefixes.importRegistry(entries: [
            RegistryEntry(key: "HKEY_CLASSES_ROOT\\gamename", strings: ["": "URL:Game Protocol", "URL Protocol": ""]),
        ], prefix: prefix, runner: runner)
        let imported = try String(contentsOf: prefix.url.appendingPathComponent("imported.reg"))
        XCTAssertTrue(imported.hasPrefix("Windows Registry Editor Version 5.00"))
        XCTAssertTrue(imported.contains("[HKEY_CLASSES_ROOT\\gamename]"))

        // Launch: wine <exe> with cwd = exe dir and the game's env; playtime reported on exit
        let exeDir = prefix.driveC.appendingPathComponent("Game", isDirectory: true)
        try fm.createDirectory(at: exeDir, withIntermediateDirectories: true)
        let exe = exeDir.appendingPathComponent("game.exe")
        try Data().write(to: exe)
        let game = Game(name: "Game", prefixName: prefix.name, runnerID: runner.id,
                        exePath: Game.storedExePath(for: exe, in: prefix), args: ["-windowed"], env: ["DECANTER_GAME_ENV": "yes"])
        XCTAssertEqual(game.exePath, "drive_c/Game/game.exe")

        let launcher = Launcher()
        let exitBox = ExitBox()
        let process = try await launcher.launch(game: game, prefix: prefix, runner: runner) { code, seconds in
            exitBox.set(code: code, seconds: seconds)
        }
        let runningNow = await launcher.isRunning(game.id)
        XCTAssertTrue(runningNow)
        let code = await process.waitUntilExit()
        XCTAssertEqual(code, 0)
        // give the launcher's bookkeeping task a moment
        for _ in 0..<50 where exitBox.code == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(exitBox.code, 0)
        let runningAfter = await launcher.isRunning(game.id)
        XCTAssertFalse(runningAfter)
        let launched = try String(contentsOf: prefix.url.appendingPathComponent("launched"))
        XCTAssertTrue(launched.contains("exe:\(exe.path)"), launched)
        XCTAssertTrue(launched.contains("cwd:\(exeDir.path)"), launched)
        XCTAssertTrue(launched.contains("extra:yes"), launched)

        // Stop → wineserver -k; start → wine start <url>
        try await launcher.stop(game: game, prefix: prefix, runner: runner)
        let startProc = try await launcher.start("gamename://launch", prefix: prefix, runner: runner)
        _ = await startProc.waitUntilExit()
        let calls2 = try String(contentsOf: prefix.url.appendingPathComponent("calls.log"))
        XCTAssertTrue(calls2.contains("wineserver -k"))
        XCTAssertTrue(calls2.contains("wine start gamename://launch"))

        // Missing exe is rejected before spawning
        var bad = game; bad.exePath = "drive_c/nope.exe"
        do {
            _ = try await launcher.launch(game: bad, prefix: prefix, runner: runner)
            XCTFail("expected exeMissing")
        } catch LaunchError.exeMissing { }

        // Destroy prefix
        try await prefixes.destroy(prefix, runner: runner)
        XCTAssertFalse(fm.fileExists(atPath: prefix.url.path))

        // Delete runner
        try await manager.delete(runner)
        let remaining = await manager.installed()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testInstallBundledFromSplitParts() async throws {
        // Synthetic Vendor/ tree: manifest + split parts + winetricks
        let vendor = scratch.appendingPathComponent("Vendor", isDirectory: true)
        let runnersDir = vendor.appendingPathComponent("runners", isDirectory: true)
        try fm.createDirectory(at: runnersDir, withIntermediateDirectories: true)
        let archive = try makeArchive(named: "wine-stable-11.0_1-osx64.tar.xz", in: scratch)
        let data = try Data(contentsOf: archive)
        let sha = SHA256Digest.hex(of: data)
        let partSize = max(1, data.count / 3 + 1)
        var parts: [String] = []
        var offset = 0
        while offset < data.count {
            let name = "wine-stable-11.0_1-osx64.tar.xz.part-0\(parts.count)"
            try data[offset..<min(offset + partSize, data.count)].write(to: runnersDir.appendingPathComponent(name))
            parts.append(name)
            offset += partSize
        }
        let wt = vendor.appendingPathComponent("winetricks", isDirectory: true)
        try fm.createDirectory(at: wt, withIntermediateDirectories: true)
        let wtScript = "#!/bin/sh\necho \"winetricks $*\" >> \"$WINEPREFIX/calls.log\"\necho \"WINE=$WINE\" >> \"$WINEPREFIX/calls.log\"\n"
        try wtScript.write(to: wt.appendingPathComponent("winetricks"), atomically: true, encoding: .utf8)
        let manifest = """
        {"runners":[{"kind":"wine-stable","version":"11.0_1","asset":"wine-stable-11.0_1-osx64.tar.xz",
          "sha256":"\(sha)","size":\(data.count),"parts":[\(parts.map { "\"\($0)\"" }.joined(separator: ","))]}],
         "winetricks":{"file":"winetricks/winetricks","sha256":"\(SHA256Digest.hex(of: wtScript.data(using: .utf8)!))","version":"test"}}
        """
        try manifest.write(to: runnersDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let manager = RunnerManager()
        let bundled = await manager.bundledRunners(vendorDir: vendor)
        XCTAssertEqual(bundled.map(\.id), ["wine-stable-11.0_1"])
        let collector = PhaseCollector()
        let runner = try await manager.installBundled(bundled[0], vendorDir: vendor) { p in collector.add(p.phase) }
        XCTAssertEqual(runner.source, .bundled)
        XCTAssertEqual(runner.sha256, sha)
        XCTAssertTrue(collector.phases.contains { $0.hasPrefix("Assembling") })
        XCTAssertTrue(collector.phases.contains { $0.hasPrefix("Verifying") })
        XCTAssertTrue(fm.isExecutableFile(atPath: runner.wine.path))
        XCTAssertEqual(try SHA256Digest.hex(ofFile: Paths.cache.appendingPathComponent(bundled[0].asset)), sha)

        // Corrupt manifest hash → refused, nothing installed
        try await manager.delete(runner)
        var badRunner = bundled[0]
        badRunner.sha256 = String(repeating: "0", count: 64)
        try fm.removeItem(at: Paths.cache.appendingPathComponent(bundled[0].asset))
        do {
            _ = try await manager.installBundled(badRunner, vendorDir: vendor) { _ in }
            XCTFail("expected checksumMismatch")
        } catch RunnerError.checksumMismatch { }
        let afterBad = await manager.installed()
        XCTAssertTrue(afterBad.isEmpty)

        // winetricks: vendored script is copied (hash-checked) and run with WINE set
        let good = try await manager.installBundled(bundled[0], vendorDir: vendor) { _ in }
        let prefixes = PrefixManager()
        let prefix = try await prefixes.create(name: "wt", runner: good)
        // point the prefix manager at the synthetic vendor dir via a pre-seeded cache copy
        try fm.copyItem(at: wt.appendingPathComponent("winetricks"), to: Paths.cache.appendingPathComponent("winetricks"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.cache.appendingPathComponent("winetricks").path)
        try await prefixes.winetricks(verbs: ["corefonts", "vcrun2010"], prefix: prefix, runner: good)
        let calls = try String(contentsOf: prefix.url.appendingPathComponent("calls.log"))
        XCTAssertTrue(calls.contains("winetricks --unattended corefonts vcrun2010"), calls)
        XCTAssertTrue(calls.contains("WINE=\(good.wine.path)"), calls)
    }
}

final class PhaseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _phases: [String] = []
    var phases: [String] { lock.lock(); defer { lock.unlock() }; return _phases }
    func add(_ p: String) { lock.lock(); _phases.append(p); lock.unlock() }
}

final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _code: Int32?
    private var _seconds: Int?
    var code: Int32? { lock.lock(); defer { lock.unlock() }; return _code }
    func set(code: Int32, seconds: Int) { lock.lock(); _code = code; _seconds = seconds; lock.unlock() }
}
