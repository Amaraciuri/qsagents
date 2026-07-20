# QS Agents (app tree)

Native macOS app sources, tests, scripts, and distribution assets.

**→ Full project README (install, architecture, privacy, ship):** [../README.md](../README.md)

```bash
cd QSAgents
xcodebuild -scheme QSAgents -configuration Debug -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' build
open "build/Build/Products/Debug/QS Agents.app"
```

Release / Sparkle: [`distribution/README.md`](./distribution/README.md)
