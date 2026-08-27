#!/bin/zsh
# 构建 FileDrawer.app：release 编译 + 打包 + 临时签名（ad-hoc）
# 用法：./make_app.sh [--universal]
#   --universal   同时编 arm64 + x86_64（分发给他人的 Intel / Apple Silicon Mac 用）
set -e

cd "$(dirname "$0")"

# 版本号唯一来源：发版只改这两行（关于面板、DMG 文件名都从产物里读）
VERSION="1.6.0"
BUILD="5"

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

# SPM 资源 bundle（本地化表等）：存在则随包分发，Bundle.module 会从主包 Resources 解析
RES_BUNDLE=".build/release/FileDrawer_FileDrawer.bundle"
if (( UNIVERSAL )) && [[ -d ".build/apple/Products/Release/FileDrawer_FileDrawer.bundle" ]]; then
  RES_BUNDLE=".build/apple/Products/Release/FileDrawer_FileDrawer.bundle"
fi
if [[ -d "$RES_BUNDLE" ]]; then
  cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
fi

# 主包本地化表：App Intents 面板（LocalizedStringResource）从主包解析，
# 把同一份表放进 .app 的 <lang>.lproj（UI 走 Bundle.module，互不冲突）
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/zh-Hans.lproj"
cp "Sources/FileDrawer/Resources/en.lproj/Localizable.strings" "$APP/Contents/Resources/en.lproj/"
cp "Sources/FileDrawer/Resources/zh-Hans.lproj/Localizable.strings" "$APP/Contents/Resources/zh-Hans.lproj/"

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
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.wangxiao.filedrawer</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>filedrawer</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" >/dev/null 2>&1
codesign --verify --strict "$APP"

echo "✅ 已生成 $APP（v$VERSION build $BUILD，$(lipo -archs "$APP/Contents/MacOS/FileDrawer" | tr -s ' ' )）"
echo "   安装到 /Applications：make install    分发 DMG：make dmg"
