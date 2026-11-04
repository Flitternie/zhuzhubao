#!/bin/zsh
# Publish a new version to GitHub Releases; installed copies pick it up through Sparkle.
#   ./release.sh 1.2 "新动作：伸懒腰更舒展" "修好了晚上水碗变空的问题"
# Each argument after the version is one line of the release notes. This bumps VERSION, builds the
# app and the DMG, signs the update zip with the Sparkle key in the login keychain (account
# "zhuzhubao"), writes appcast.xml, commits, pushes and creates the release with the zip, the DMG
# and appcast.xml. The app reads releases/latest/download/appcast.xml, so the newest release wins.
set -euo pipefail
cd "$(dirname "$0")"
REPO="Flitternie/zhuzhubao"
NEW="${1:?usage: ./release.sh <version> [note ...]}"
shift
OLD="$(cat VERSION)"
if [[ "$(printf '%s\n%s\n' "$OLD" "$NEW" | sort -V | tail -1)" != "$NEW" || "$OLD" == "$NEW" ]] && gh release view "v$OLD" -R "$REPO" >/dev/null 2>&1; then
  echo "版本号要比已发布的 $OLD 大"; exit 1
fi
if gh release view "v$NEW" -R "$REPO" >/dev/null 2>&1; then echo "v$NEW 已经发布过了"; exit 1; fi

echo "$NEW" > VERSION
ZHUZHU_VERSION="$NEW" ./package.sh
APP="build/猪猪包.app"
# GitHub turns non-ASCII asset names into "default", so the uploaded files get ASCII names.
ZIP="build/Zhuzhubao-$NEW.zip"
DMG="build/Zhuzhubao-$NEW.dmg"
/bin/rm -f "$ZIP" "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
cp "build/猪猪包-$NEW.dmg" "$DMG"
SIG="$(vendor/sparkle/bin/sign_update --account zhuzhubao "$ZIP")"     # sparkle:edSignature="..." length="..."
BUILD_NO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

NOTES_HTML=""; NOTES_MD=""
for line in "$@"; do
  esc="${line//&/&amp;}"; esc="${esc//</&lt;}"; esc="${esc//>/&gt;}"
  NOTES_HTML+="<li>$esc</li>"; NOTES_MD+="- $line"$'\n'
done
[[ -z "$NOTES_HTML" ]] && NOTES_HTML="<li>小改进</li>" && NOTES_MD="- 小改进"
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>猪猪包</title>
    <item>
      <title>猪猪包 $NEW</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$BUILD_NO</sparkle:version>
      <sparkle:shortVersionString>$NEW</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<h3>猪猪包 $NEW</h3><ul>$NOTES_HTML</ul>]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$NEW/Zhuzhubao-$NEW.zip" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

cd ..
git add -A
git commit -q -m "Release $NEW" || true
git push -q origin HEAD
gh release create "v$NEW" -R "$REPO" --target "$(git rev-parse HEAD)" --title "猪猪包 $NEW" \
  --notes "$NOTES_MD"$'\n'"第一次安装：下载 Zhuzhubao-$NEW.dmg，把猪猪包拖进 Applications。已经装了的会自动收到更新。" \
  "app/$ZIP" "app/$DMG" app/build/appcast.xml
echo "released v$NEW"
