#!/usr/bin/env bash
# Download Sparkle CLI tools (generate_keys / sign_update / generate_appcast) into tools/sparkle/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/tools/sparkle"
VER="${SPARKLE_VERSION:-2.9.4}"
URL="https://github.com/sparkle-project/Sparkle/releases/download/${VER}/Sparkle-${VER}.tar.xz"
mkdir -p "$DEST"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "==> Fetch $URL"
curl -sL "$URL" -o "$TMP/sparkle.tar.xz"
tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP"
# Archive extracts bin/ at top level
cp "$TMP/bin/generate_keys" "$TMP/bin/sign_update" "$TMP/bin/generate_appcast" "$DEST/"
chmod +x "$DEST/"*
echo "OK tools in $DEST"
ls -la "$DEST"
