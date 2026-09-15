import XCTest
@testable import DecanterCore

final class ParsingTests: XCTestCase {
    func testParseAssetName() {
        let p = RunnerManager.parseAssetName("wine-stable-11.0_1-osx64.tar.xz")
        XCTAssertEqual(p?.kind, .stable)
        XCTAssertEqual(p?.version, "11.0_1")
        XCTAssertEqual(RunnerManager.parseAssetName("wine-devel-11.17-osx64.tar.xz")?.kind, .devel)
        XCTAssertEqual(RunnerManager.parseAssetName("wine-staging-11.17-osx64.tar.xz")?.version, "11.17")
        XCTAssertNil(RunnerManager.parseAssetName("wine-stable-11.0_1-osx64.dmg"))
        XCTAssertNil(RunnerManager.parseAssetName("something-else.tar.xz"))
    }

    func testWineVersionOrdering() {
        XCTAssertLessThan(WineVersion("9.0"), WineVersion("11.0_1"))
        XCTAssertLessThan(WineVersion("11.0"), WineVersion("11.0_1"))
        XCTAssertLessThan(WineVersion("11.9"), WineVersion("11.17"))
        XCTAssertEqual(WineVersion("11.0").components, [11, 0])
    }

    func testParseReleases() throws {
        let json = """
        [
          {"tag_name": "11.17", "prerelease": false, "published_at": "2026-09-01T10:00:00Z",
           "assets": [
             {"name": "wine-devel-11.17-osx64.tar.xz", "size": 100, "browser_download_url": "https://x/devel"},
             {"name": "wine-staging-11.17-osx64.tar.xz", "size": 200, "browser_download_url": "https://x/staging"},
             {"name": "README.txt", "size": 1, "browser_download_url": "https://x/readme"}
           ]},
          {"tag_name": "11.0_1", "prerelease": false, "published_at": null,
           "assets": [
             {"name": "wine-stable-11.0_1-osx64.tar.xz", "size": 185303032, "browser_download_url": "https://x/stable"}
           ]}
        ]
        """.data(using: .utf8)!
        let releases = try RunnerManager.parseReleases(json)
        XCTAssertEqual(releases.map(\.id), ["wine-devel-11.17", "wine-staging-11.17", "wine-stable-11.0_1"])
        XCTAssertEqual(releases.last?.size, 185303032)
        XCTAssertNotNil(releases.first?.publishedAt)
    }

    func testRegFileText() {
        let text = PrefixManager.regFileText([
            RegistryEntry(key: "HKEY_CLASSES_ROOT\\gamename", strings: ["": "URL:Game Protocol", "URL Protocol": ""]),
            RegistryEntry(key: "HKEY_CLASSES_ROOT\\gamename\\shell\\open\\command",
                          strings: ["": "\"C:\\Program Files\\Game\\game.exe\" \"%1\""]),
            RegistryEntry(key: "HKEY_CURRENT_USER\\Software\\Wine\\Test", values: ["Flag": .dword(1)]),
        ])
        let expected = [
            "Windows Registry Editor Version 5.00", "",
            "[HKEY_CLASSES_ROOT\\gamename]",
            "@=\"URL:Game Protocol\"",
            "\"URL Protocol\"=\"\"", "",
            "[HKEY_CLASSES_ROOT\\gamename\\shell\\open\\command]",
            "@=\"\\\"C:\\\\Program Files\\\\Game\\\\game.exe\\\" \\\"%1\\\"\"", "",
            "[HKEY_CURRENT_USER\\Software\\Wine\\Test]",
            "\"Flag\"=dword:00000001", "",
        ].joined(separator: "\r\n") + "\r\n"
        XCTAssertEqual(text, expected)
    }

    func testPrefixNameValidation() {
        XCTAssertTrue(PrefixManager.isValidName("browser-game"))
        XCTAssertTrue(PrefixManager.isValidName("My Game 2"))
        XCTAssertFalse(PrefixManager.isValidName(""))
        XCTAssertFalse(PrefixManager.isValidName(".hidden"))
        XCTAssertFalse(PrefixManager.isValidName("a/b"))
        XCTAssertFalse(PrefixManager.isValidName(" pad"))
    }

