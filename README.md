# Decanter
Lutris-style Wine game manager for macOS (personal build, unsigned).

## Build & run (no internet needed)
Everything the app needs is inside this repo:

| What | Where |
|------|-------|
| Yams (only Swift dependency) | `Vendor/Yams/` — a local path dependency, so `swift build` never hits the network |
| Wine runner: Gcenx **wine-stable 11.0_1** (185 MB) | `Vendor/runners/wine-stable-11.0_1-osx64.tar.xz.part-00…03` + `manifest.json` (SHA-256) |
| winetricks | `Vendor/winetricks/winetricks` |

```sh
softwareupdate --install-rosetta --agree-to-license   # Apple Silicon only, once
swift build
swift run Decanter
```

Then in the app: **Runners → Bundled (offline) → Install**. The parts are joined into
`~/Library/Application Support/Decanter/cache/`, hash-checked, unpacked into
`runners/wine-stable-11.0_1/Wine Stable.app`, and the quarantine attribute is removed.
No download happens. (Online downloads from Gcenx's GitHub releases are also available in
the same tab, and any `wine-*-osx64.tar.xz` can be imported.)

Without the app you can rebuild the tarball by hand:
```sh
cat Vendor/runners/wine-stable-11.0_1-osx64.tar.xz.part-* > wine-stable-11.0_1-osx64.tar.xz
scripts/verify-vendor.sh          # checks the SHA-256 in Vendor/runners/manifest.json
```

## Layout
- `Sources/DecanterCore` — Foundation-only core (runners, prefixes, launcher, process wrapper). Builds and tests on Linux too.
- `Sources/Decanter` — the SwiftUI app (macOS 14+).
- `Tests/DecanterCoreTests` — unit tests plus fake-wine integration tests
  (`DECANTER_DATA_DIR=/tmp/decanter-test swift test`).
- `Vendor/` — offline install files (see above). Refresh with `scripts/vendor-fetch.sh [tag]`.
- `docs/PLAN.md`, `docs/RECIPE_SCHEMA.md`, `CLAUDE.md` — plan, recipe schema, working notes.

## Useful env vars
- `DECANTER_DATA_DIR` — data directory override (default `~/Library/Application Support/Decanter`).
- `DECANTER_VENDOR_DIR` — where to find `runners/manifest.json` if not running from the checkout.
- `DECANTER_LOG_STDERR=1` — mirror the in-app log console to the terminal.
