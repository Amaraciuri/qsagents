#!/usr/bin/env bash
# Sign a notarized .zip and write/update distribution/appcast.xml for Sparkle.
# Usage:
#   ./scripts/make_appcast.sh ~/Desktop/QS-Agents-notarized.zip 1.3.10 12
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="${1:?path to notarized .zip}"
VERSION="${2:?marketing version e.g. 1.3.10}"
BUILD="${3:?build number e.g. 12}"
SIGN="$ROOT/tools/sparkle/sign_update"
OUT="$ROOT/distribution/appcast.xml"
DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/Amaraciuri/qsagents/releases/download/v${VERSION}/QS-Agents.zip}"

if [[ ! -x "$SIGN" ]]; then
  echo "Missing $SIGN — run ./scripts/fetch_sparkle_tools.sh first"
  exit 1
fi
if [[ ! -f "$ZIP" ]]; then
  echo "FAIL: zip not found: $ZIP"
  exit 1
fi

mkdir -p "$ROOT/distribution"
LENGTH=$(stat -f%z "$ZIP")
# sign_update prints: sparkle:edSignature="…" length="…"
SIG_LINE=$("$SIGN" "$ZIP")
ED_SIG=$(echo "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
if [[ -z "$ED_SIG" ]]; then
  echo "FAIL: could not parse edSignature from: $SIG_LINE"
  exit 1
fi

PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')
TITLE="QS Agents ${VERSION}"

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>QS Agents</title>
    <link>https://github.com/Amaraciuri/qsagents</link>
    <description>Aggiornamenti QS Agents (Developer ID + notarized).</description>
    <language>it</language>
    <item>
      <title>${TITLE}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <ul>
          <li>Sparkle auto-update</li>
          <li>Production roadmap Fase 0–6 (notarize + resilienza + test)</li>
        </ul>
      ]]></description>
      <enclosure
        url="${DOWNLOAD_URL}"
        length="${LENGTH}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIG}" />
    </item>
  </channel>
</rss>
EOF

echo "OK wrote $OUT"
echo "Upload zip as release asset: $DOWNLOAD_URL"
echo "Push this appcast to main so SUFeedURL resolves."
