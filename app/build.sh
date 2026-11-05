#!/bin/zsh
# Build 猪猪包.app with swiftc (works with Command Line Tools only; SwiftPM needs full Xcode here).
set -euo pipefail
cd "$(dirname "$0")"
APP="build/猪猪包.app"
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
VERSION="${ZHUZHU_VERSION:-$(cat VERSION)}"
BUILD_NO="${ZHUZHU_BUILD:-$(date +%Y%m%d%H%M)}"
mkdir -p build/obj
# Universal binary: Apple silicon and Intel Macs.
for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos13 \
    -framework AppKit -framework QuartzCore -framework EventKit -framework ServiceManagement \
    -F vendor/sparkle -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/ZhuzhuPet/*.swift \
    -o "build/obj/ZhuzhuPet-$arch"
done
lipo -create build/obj/ZhuzhuPet-arm64 build/obj/ZhuzhuPet-x86_64 -output "$APP/Contents/MacOS/ZhuzhuPet"
cp -R Sources/ZhuzhuPet/Resources/sprites "$APP/Contents/Resources/"
cp -R Sources/ZhuzhuPet/Resources/fonts "$APP/Contents/Resources/"
cp Sources/ZhuzhuPet/Resources/icon/AppIcon.icns "$APP/Contents/Resources/"
# Sparkle (auto-update). ditto keeps the framework's symlinks.
mkdir -p "$APP/Contents/Frameworks"
ditto vendor/sparkle/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>猪猪包</string>
  <key>CFBundleDisplayName</key><string>猪猪包</string>
  <key>CFBundleIdentifier</key><string>local.zhuzhubao.pet</string>
  <key>CFBundleExecutable</key><string>ZhuzhuPet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NO</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>猪猪包</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>https://github.com/Flitternie/zhuzhubao/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>LmeQZYmSC3rUeW13avdwmOt4ninZAsmqdy6P3GnJFRw=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>local.zhuzhubao.pet.invite</string>
    <key>CFBundleURLSchemes</key><array><string>zhuzhubao</string></array>
  </dict></array>
  <key>NSCalendarsUsageDescription</key><string>猪猪包会在日程开始前提醒你。</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>猪猪包会读取日历里的日程，在开始前提醒你。只在本机读取，不会上传。</string>
</dict>
</plist>
PLIST
# Ad-hoc signature by default; set ZHUZHU_SIGN to a "Developer ID Application: ..." identity to sign for real.
if [[ -n "${ZHUZHU_SIGN:-}" ]]; then
  # Sparkle's helpers first (inside out), then the app.
  FW="$APP/Contents/Frameworks/Sparkle.framework"
  codesign -f -s "$ZHUZHU_SIGN" -o runtime --timestamp "$FW/Versions/B/XPCServices/Installer.xpc"
  codesign -f -s "$ZHUZHU_SIGN" -o runtime --timestamp --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
  codesign -f -s "$ZHUZHU_SIGN" -o runtime --timestamp "$FW/Versions/B/Autoupdate"
  codesign -f -s "$ZHUZHU_SIGN" -o runtime --timestamp "$FW/Versions/B/Updater.app"
  codesign -f -s "$ZHUZHU_SIGN" -o runtime --timestamp "$FW"
  codesign --force --options runtime --timestamp --sign "$ZHUZHU_SIGN" "$APP"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "built $APP"
# ./build.sh install: also put it in ~/Applications, a stable place for the login item.
if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Applications/猪猪包.app"
  mkdir -p "$HOME/Applications"
  pkill -f "猪猪包.app/Contents/MacOS/ZhuzhuPet" 2>/dev/null || true
  /bin/rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "installed $DEST"
fi
