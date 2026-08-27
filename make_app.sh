#!/bin/zsh
# 构建 FileDrawer.app：release 编译 + 打包 + 临时签名
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

cd "$(dirname "$0")"

swift build -c release

APP="build/FileDrawer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/FileDrawer" "$APP/Contents/MacOS/FileDrawer"
cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
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

codesign --force -s - "$APP"

echo "✅ 已生成 $APP"
