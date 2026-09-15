#!/bin/sh
# Check the vendored runner parts reassemble to the manifest's SHA-256 (no build needed).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/Vendor/runners/manifest.json"
sha() { if command -v shasum >/dev/null; then shasum -a 256 | cut -d' ' -f1; else sha256sum | cut -d' ' -f1; fi; }
EXPECTED="$(grep -m1 '"sha256"' "$M" | sed 's/.*"sha256": *"\([0-9a-f]*\)".*/\1/')"
ASSET="$(grep -m1 '"asset"' "$M" | sed 's/.*"asset": *"\([^"]*\)".*/\1/')"
ACTUAL="$(cat "$ROOT/Vendor/runners/$ASSET".part-* | sha)"
if [ "$EXPECTED" = "$ACTUAL" ]; then echo "OK  $ASSET  $ACTUAL"; else echo "MISMATCH expected $EXPECTED got $ACTUAL"; exit 1; fi
WT_EXPECTED="$(grep -A3 '"winetricks"' "$M" | grep '"sha256"' | sed 's/.*"sha256": *"\([0-9a-f]*\)".*/\1/')"
WT_ACTUAL="$(sha < "$ROOT/Vendor/winetricks/winetricks")"
if [ "$WT_EXPECTED" = "$WT_ACTUAL" ]; then echo "OK  winetricks  $WT_ACTUAL"; else echo "MISMATCH winetricks"; exit 1; fi
