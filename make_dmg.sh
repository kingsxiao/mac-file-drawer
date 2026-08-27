#!/bin/zsh
# 生成可分发的 DMG：build/FileDrawer-<版本>-<架构>.dmg（含拖入 /Applications 的安装引导）
# 用法：./make_dmg.sh [--universal]
set -e

cd "$(dirname "$0")"

./make_app.sh "$@"
APP="build/FileDrawer.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/FileDrawer")"
if [[ "$ARCHS" == *" "* ]]; then
  ARCH="universal"
else
  ARCH="$ARCHS"
fi

STAGING="build/dmg-root"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/FileDrawer.app"   # ditto 保留签名与可执行位，cp 会丢
ln -sfn /Applications "$STAGING/Applications"

DMG="build/FileDrawer-$VERSION-$ARCH.dmg"
rm -f "$DMG"
echo "💿 打包 $DMG…"
hdiutil create -volname "FileDrawer" -srcfolder "$STAGING" -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

rm -rf "$STAGING"
echo "✅ 已生成 $DMG（$ARCH，v$VERSION）"
echo "   对方安装：双击挂载 → 把 FileDrawer 拖进 Applications；首次打开在访达里右键 → 打开"
