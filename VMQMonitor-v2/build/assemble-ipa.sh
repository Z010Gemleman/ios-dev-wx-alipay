#!/usr/bin/env bash
# assemble-ipa.sh — VMQ Monitor V2 单 IPA 组装脚本（设计文档 §19）
#
# 流程：
#   1. 用标准 theos 构建 rootless runtime .deb
#   2. 用 roothide theos 构建 roothide runtime .deb
#   3. 构建 Root Helper (vmqhelper)
#   4. 构建 App bundle
#   5. 组装 Payload/VMQMonitor.app：内嵌 vmqhelper 与两个 .deb
#   6. fakesign（ldid）App 与 helper，打成 VMQMonitor-v2.ipa
#   7. 生成 SHA-256
#
# 用法：  bash build/assemble-ipa.sh
#
# 环境变量（可覆盖）：
#   THEOS_STD       标准 theos 路径（默认 /root/theos）
#   THEOS_ROOTHIDE  roothide theos 路径（默认 /root/theos_roothide）

set -euo pipefail

# ---- 路径 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
THEOS_STD="${THEOS_STD:-/root/theos}"
THEOS_ROOTHIDE="${THEOS_ROOTHIDE:-/root/theos_roothide}"

OUT_DIR="$PROJ_DIR/build/out"
STAGE_DIR="$PROJ_DIR/build/stage"
APP_NAME="VMQMonitor"
IPA_NAME="VMQMonitor-v2.ipa"

RUNTIME_PKG="com.z010genleman.vmqmonitor.v2.runtime"
DEB_ROOTLESS="$RUNTIME_PKG-rootless.deb"
DEB_ROOTHIDE="$RUNTIME_PKG-roothide.deb"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 前置检查 ----
[ -d "$THEOS_STD" ]      || fail "标准 theos 不存在: $THEOS_STD"
[ -d "$THEOS_ROOTHIDE" ] || fail "roothide theos 不存在: $THEOS_ROOTHIDE"
LDID="$THEOS_STD/bin/ldid"
[ -x "$LDID" ] || LDID="$(command -v ldid || true)"
[ -n "$LDID" ] || fail "找不到 ldid"

rm -rf "$OUT_DIR" "$STAGE_DIR"
mkdir -p "$OUT_DIR" "$STAGE_DIR"

# ---- 1. rootless runtime deb ----
log "构建 rootless runtime deb"
make -C "$PROJ_DIR/runtime" clean >/dev/null 2>&1 || true
rm -rf "$PROJ_DIR/runtime/.theos" "$PROJ_DIR/runtime/packages"
make -C "$PROJ_DIR/runtime" package FINALPACKAGE=1 \
    THEOS="$THEOS_STD" THEOS_PACKAGE_SCHEME=rootless
cp "$PROJ_DIR/runtime/packages/"*.deb "$STAGE_DIR/$DEB_ROOTLESS"

# ---- 2. roothide runtime deb ----
log "构建 roothide runtime deb"
make -C "$PROJ_DIR/runtime" clean >/dev/null 2>&1 || true
rm -rf "$PROJ_DIR/runtime/.theos" "$PROJ_DIR/runtime/packages"
make -C "$PROJ_DIR/runtime" package FINALPACKAGE=1 \
    THEOS="$THEOS_ROOTHIDE" THEOS_PACKAGE_SCHEME=roothide
cp "$PROJ_DIR/runtime/packages/"*.deb "$STAGE_DIR/$DEB_ROOTHIDE"

# ---- 3. Root Helper ----
log "构建 Root Helper"
make -C "$PROJ_DIR/helper" clean >/dev/null 2>&1 || true
rm -rf "$PROJ_DIR/helper/.theos"
make -C "$PROJ_DIR/helper" FINALPACKAGE=1 THEOS="$THEOS_STD"
HELPER_BIN="$PROJ_DIR/helper/.theos/obj/vmqhelper"
[ -f "$HELPER_BIN" ] || HELPER_BIN="$(find "$PROJ_DIR/helper/.theos/obj" -maxdepth 1 -name vmqhelper -type f | head -n1)"
[ -f "$HELPER_BIN" ] || fail "helper 二进制未找到"

# ---- 4. App bundle ----
log "构建 App bundle"
make -C "$PROJ_DIR/app" clean >/dev/null 2>&1 || true
rm -rf "$PROJ_DIR/app/.theos"
# make stage：包含 Info.plist 等资源文件（make 只产出二进制，stage 才是完整 bundle）。
make -C "$PROJ_DIR/app" stage FINALPACKAGE=1 THEOS="$THEOS_STD"
# staged bundle 路径（Theos 标准结构）
APP_BUNDLE="$PROJ_DIR/app/.theos/_/Applications/$APP_NAME.app"
if [ ! -d "$APP_BUNDLE" ]; then
    # 兜底：从 obj 里找合并后的 bundle
    APP_BUNDLE="$(find "$PROJ_DIR/app/.theos/obj" -maxdepth 1 -name "$APP_NAME.app" -type d | head -n1)"
fi
[ -d "$APP_BUNDLE" ] || fail "App bundle 未找到"

# Info.plist 安全网：若 Theos 没有把它放进 bundle，手动补入。
# （某些 Theos 配置下 RESOURCE_FILES 在 stage 之前不复制）
if [ ! -f "$APP_BUNDLE/Info.plist" ] && [ -f "$PROJ_DIR/app/Info.plist" ]; then
    cp "$PROJ_DIR/app/Info.plist" "$APP_BUNDLE/Info.plist"
fi
[ -f "$APP_BUNDLE/Info.plist" ] || fail "Info.plist 缺失，IPA 无法安装"

# ---- 5. 组装 Payload ----
log "组装 Payload/$APP_NAME.app"
PAYLOAD="$STAGE_DIR/Payload"
mkdir -p "$PAYLOAD"
cp -a "$APP_BUNDLE" "$PAYLOAD/"
DEST_APP="$PAYLOAD/$APP_NAME.app"

# helper 放进 bundle 根；两个 deb 放进 Payloads/（helper 从这里读取）
cp "$HELPER_BIN" "$DEST_APP/vmqhelper"
chmod 0755 "$DEST_APP/vmqhelper"
mkdir -p "$DEST_APP/Payloads"
cp "$STAGE_DIR/$DEB_ROOTLESS" "$DEST_APP/Payloads/"
cp "$STAGE_DIR/$DEB_ROOTHIDE" "$DEST_APP/Payloads/"

# ---- 6. fakesign ----
log "fakesign App 与 helper"
"$LDID" -S"$PROJ_DIR/app/entitlements/VMQMonitor.plist" "$DEST_APP/$APP_NAME"
"$LDID" -S"$PROJ_DIR/helper/entitlements/vmqhelper.plist" "$DEST_APP/vmqhelper"

# ---- 7. 打包 IPA + SHA-256 ----
log "打包 $IPA_NAME"
( cd "$STAGE_DIR" && zip -qr "$OUT_DIR/$IPA_NAME" Payload )
( cd "$OUT_DIR" && sha256sum "$IPA_NAME" > "$IPA_NAME.sha256" )

log "完成"
echo "  IPA:    $OUT_DIR/$IPA_NAME"
echo "  SHA256: $(cat "$OUT_DIR/$IPA_NAME.sha256")"
