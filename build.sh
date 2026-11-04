#!/bin/zsh
# 构建 Baud.app：./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP=Baud.app
ICON_WORK=.build/icon

swift build -c release --product Baud

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/stickers"
cp .build/release/Baud "$APP/Contents/MacOS/Baud"
cp design/stickers/*.png "$APP/Contents/Resources/stickers/"

if [[ ! -f .build/AppIcon.icns || design/stickers/r3c1.png -nt .build/AppIcon.icns ]]; then
    rm -rf "$ICON_WORK"
    mkdir -p "$ICON_WORK/AppIcon.iconset"
    swift Scripts/make_icon.swift design/stickers/r3c1.png "$ICON_WORK/icon.png"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON_WORK/icon.png" --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double "$ICON_WORK/icon.png" --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Baud</string>
    <key>CFBundleDisplayName</key><string>Baud</string>
    <key>CFBundleIdentifier</key><string>local.summer.baud</string>
    <key>CFBundleExecutable</key><string>Baud</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP"
echo "完成：$(pwd)/$APP"
