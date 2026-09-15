# Phases

## Phase 1 — MVP (usable for the browser+game case)
- [ ] Paths.bootstrap + Rosetta check on launch
- [ ] RunnerManager: fetch release list, download + unpack + dequarantine, mark default
- [ ] WineProcess: run(runner, prefix, exe, args, env) -> AsyncStream<String>
- [ ] PrefixManager: create (`wineboot -u`), set Windows version, import .reg, run winetricks verbs
- [ ] Launcher: start exe in prefix; stop = `wineserver -k`
- [ ] Views: Library grid, Add local .exe wizard (runner, prefix name, exe)
- [ ] GameDetail: Launch, Stop, Reveal prefix, winecfg, regedit, winetricks, LogConsole
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
