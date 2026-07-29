#!/usr/bin/env bash
# deploy.sh — 下载最新 CI 产物并传到设备，等待 RootHidePatcher 安装
# 用法：bash scripts/deploy.sh
# 前提：设备 SSH 可连，越狱已激活
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$ROOT/.env" ]; then
  set -a; source "$ROOT/.env"; set +a
else
  echo "ERROR: .env not found" >&2; exit 1
fi
[ -z "$GH_TOKEN" ] && { echo "ERROR: GH_TOKEN not set" >&2; exit 1; }
[ -z "$DEVICE_IP" ]   && { echo "ERROR: DEVICE_IP not set" >&2; exit 1; }
[ -z "$DEVICE_PASS" ] && { echo "ERROR: DEVICE_PASS not set" >&2; exit 1; }

SSH="sshpass -p $DEVICE_PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 ${DEVICE_USER:-mobile}@$DEVICE_IP"
SCP="sshpass -p $DEVICE_PASS scp -o StrictHostKeyChecking=no -o ConnectTimeout=15"

# --- 1. Download latest CI artifact ---
echo "==> fetching latest CI artifact"
H="Authorization: Bearer $GH_TOKEN"
API="https://api.github.com/repos/$GH_REPO"
RUN=$(curl -s -H "$H" "$API/actions/runs?branch=master&per_page=1")
RID=$(echo "$RUN" | grep -o '"id": [0-9]*' | head -1 | grep -o '[0-9]*')
CONCL=$(echo "$RUN" | grep -o '"conclusion": "[^"]*"' | head -1)
if ! echo "$CONCL" | grep -q success; then
  echo "ERROR: latest CI run $RID is $CONCL (not success)" >&2; exit 1
fi
ART=$(curl -s -H "$H" "$API/actions/runs/$RID/artifacts" | grep -o '"id": [0-9]*' | head -1 | grep -o '[0-9]*')
DL_DIR="$ROOT/build/ci-download"
rm -rf "$DL_DIR" && mkdir -p "$DL_DIR"
curl -sL -H "$H" "$API/actions/artifacts/$ART/zip" -o "$DL_DIR/artifact.zip"
cd "$DL_DIR" && unzip -q artifact.zip
DEB=$(find "$DL_DIR" -name "*rootless*.deb" | head -1)
[ -z "$DEB" ] && { echo "ERROR: rootless deb not found in artifact" >&2; exit 1; }
echo "  deb: $DEB ($(du -h "$DEB" | cut -f1))"

# --- 2. Test device SSH ---
echo "==> testing SSH to $DEVICE_IP"
$SSH 'echo SSH_OK; ls -la /var/jb 2>/dev/null | head -1' || {
  echo "ERROR: cannot SSH to device. Check DEVICE_IP/DEVICE_PASS in .env" >&2; exit 1
}

# --- 3. Create inbox dir on device ---
# RootHidePatcher reads from /var/mobile/Library/Application Support/Containers/com.roothide.patcher/Documents/Inbox/
INBOX="/var/mobile/Library/Application Support/Containers/com.roothide.patcher/Documents/Inbox"
$SSH "mkdir -p \"$INBOX\"; echo dir_ok"

# --- 4. SCP the deb into RootHidePatcher inbox ---
DEBNAME="$(basename "$DEB")"
echo "==> uploading $DEBNAME to RootHidePatcher inbox"
$SCP "$DEB" "${DEVICE_USER:-mobile}@$DEVICE_IP:\"$INBOX/$DEBNAME\""
$SSH "ls -lh \"$INBOX/$DEBNAME\""

echo ""
echo "=== 完成 ==="
echo "deb 已传到设备的 RootHidePatcher 收件箱:"
echo "  $INBOX/$DEBNAME"
echo ""
echo "现在在手机上:"
echo "  1. 打开 RootHidePatcher app"
echo "  2. 在 Inbox 里找到 $DEBNAME"
echo "  3. 点击 → Patch & Install"
echo "  4. Respring 后监听生效"
