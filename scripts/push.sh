#!/usr/bin/env bash
# push.sh — 推代码到 GitHub 触发 CI 编译
# 用法：bash scripts/push.sh [提交消息]
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 读取 .env
if [ -f "$ROOT/.env" ]; then
  set -a; source "$ROOT/.env"; set +a
else
  echo "ERROR: .env not found. Copy .env.example to .env and fill in values." >&2; exit 1
fi

[ -z "$GH_TOKEN" ] && { echo "ERROR: GH_TOKEN not set in .env" >&2; exit 1; }

MSG="${1:-"rebuild $(date +%Y-%m-%d)"}"
cd "$ROOT"

echo "==> staging all changes"
git add -A

if git diff --cached --quiet; then
  echo "==> nothing to commit, triggering CI with empty commit"
  git commit --allow-empty -m "$MSG"
else
  git commit -m "$MSG"
fi

echo "==> pushing to https://github.com/$GH_REPO"
git push "https://x-access-token:${GH_TOKEN}@github.com/${GH_REPO}.git" master
echo "==> done — check CI at https://github.com/$GH_REPO/actions"
