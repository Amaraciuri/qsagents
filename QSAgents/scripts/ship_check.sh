#!/usr/bin/env bash
# QS Agents — production ship check (local Release + optional notarize prep).
# Usage:
#   ./scripts/ship_check.sh              # build + smoke
#   NOTARIZE=1 ./scripts/ship_check.sh   # + Developer ID / notarytool checks (no upload unless UPLOAD=1)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DERIVED="${DERIVED:-build}"
SCHEME="${SCHEME:-QSAgents}"
CONFIG="${CONFIG:-Release}"
NOTARIZE="${NOTARIZE:-0}"
UPLOAD="${UPLOAD:-0}"

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  echo "==> DEVELOPER_DIR=$DEVELOPER_DIR"
fi

echo "==> Building ${CONFIG}..."
xcodebuild -project QSAgents.xcodeproj -scheme "$SCHEME" \
  -configuration "$CONFIG" -derivedDataPath "$DERIVED" build 2>&1 | tail -40

APP=$(find "$DERIVED/Build/Products/$CONFIG" -maxdepth 1 -name "*.app" | head -1)
if [[ -z "$APP" ]]; then
  echo "FAIL: no .app in $DERIVED/Build/Products/$CONFIG"
  exit 1
fi
echo "==> App: $APP"

PLIST="$APP/Contents/Info.plist"
echo "==> Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
echo "==> Build:   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || true)"
echo "==> Bundle:  $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"

echo "==> codesign (ad-hoc ok for local)..."
codesign -dv --verbose=2 "$APP" 2>&1 | head -20 || true

echo "==> Smoke: binary exists"
BIN="$APP/Contents/MacOS"
test -d "$BIN"
ls -la "$BIN"

if [[ "$NOTARIZE" == "1" ]]; then
  echo ""
  echo "==> Notarize prep (Fase 6 — richiede Apple Developer Program + Developer ID Application)"
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -F "Developer ID Application" | head -1 || true)
  if [[ -z "$IDENTITY" ]]; then
    echo "WARN: nessun certificato «Developer ID Application» nel keychain."
    echo "      Crea/installa da https://developer.apple.com/account/resources/certificates/"
    echo "      Poi: codesign --deep --force --options runtime --sign \"Developer ID Application: …\" \"$APP\""
  else
    echo "OK identity: $IDENTITY"
  fi

  if ! xcrun notarytool --help >/dev/null 2>&1; then
    echo "WARN: notarytool non disponibile (Xcode CLI tools)."
  else
    echo "OK notarytool presente."
    echo "Credenziali tipiche (una tantum):"
    echo "  xcrun notarytool store-credentials QSAgents-notary \\"
    echo "    --apple-id YOUR@EMAIL --team-id TEAMID --password app-specific-password"
  fi

  if [[ "$UPLOAD" == "1" ]]; then
    if [[ -z "$IDENTITY" ]]; then
      echo "FAIL: UPLOAD=1 richiede Developer ID Application"
      exit 1
    fi
    SIGN_ID=$(echo "$IDENTITY" | sed -E 's/.*"([^"]+)".*/\1/')
    ENTITLEMENTS="$ROOT/QSAgents/QSAgents.entitlements"
    echo "==> Re-sign with Developer ID + hardened runtime: $SIGN_ID"
    if [[ -f "$ENTITLEMENTS" ]]; then
      codesign --deep --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_ID" "$APP"
    else
      codesign --deep --force --options runtime --sign "$SIGN_ID" "$APP"
    fi
    codesign --verify --deep --strict --verbose=2 "$APP"
    spctl --assess --type execute --verbose=4 "$APP" 2>&1 || true

    ZIP="${TMPDIR:-/tmp}/QSAgents-notarize-$$.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "==> Submit notarization (profile QSAgents-notary)…"
    xcrun notarytool submit "$ZIP" --keychain-profile QSAgents-notary --wait
    echo "==> Staple…"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP" 2>&1 || true
    rm -f "$ZIP"
    echo "OK notarized + stapled: $APP"
    echo "Copia da distribuire: ditto -c -k --keepParent \"$APP\" ~/Desktop/QS-Agents-notarized.zip"
  else
    echo "Skip upload (set UPLOAD=1 dopo store-credentials per inviare ad Apple)."
  fi
fi

echo ""
echo "OK · local Release build ready."
echo "Distribuzione pubblica: NOTARIZE=1 UPLOAD=1 ./scripts/ship_check.sh (Developer Program)."
echo "Apri: open \"$APP\""