    func testShellQuote() {
        XCTAssertEqual(CommandSpec.shellQuote("simple-1.0"), "simple-1.0")
        XCTAssertEqual(CommandSpec.shellQuote("has space"), "'has space'")
        XCTAssertEqual(CommandSpec.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(CommandSpec.shellQuote(""), "''")
    }

    func testBundledManifestDecodes() throws {
        let json = """
        {"runners":[{"kind":"wine-stable","version":"11.0_1","asset":"a.tar.xz","sha256":"00","size":5,
                     "parts":["a.part-00"],"source_url":"https://x"}],
         "winetricks":{"file":"winetricks/winetricks","sha256":"11","version":"2026"}}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(BundledManifest.self, from: json)
        XCTAssertEqual(m.runners.first?.id, "wine-stable-11.0_1")
        XCTAssertEqual(m.runners.first?.sourceURL, "https://x")
        XCTAssertEqual(m.winetricks?.version, "2026")
    }
}

final class SHA256Tests: XCTestCase {
    func testKnownVectors() {
        var h = PureSHA256()
        XCTAssertEqual(h.finalizeHex(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        h = PureSHA256(); h.update("abc".data(using: .utf8)!)
        XCTAssertEqual(h.finalizeHex(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        h = PureSHA256(); h.update("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".data(using: .utf8)!)
        XCTAssertEqual(h.finalizeHex(), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // multi-block, chunked updates
        h = PureSHA256()
        let million = Data(repeating: 0x61, count: 1_000_000)
        var i = 0
        while i < million.count { let n = min(7919, million.count - i); h.update(million[i..<i + n]); i += n }
        XCTAssertEqual(h.finalizeHex(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        XCTAssertEqual(SHA256Digest.hex(of: "abc".data(using: .utf8)!),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testFileHashMatchesData() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("decanter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let file = dir.appendingPathComponent("blob")
        try data.write(to: file)
        XCTAssertEqual(try SHA256Digest.hex(ofFile: file), SHA256Digest.hex(of: data))
    }
}

final class StorageTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("decanter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testLibraryRoundTrip() throws {
        let url = dir.appendingPathComponent("library.json")
        let game = Game(name: "Test", prefixName: "p", runnerID: "wine-stable-11.0_1",
                        exePath: "drive_c/Program Files/x/y.exe", args: ["-w"], env: ["WINEDEBUG": "-all"],
                        lastPlayed: Date(timeIntervalSince1970: 1_700_000_000), playtimeSeconds: 42,
                        addedAt: Date(timeIntervalSince1970: 1_690_000_000))
        try LibraryStore.save([game], to: url)
        let loaded = try LibraryStore.load(from: url)
        XCTAssertEqual(loaded, [game])
        XCTAssertEqual(try LibraryStore.load(from: dir.appendingPathComponent("missing.json")), [])
    }

    func testJoinPartsAndVerify() throws {
        let parts = (0..<3).map { dir.appendingPathComponent("blob.part-0\($0)") }
        var whole = Data()
        for (i, p) in parts.enumerated() {
            let d = Data(repeating: UInt8(i + 1), count: 1000 + i)
            try d.write(to: p)
            whole.append(d)
        }
        let out = dir.appendingPathComponent("blob")
        var last: Int64 = 0
        try RunnerManager.join(parts: parts, into: out) { last = $0 }
        XCTAssertEqual(last, Int64(whole.count))
        XCTAssertEqual(try Data(contentsOf: out), whole)
        XCTAssertEqual(try SHA256Digest.hex(ofFile: out), SHA256Digest.hex(of: whole))
        XCTAssertThrowsError(try RunnerManager.join(parts: [dir.appendingPathComponent("nope")], into: out))
    }

    func testVendoredManifestMatchesFiles() throws {
        // Repo sanity: the manifest's parts exist and the winetricks hash matches.
        guard let vendor = Paths.vendorDir else { return XCTFail("Vendor/ not found from #filePath") }
        let m = try JSONDecoder().decode(BundledManifest.self, from: Data(contentsOf: vendor.appendingPathComponent("runners/manifest.json")))
        for r in m.runners {
            var total: Int64 = 0
            for p in r.parts {
                let url = vendor.appendingPathComponent("runners/\(p)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), p)
                total += (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            }
            XCTAssertEqual(total, r.size, "parts of \(r.asset) must add up to the manifest size")
        }
        if let w = m.winetricks {
            XCTAssertEqual(try SHA256Digest.hex(ofFile: vendor.appendingPathComponent(w.file)), w.sha256)
        }
    }

    func testGameExePathStorage() {
        let prefix = WinePrefix(name: "p", runnerID: "r")
        let inside = prefix.url.appendingPathComponent("drive_c/Game/game.exe")
        XCTAssertEqual(Game.storedExePath(for: inside, in: prefix), "drive_c/Game/game.exe")
        let outside = URL(fileURLWithPath: "/Applications/Other/x.exe")
        XCTAssertEqual(Game.storedExePath(for: outside, in: prefix), "/Applications/Other/x.exe")
        let g = Game(name: "g", prefixName: "p", runnerID: "r", exePath: "drive_c/Game/game.exe")
        XCTAssertEqual(g.resolvedExe(in: prefix).path, inside.path)
    }
}

final class ProcessTests: XCTestCase {
    func testSpawnStreamsOutputAndEnv() async throws {
        let spec = CommandSpec(path: "/bin/sh", arguments: ["-c", "echo one; echo \"$DECANTER_TEST_VAR\" 1>&2; printf 'no-newline'; exit 3"],
                               environment: ["DECANTER_TEST_VAR": "hello"], label: "sh-test")
        let result = try await WineProcess.run(spec, check: false)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.output, ["one", "hello", "no-newline"])

        let entries = Log.shared.snapshot().filter { $0.source == "sh-test" }
        XCTAssertTrue(entries.contains { $0.level == .command && $0.message.contains("DECANTER_TEST_VAR=hello") })
        XCTAssertTrue(entries.contains { $0.level == .output && $0.message == "hello" })
        XCTAssertTrue(entries.contains { $0.level == .error && $0.message.contains("code 3") })
    }

    func testRunThrowsOnFailure() async {
        do {
            try await WineProcess.run(CommandSpec(path: "/bin/sh", arguments: ["-c", "echo bad; exit 1"]))
            XCTFail("expected throw")
        } catch let e as CommandError {
            XCTAssertEqual(e.exitCode, 1)
            XCTAssertEqual(e.outputTail, ["bad"])
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testWineEnvironment() {
        let runner = Runner(kind: .stable, version: "11.0_1", appPath: URL(fileURLWithPath: "/tmp/r/Wine Stable.app"))
        let env = WineProcess.wineEnvironment(runner: runner, prefix: URL(fileURLWithPath: "/tmp/p"), extra: ["WINEDEBUG": "+all"])
        XCTAssertEqual(env["WINEPREFIX"], "/tmp/p")
        XCTAssertEqual(env["WINEDEBUG"], "+all")
        XCTAssertEqual(env["WINE"], "/tmp/r/Wine Stable.app/Contents/Resources/wine/bin/wine")
        XCTAssertTrue(env["PATH"]!.hasPrefix("/tmp/r/Wine Stable.app/Contents/Resources/wine/bin:"))
        let spec = WineProcess.wine(runner: runner, prefix: URL(fileURLWithPath: "/tmp/p"), arguments: ["wineboot", "-u"])
        XCTAssertEqual(spec.executable.path, runner.wine.path)
        XCTAssertEqual(spec.arguments, ["wineboot", "-u"])
    }

    func testLogStreamReplaysHistory() async {
        let log = Log()
        log.info("a", "first")
        let stream = log.stream()
        log.info("a", "second")
        var got: [String] = []
        for await e in stream {
            got.append(e.message)
            if got.count == 2 { break }
        }
        XCTAssertEqual(got, ["first", "second"])
    }
}
