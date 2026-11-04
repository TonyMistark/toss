#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Toss.app"

VERSION="${VERSION:-${TOSS_VERSION:-}}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/macos/Info.plist")"
fi

if [[ ! -d "$APP" ]]; then
  echo "✗ 找不到 $APP，先运行 ./scripts/build_app.sh" >&2
  exit 1
fi

DMG="$ROOT/dist/toss-$VERSION.dmg"
mkdir -p "$ROOT/dist"
rm -f "$DMG"

hdiutil create \
  -volname "Toss" \
  -srcfolder "$APP" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

echo "✓ 已生成 $DMG"
echo "$DMG"
