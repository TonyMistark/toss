#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-${TOSS_VERSION:-}}"
DMG="${DMG_PATH:-$ROOT/dist/toss-$VERSION.dmg}"

if [[ -z "$VERSION" ]]; then
  echo "✗ 缺少 VERSION（例如 VERSION=0.1.0）" >&2
  exit 1
fi
if [[ ! -f "$DMG" ]]; then
  echo "✗ 找不到安装包：$DMG" >&2
  exit 1
fi

MOUNT="/tmp/toss-smoke-mount-$VERSION"
SMOKE_HOME="/tmp/toss-smoke-home-$VERSION"
LOG="/tmp/toss-smoke-$VERSION.log"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
}
trap cleanup EXIT

hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
rm -rf "$MOUNT" "$SMOKE_HOME"
mkdir -p "$SMOKE_HOME"

echo "→ 挂载 $DMG"
hdiutil attach "$DMG" -nobrowse -mountpoint "$MOUNT" >/dev/null

APP="$MOUNT/Toss.app"
if [[ ! -x "$APP/Contents/MacOS/Toss" ]]; then
  echo "✗ 安装包里没有可执行文件" >&2
  exit 1
fi

INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$INSTALLED_VERSION" != "$VERSION" ]]; then
  echo "✗ 版本不一致：Info.plist=$INSTALLED_VERSION，期望=$VERSION" >&2
  exit 1
fi

echo "→ 隔离启动（CFFIXED_USER_HOME=${SMOKE_HOME}）"
env CFFIXED_USER_HOME="$SMOKE_HOME" "$APP/Contents/MacOS/Toss" >"$LOG" 2>&1 &
APP_PID=$!

sleep 8
if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "✗ 应用启动后退出，日志：$LOG" >&2
  tail -n 20 "$LOG" >&2 || true
  exit 1
fi

CRASH_DIR="$SMOKE_HOME/Library/Application Support/toss/crashes"
BREADCRUMBS="$CRASH_DIR/breadcrumbs.log"
if [[ ! -f "$BREADCRUMBS" ]]; then
  echo "✗ 没有生成轨迹本：$BREADCRUMBS" >&2
  exit 1
fi

FIRST_LINE="$(head -n 1 "$BREADCRUMBS")"
if [[ "$FIRST_LINE" != *"launch $VERSION"* ]]; then
  echo "✗ 轨迹本首行不符合预期：$FIRST_LINE" >&2
  exit 1
fi

REPORTS="$(find "$CRASH_DIR" -maxdepth 1 -type f \
  ! -name 'breadcrumbs.log' \
  ! -name '.inflight-*' \
  ! -name 'seen.json' 2>/dev/null || true)"
if [[ -n "$REPORTS" ]]; then
  echo "✗ 首次启动不应有崩溃报告：" >&2
  echo "$REPORTS" >&2
  exit 1
fi

kill -TERM "$APP_PID"
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

echo "✓ 冒烟通过：v$VERSION 可启动、窗口进程存活、轨迹正常、无崩溃报告"
