#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Toss.app"
VERSION="${TOSS_VERSION:-}"

cd "$ROOT/macos"
# -disable-sandbox 仅关闭宏插件的编译器沙箱，避免部分受限环境下宏无法展开
swift build -c release -Xswiftc -disable-sandbox

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Toss" "$APP/Contents/MacOS/Toss"
cp "Info.plist" "$APP/Contents/Info.plist"

if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ -n "$VERSION" && "$ACTUAL_VERSION" != "$VERSION" ]]; then
  echo "✗ 版本号不一致：期望 $VERSION，产物是 $ACTUAL_VERSION" >&2
  exit 1
fi

# 本机使用，采用 ad-hoc 签名即可
/usr/bin/codesign --force --sign - "$APP" >/dev/null

echo "✓ 已生成 $APP (v$ACTUAL_VERSION)"
echo "  运行：open \"$APP\""
