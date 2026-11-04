#!/bin/zsh
# Make a DMG to share: build/猪猪包-<version>.dmg with the app and an Applications shortcut.
#   ./package.sh                 ad-hoc signed (friends open it via right-click > Open the first time)
#   ZHUZHU_SIGN="Developer ID Application: Name (TEAMID)" ZHUZHU_NOTARY_PROFILE=profile ./package.sh
#                                signed + notarized (opens normally on any Mac)
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${ZHUZHU_VERSION:-$(cat VERSION)}"
./build.sh
APP="build/猪猪包.app"
DMG="build/猪猪包-$VERSION.dmg"
ICNS="Sources/ZhuzhuPet/Resources/icon/AppIcon.icns"
STAGE="build/dmg"
RW="build/dmg-rw.dmg"
/bin/rm -rf "$STAGE"
/bin/rm -f "$DMG" "$RW"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Room for the background, which is copied in after mounting.
hdiutil create -quiet -volname "猪猪包" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size 40m -ov "$RW"
if mount | grep -q " on /Volumes/猪猪包 "; then echo "先推出已经挂载的「猪猪包」磁盘再打包"; exit 1; fi
hdiutil attach -quiet -noverify -noautoopen "$RW"
VOL="/Volumes/猪猪包"
# Pixel-art install window (1x + 2x in one tiff). Copied onto the mounted disk (not into the staging
# folder) so Finder can find it when it saves the layout.
python3 tools/make_dmg_bg.py >/dev/null
mkdir -p "$VOL/.background"
tiffutil -cathidpicheck packaging/background.png packaging/background@2x.png -out "$VOL/.background/background.tiff" 2>/dev/null
# Finder writes the window layout itself: on macOS 26 it ignores layouts written by tools such as
# dmgbuild (it stores the background as a new 'pBB0' record). The background is 640 x 420; macOS 26
# always shows the path bar (68 pt with the title) and the status bar (28 pt), so the window is taller.
osascript <<'OSA'
tell application "Finder"
  tell disk "猪猪包"
    open
    delay 1
    close
    delay 1
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, 840, 656}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "猪猪包.app" of container window to {160, 208}
    set position of item "Applications" of container window to {480, 208}
    update without registering applications
    delay 2
    close
    open
    delay 2
    close
  end tell
end tell
OSA
sleep 2
# Disk icon last: Finder drops a .VolumeIcon.icns that is there while it rewrites the layout.
cp "$ICNS" "$VOL/.VolumeIcon.icns"
SetFile -a C "$VOL"
if ! grep -q pBB0 "$VOL/.DS_Store" 2>/dev/null && ! grep -q pBBk "$VOL/.DS_Store" 2>/dev/null; then
  echo "warning: Finder did not save the background picture"
fi
sync
hdiutil detach -quiet "$VOL"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
/bin/rm -f "$RW"
/bin/rm -rf "$STAGE"
if [[ -n "${ZHUZHU_SIGN:-}" ]]; then
  codesign --force --sign "$ZHUZHU_SIGN" "$DMG"
  if [[ -n "${ZHUZHU_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$ZHUZHU_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi
# The .dmg file itself shows the cat head in Finder (stored as a custom icon; some chat apps drop it).
osascript -l JavaScript -e 'function run(a){ObjC.import("AppKit");var i=$.NSImage.alloc.initWithContentsOfFile(a[0]);$.NSWorkspace.sharedWorkspace.setIconForFileOptions(i,a[1],0)}' "$ICNS" "$DMG" >/dev/null
echo "packaged $DMG"
