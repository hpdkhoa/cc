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
- Dependencies: Yams (YAML). Do not add others without asking.
- All Wine invocations go through `Core/WineProcess.swift`. Nothing else spawns `wine` directly.
- Wine builds are x86_64 → require Rosetta on Apple Silicon. Check with `arch -x86_64 /usr/bin/true` and prompt if missing.
- Data dir: `~/Library/Application Support/Decanter/` with `runners/`, `prefixes/`, `recipes/`, `cache/`, `library.json`.
- Runner source: https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases — download the `wine-stable-*-osx64.tar.xz` asset, unpack, then `xattr -dr com.apple.quarantine` on the .app.
- Binaries inside a runner: `<Wine Stable.app>/Contents/Resources/wine/bin/{wine,wineserver}`. winetricks: download raw script from github.com/Winetricks/winetricks into cache/ and run with the runner's wine on PATH.

## Architecture (details in docs/PLAN.md)
- `Core/WineProcess`    — the single Process wrapper; streams output
- `Core/RunnerManager`  — list/download/verify/delete runners
- `Core/PrefixManager`  — create (wineboot), regedit (.reg import), winetricks, destroy
- `Core/Launcher`       — build env, spawn, track PID, `wineserver -k` on stop
- `Core/Installer`      — run a Recipe against a fresh prefix (Phase 3)
- `Models/`             — Game, Runner (Codable)
- `Recipes/`            — Recipe model + RecipeStore (Phase 3)
- `Views/`              — Library, GameDetail, Runners, AddGame, InstallRecipe, LogConsole

## Conventions
- async/await; managers are `actor`s, UI state is `@MainActor @Observable`.
- Persist library as JSON at `library.json` (SwiftData later).
- Log every external command (argv + env diff) to the LogConsole.
- Never `sudo`. Never write outside the data dir except paths the user picked.
- UI minimal; function first. Verify each feature by actually running `swift run` before moving on.

## Working order
Phase 1 in docs/PLAN.md, top to bottom. Stop and ask when a design decision isn't covered here.
