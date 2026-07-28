#!/bin/bash
# TidyApp 构建脚本(§11.2):SwiftPM 编译 → 手工组装 .app → 固定证书签名
# 用法:./build.sh [--run]
set -euo pipefail
cd "$(dirname "$0")"

SIGN_IDENTITY="TidyApp Dev"   # setup-signing.sh 创建的固定自签名证书
APP_NAME="TidyApp"
DIST="dist"
APP="${DIST}/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release 2>&1 | tail -5

BIN=".build/release/${APP_NAME}"
[ -f "$BIN" ] || { echo "构建产物不存在:$BIN"; exit 1; }

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 签名:优先固定证书(TCC 授权跨 rebuild 保留);无则 ad-hoc 并警告
if security find-identity -p codesigning -v 2>/dev/null | grep -q "${SIGN_IDENTITY}"; then
    echo "==> codesign(固定证书:${SIGN_IDENTITY})"
    codesign --force --deep --sign "${SIGN_IDENTITY}" "$APP"
else
    echo "⚠️  未找到固定签名证书「${SIGN_IDENTITY}」,使用 ad-hoc 签名。"
    echo "    每次 rebuild 后系统授权(自动化等)可能需要重新给。建议先运行 ./setup-signing.sh"
    codesign --force --deep --sign - "$APP"
fi

echo "==> 完成:$APP"

if [ "${1:-}" = "--run" ]; then
    # 替换正在运行的实例
    pkill -x "${APP_NAME}" 2>/dev/null || true
    sleep 0.3
    open "$APP"
    echo "==> 已启动(看屏幕顶部中央的灵动岛)"
fi
