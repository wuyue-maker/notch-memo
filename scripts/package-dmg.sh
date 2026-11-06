#!/bin/zsh
# Build the drag-to-Applications disk image that ships the app and the guide.
set -euo pipefail
cd "${0:A:h:h}"

app="build/刘海便签.app"
guide="docs/安装与使用.pdf"

if [[ ! -d "$app" ]]; then
  print -u2 "缺少 $app，先运行 zsh scripts/build.sh"
  exit 1
fi
if [[ ! -f "$guide" ]]; then
  print -u2 "缺少 $guide，先运行 python3 scripts/make_guide.py 并导出 PDF"
  exit 1
fi

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
dmg="dist/刘海便签-$version.dmg"
stage=$(mktemp -d "${TMPDIR:-/tmp}/notchmemo-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT

mkdir -p dist
cp -R "$app" "$stage/"
cp "$guide" "$stage/安装与使用.pdf"
ln -s /Applications "$stage/应用程序"
# The volume is mounted with noowners; make the contents readable for whoever mounts it.
chmod 755 "$stage"
chmod -R a+rX "$stage"

# Make sure the app itself is signed before it is frozen into the image.
codesign --force --sign - "$stage/刘海便签.app"

rm -f "$dmg"
hdiutil create -volname "刘海便签 $version" -srcfolder "$stage" \
  -ov -format UDZO "$dmg" >/dev/null

print "已生成：$dmg"
shasum -a 256 "$dmg"
