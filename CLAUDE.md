# Decanter — a Lutris-style Wine game manager for macOS

Personal-use project. No code signing / notarization for now (skip Gatekeeper; quarantine is stripped manually or by the app).

## Goal
Native SwiftUI app that:
1. Downloads and manages Wine runners (Gcenx builds from GitHub releases)
2. Creates isolated Wine prefixes per game
3. Installs games from YAML recipes (Lutris-inspired schema, see docs/RECIPE_SCHEMA.md)
4. Launches games from a library view, with logs

First concrete use case: one prefix containing a Windows browser + a Flash-era game .exe; the browser logs into a site and launches the game via a custom URL scheme registered in HKCR. Recipes/example-url-launcher.yaml must support this.

## Stack & constraints
- Swift 5.9+, SwiftUI, macOS 14+. Build with `swift build`, run with `swift run Decanter`. No Xcode project yet (add XcodeGen later if needed).
- Dependencies: Yams (YAML), vendored at `Vendor/Yams` as a local path dependency so builds work offline. Do not add others without asking.
- Offline install: `Vendor/runners/` holds the Gcenx wine-stable tarball split into <50 MB parts (GitHub's 100 MB file cap) plus `manifest.json` with sha256; `Vendor/winetricks/winetricks` is the script. Refresh with `scripts/vendor-fetch.sh`. The app finds `Vendor/` via `Paths.vendorDir` (env `DECANTER_VENDOR_DIR`, the source tree, or next to the binary).
- All Wine invocations go through `Core/WineProcess.swift`. Nothing else spawns `wine` directly.
- Wine builds are x86_64 → require Rosetta on Apple Silicon. Check with `arch -x86_64 /usr/bin/true` and prompt if missing.
- Data dir: `~/Library/Application Support/Decanter/` with `runners/`, `prefixes/`, `recipes/`, `cache/`, `library.json`.
- Runner source: https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases — download the `wine-stable-*-osx64.tar.xz` asset, unpack, then `xattr -dr com.apple.quarantine` on the .app.
- Binaries inside a runner: `<Wine Stable.app>/Contents/Resources/wine/bin/{wine,wineserver}`. winetricks: download raw script from github.com/Winetricks/winetricks into cache/ and run with the runner's wine on PATH.

## Architecture (details in docs/PLAN.md)
Two targets: `DecanterCore` (Foundation only — builds and tests on Linux, no UI imports allowed)
and `Decanter` (SwiftUI app, macOS only; `Package.swift` adds it only when building on macOS).
- `DecanterCore/Core/WineProcess`    — the single Process wrapper; `spawn`/`run(CommandSpec)`, streams output, logs argv + env diff
- `DecanterCore/Core/RunnerManager`  — list/download/install (GitHub, vendored parts, local .tar.xz)/verify/delete runners
- `DecanterCore/Core/PrefixManager`  — create (wineboot), winecfg /v, regedit (.reg import + builder), winetricks, destroy, open tools
- `DecanterCore/Core/Launcher`       — build env, spawn, track process + playtime, `wineserver -k` on stop, `wine start <url>`
- `DecanterCore/Core/Installer`      — run a Recipe against a fresh prefix (Phase 3)
- `DecanterCore/Core/{Paths,Log,SHA256,Downloader,Rosetta,LibraryStore}` — support
- `DecanterCore/Models/`             — Runner, RunnerRelease, BundledManifest, WinePrefix, Game (Codable)
- `DecanterCore/Recipes/`            — Recipe model + RecipeStore (Phase 3)
- `Decanter/App/AppState`            — `@MainActor @Observable` UI state over the Core actors
- `Decanter/Views/`                  — Library, GameDetail, Runners, AddGame, LogConsole (InstallRecipe in Phase 3)
- `Tests/DecanterCoreTests`          — unit tests + fake-wine integration tests (`DECANTER_DATA_DIR=/tmp/x swift test`)

## Conventions
- async/await; managers are `actor`s, UI state is `@MainActor @Observable`.
- Persist library as JSON at `library.json` (SwiftData later).
- Log every external command (argv + env diff) to the LogConsole.
- Never `sudo`. Never write outside the data dir except paths the user picked.
- UI minimal; function first. Verify each feature by actually running `swift run` before moving on.
- Without a Mac (e.g. Linux container): `swift build && DECANTER_DATA_DIR=/tmp/decanter-test swift test` covers Core; the UI target is skipped there. `DECANTER_LOG_STDERR=1` echoes the log console to the terminal.

## Working order
Phase 1 in docs/PLAN.md, top to bottom. Stop and ask when a design decision isn't covered here.
