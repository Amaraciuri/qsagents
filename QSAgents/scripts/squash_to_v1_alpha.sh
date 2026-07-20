#!/usr/bin/env bash
# Squash ALL git history to a single "v1 alpha" root commit and force-push.
# Run from repo root:  bash QSAgents/scripts/squash_to_v1_alpha.sh
# Requires: clean working tree; you explicitly want to rewrite origin/main.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "FAIL: working tree not clean. Commit or stash first."
  exit 1
fi

echo "==> Creating orphan commit from current tree…"
TREE=$(git rev-parse 'HEAD^{tree}')
COMMIT=$(git commit-tree "$TREE" -m "$(cat <<'EOF'
QS Agents v1 alpha

Local-first multi-agent command center for macOS.
Native SwiftUI app: real PTYs, orchestrator, tasks, swarm, git, knowledge,
Keychain BYOK, notarized Developer ID builds, Sparkle updates. MIT.
EOF
)")
echo "    $COMMIT"

echo "==> Pointing main at new root…"
git update-ref refs/heads/main "$COMMIT"
git symbolic-ref HEAD refs/heads/main
git reset --hard HEAD

echo "==> Tags…"
git tag -d v1.3.10 2>/dev/null || true
git tag -a v1.0.0-alpha -f -m "QS Agents v1 alpha"

echo "==> Force-push main + tag (rewrites remote history)…"
git push --force-with-lease origin main
git push origin :refs/tags/v1.3.10 2>/dev/null || true
git push origin v1.0.0-alpha --force

echo ""
echo "OK · history is 1 commit · tag v1.0.0-alpha"
git log --oneline
git rev-list --count HEAD
