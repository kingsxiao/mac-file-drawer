#!/bin/zsh
# 构建 FileDrawer.app：release 编译 + 打包 + 临时签名（ad-hoc）
# 用法：./make_app.sh [--universal]
#   --universal   同时编 arm64 + x86_64（分发给他人的 Intel / Apple Silicon Mac 用）
set -e

cd "$(dirname "$0")"

# 版本号唯一来源：发版只改这两行（关于面板、DMG 文件名都从产物里读）
VERSION="1.2.0"
BUILD="3"

# 工具链探测：已设置 DEVELOPER_DIR 则尊重；否则优先完整版 Xcode；都没有就用 xcode-select 当前选择（纯 CLT 也能编译本项目）
if [[ -z "$DEVELOPER_DIR" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

UNIVERSAL=0
BUILD_ARGS=()
if [[ "$1" == "--universal" ]]; then
  UNIVERSAL=1
  BUILD_ARGS=(--arch arm64 --arch x86_64)
  echo "🏗  构建 Universal 二进制（arm64 + x86_64）"
elif [[ -n "$1" ]]; then
  echo "用法：$0 [--universal]" >&2
  exit 1
fi

swift build -c release "${BUILD_ARGS[@]}"

# 多架构时 SwiftPM 把 lipo 合成的 fat binary 放在 .build/apple/Products/Release，单架构在 .build/release
BIN=".build/release/FileDrawer"
if (( UNIVERSAL )) && [[ -f ".build/apple/Products/Release/FileDrawer" ]]; then
  BIN=".build/apple/Products/Release/FileDrawer"
fi

APP="build/FileDrawer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/FileDrawer"
cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>FileDrawer</string>
    <key>CFBundleIdentifier</key>
    <string>com.wangxiao.filedrawer</string>
    <key>CFBundleName</key>
    <string>FileDrawer</string>
    <key>CFBundleDisplayName</key>
    <string>文件抽屉</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" >/dev/null 2>&1
codesign --verify --strict "$APP"

echo "✅ 已生成 $APP（v$VERSION build $BUILD，$(lipo -archs "$APP/Contents/MacOS/FileDrawer" | tr -s ' ' )）"
echo "   安装到 /Applications：make install    分发 DMG：make dmg"
