# Phases

## Phase 1 — MVP (usable for the browser+game case)
- [x] Paths.bootstrap + Rosetta check on launch
- [x] RunnerManager: fetch release list, download + unpack + dequarantine, mark default
- [x] RunnerManager: offline install from `Vendor/runners` (split tarball + sha256) and from a local .tar.xz
- [x] WineProcess: spawn/run(CommandSpec) -> RunningProcess with AsyncStream<String>; wine/wineserver/winetricks builders
- [x] PrefixManager: create (`wineboot -u`), set Windows version, import .reg, run winetricks verbs
- [x] Launcher: start exe in prefix; stop = `wineserver -k`; `wine start <url>` for scheme tests
- [x] Views: Library grid, Add local .exe wizard (runner, prefix name, exe)
- [x] GameDetail: Launch, Stop, Reveal prefix, winecfg, regedit, winetricks, LogConsole
- [x] Core verified on Linux: 19 XCTest cases incl. fake-wine integration (install → prefix → regedit → launch → stop)
- [ ] `swift run Decanter` on a Mac: UI smoke test (not possible in the Linux dev container)
- [ ] Manual test: browser + game in one prefix, HKCR URL scheme, `wine start scheme://x` opens game

## Phase 2 — Settings
- [ ] Per-game env vars, args, Windows version, DPI
- [ ] Duplicate / delete prefix
- [ ] Cover art (SteamGridDB key), playtime

## Phase 3 — Recipes
- [ ] Recipe Codable model + Yams parsing
- [ ] Installer: whitelisted steps only (run, registry, copy)
- [ ] Remote recipe index (GitHub repo, JSON index)
- [ ] 5 shipped recipes incl. Recipes/example-url-launcher.yaml

## Phase 4 — Runners
- [ ] Apple Game Porting Toolkit (user supplies D3DMetal; never redistribute)
- [ ] DXVK toggle

## Phase 5 — Distribution (later)
- [ ] Sign + notarize, Sparkle, GitHub releases
