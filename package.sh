#!/bin/zsh
set -e

# Ensure we run from project root
cd "$(dirname "$0")"

echo "==> Building TopBar for distribution..."

APP="TopBar.app"
DIST_DIR="dist"
DMG_NAME="TopBar.dmg"
ZIP_NAME="TopBar.zip"

# Clean previous build & dist artifacts
rm -rf "$APP" "$DIST_DIR"
mkdir -p "$DIST_DIR"

# 1. Compile and package the app bundle
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Compiling Swift sources (universal arm64 + x86_64, macOS 14.0+)..."
if /usr/bin/xcrun --sdk macosx swiftc -target arm64-apple-macos14.0 -parse-as-library -O -o "$APP/Contents/MacOS/TopBar-arm64" Sources/*.swift && \
   /usr/bin/xcrun --sdk macosx swiftc -target x86_64-apple-macos14.0 -parse-as-library -O -o "$APP/Contents/MacOS/TopBar-x86_64" Sources/*.swift; then
    lipo -create -output "$APP/Contents/MacOS/TopBar" "$APP/Contents/MacOS/TopBar-arm64" "$APP/Contents/MacOS/TopBar-x86_64"
    rm -f "$APP/Contents/MacOS/TopBar-arm64" "$APP/Contents/MacOS/TopBar-x86_64"
else
    ARCH=$(uname -m)
    /usr/bin/xcrun --sdk macosx swiftc -target "${ARCH}-apple-macos14.0" -parse-as-library -O -o "$APP/Contents/MacOS/TopBar" Sources/*.swift
fi

echo "==> Signing application bundle..."
codesign --force --deep --sign - "$APP"

# 2. Create ZIP archive
echo "==> Creating $ZIP_NAME..."
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST_DIR/$ZIP_NAME"

# 3. Create DMG with drag-and-drop /Applications symlink
echo "==> Creating $DMG_NAME..."
DMG_TEMP="dmg_temp"
rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP"
cp -R "$APP" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"

hdiutil create -volname "TopBar" \
    -srcfolder "$DMG_TEMP" \
    -ov -format UDZO \
    "$DIST_DIR/$DMG_NAME"

rm -rf "$DMG_TEMP"

echo ""
echo "=========================================="
echo " Packaging complete!"
echo " Artifacts created in ./$DIST_DIR:"
echo "   - $DIST_DIR/$DMG_NAME (Drag-and-drop installer)"
echo "   - $DIST_DIR/$ZIP_NAME (Portable zip archive)"
echo "=========================================="
