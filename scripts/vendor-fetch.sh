#!/bin/sh
# Refresh the vendored offline-install files under Vendor/ (needs internet once).
#   scripts/vendor-fetch.sh            # wine-stable 11.0_1 (default)
#   scripts/vendor-fetch.sh 11.0_1     # another Gcenx tag
# Downloads the Gcenx tarball + winetricks, splits the tarball into <50 MB parts
# (GitHub rejects files over 100 MB) and rewrites Vendor/runners/manifest.json.
set -eu
TAG="${1:-11.0_1}"
KIND="${KIND:-wine-stable}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="$ROOT/Vendor"
ASSET="$KIND-$TAG-osx64.tar.xz"
URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/$TAG/$ASSET"
WT_URL="https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$V/runners" "$V/winetricks"
echo "downloading $URL"
curl -fL --retry 3 -o "$TMP/$ASSET" "$URL"
echo "downloading winetricks"
curl -fL --retry 3 -o "$V/winetricks/winetricks" "$WT_URL"
chmod +x "$V/winetricks/winetricks"

sha() { if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
SHA="$(sha "$TMP/$ASSET")"
SIZE="$(wc -c < "$TMP/$ASSET" | tr -d ' ')"
WT_SHA="$(sha "$V/winetricks/winetricks")"
WT_VER="$(grep -m1 '^WINETRICKS_VERSION=' "$V/winetricks/winetricks" | cut -d= -f2)"

rm -f "$V/runners/$KIND-"*.part-*
( cd "$V/runners" && split -b 49m -d -a 2 "$TMP/$ASSET" "$ASSET.part-" )
PARTS="$(ls "$V/runners" | grep "^$ASSET.part-" | sort | sed 's/.*/        "&"/' | paste -sd, - | sed 's/,/,\n/g')"

cat > "$V/runners/manifest.json" <<JSON
{
  "runners": [
    {
      "kind": "$KIND",
      "version": "$TAG",
      "asset": "$ASSET",
      "sha256": "$SHA",
      "size": $SIZE,
      "parts": [
$PARTS
      ],
      "source_url": "$URL"
    }
  ],
  "winetricks": {
    "file": "winetricks/winetricks",
    "sha256": "$WT_SHA",
    "version": "$WT_VER",
    "source_url": "$WT_URL"
  }
}
JSON
echo "wrote $V/runners/manifest.json ($ASSET, $SIZE bytes, sha256 $SHA)"
