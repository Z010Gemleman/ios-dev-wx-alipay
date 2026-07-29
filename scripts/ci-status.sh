#!/usr/bin/env bash
# ci-status.sh — 查询 GitHub Actions 最新编译状态，可选下载产物
# 用法：bash scripts/ci-status.sh [--download]
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$ROOT/.env" ]; then
  set -a; source "$ROOT/.env"; set +a
else
  echo "ERROR: .env not found" >&2; exit 1
fi
[ -z "$GH_TOKEN" ] && { echo "ERROR: GH_TOKEN not set" >&2; exit 1; }

H="Authorization: Bearer $GH_TOKEN"
API="https://api.github.com/repos/$GH_REPO"

echo "==> querying latest run for $GH_REPO"
RUN=$(curl -s -H "$H" "$API/actions/runs?branch=master&per_page=1")
RID=$(echo "$RUN" | grep -o '"id": [0-9]*' | head -1 | grep -o '[0-9]*')
STATUS=$(echo "$RUN" | grep -o '"status": "[^"]*"' | head -1)
CONCL=$(echo "$RUN" | grep -o '"conclusion": "[^"]*"' | head -1)
SHA=$(echo "$RUN" | grep -o '"head_sha": "[^"]*"' | head -1 | cut -c15-22)

echo "  run id : $RID"
echo "  status : $STATUS"
echo "  result : $CONCL"
echo "  commit : $SHA"
echo "  url    : https://github.com/$GH_REPO/actions/runs/$RID"

if [ "$1" = "--download" ] && echo "$CONCL" | grep -q success; then
  ART=$(curl -s -H "$H" "$API/actions/runs/$RID/artifacts" | grep -o '"id": [0-9]*' | head -1 | grep -o '[0-9]*')
  echo "==> downloading artifact $ART"
  OUT="$ROOT/build/ci-download"
  rm -rf "$OUT" && mkdir -p "$OUT"
  curl -sL -H "$H" "$API/actions/artifacts/$ART/zip" -o "$OUT/artifact.zip"
  cd "$OUT" && unzip -q artifact.zip
  echo "==> downloaded to $OUT/"
  ls -lh "$OUT"/**/*.{deb,ipa} 2>/dev/null || ls -lh "$OUT"
fi
