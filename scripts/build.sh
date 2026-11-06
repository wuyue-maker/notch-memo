#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/module-cache .build/clang-cache .build/config .build/security build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build --configuration release -debug-info-format none --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" --scratch-path "$PWD/.build" -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/module-cache" --disable-sandbox
app_path="$PWD/build/刘海便签.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
binary_path="$(swift build --configuration release --show-bin-path --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" --scratch-path "$PWD/.build" --disable-sandbox)"
cp "$binary_path/NotchMemo" "$app_path/Contents/MacOS/NotchMemo.next"
mv -f "$app_path/Contents/MacOS/NotchMemo.next" "$app_path/Contents/MacOS/NotchMemo"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
xcrun swift -module-cache-path "$PWD/.build/module-cache" scripts/GenerateIcon.swift "$PWD/build/AppIcon.iconset"
python3 scripts/package-icon.py "$PWD/build/AppIcon.iconset" "$app_path/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_path"
print "已生成：$app_path"
