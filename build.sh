#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=TopBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
ARCH=$(uname -m)
/usr/bin/xcrun --sdk macosx swiftc -target "${ARCH}-apple-macos14.0" -parse-as-library -O -o "$APP/Contents/MacOS/TopBar" Sources/*.swift
# Ad-hoc sign the whole bundle so macOS privacy prompts (calendar, camera, automation) can read Info.plist.
codesign --force --sign - "$APP"
echo "Built $APP — launching."
open "$APP"
