# Recipe schema (v1)

```yaml
name: My Game
slug: my-game
version: 1
runner:
  kind: wine            # wine | gptk (later)
  min_version: "10.0"
prefix:
  arch: win64           # WoW64 handles 32-bit apps
  windows_version: win7 # winxp | win7 | win10
files:                  # downloaded to cache/ before install; sha256 required
  - id: game_installer
    url: https://example.com/setup.exe
    sha256: "..."
winetricks: [vcrun2010, corefonts]
steps:                  # in order; ONLY these step types exist
  - run: { file: game_installer, args: ["/S"] }
  - registry:
      key: HKEY_CLASSES_ROOT\gamename
      values: { "": "URL:Game Protocol", "URL Protocol": "" }
  - registry:
      key: HKEY_CLASSES_ROOT\gamename\shell\open\command
      values: { "": '"C:\Program Files\Game\game.exe" "%1"' }
  - copy: { from: "drive_c/x", to: "drive_c/y" }
launch:
  exe: "drive_c/Program Files/Mozilla Firefox/firefox.exe"
  args: []
  env: { WINEDEBUG: "-all" }
```

Security: no shell steps. `run` only executes ids from `files` or paths inside the prefix. Downloads must match sha256.
