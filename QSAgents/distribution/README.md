# Distribuzione QS Agents

## Feed Sparkle

- Appcast: `appcast.xml` (su `main`)
- `SUFeedURL` nell’app:  
  `https://raw.githubusercontent.com/Amaraciuri/qsagents/main/QSAgents/distribution/appcast.xml`

Repo **pubblico** (2026-07-20): Sparkle legge appcast e zip senza auth.

## Chiavi EdDSA

- **Pubblica** → `Info.plist` → `SUPublicEDKey` (già in repo)
- **Privata** → solo Keychain del maintainer (`generate_keys`); **mai** in git

## Release checklist

```bash
export DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer"
./scripts/fetch_sparkle_tools.sh   # una tantum
NOTARIZE=1 UPLOAD=1 ./scripts/ship_check.sh
ditto -c -k --keepParent \
  "build/Build/Products/Release/QS Agents.app" \
  ~/Desktop/QS-Agents.zip
./scripts/make_appcast.sh ~/Desktop/QS-Agents.zip 1.0.6 19
# Commit appcast.xml, push main
# Crea GitHub Release v1.0.6 e carica QS-Agents.zip (stesso nome dell’URL in appcast)
```
