#!/bin/zsh
set -e

# Ensure we run from project root
cd "$(dirname "$0")"

echo "==> Building BullshitNotch for distribution..."

APP="BullshitNotch.app"
DIST_DIR="dist"
DMG_NAME="BullshitNotch.dmg"
ZIP_NAME="BullshitNotch.zip"

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
if /usr/bin/xcrun --sdk macosx swiftc -module-cache-path /tmp/swift-module-cache -target arm64-apple-macos14.0 -parse-as-library -O -o "$APP/Contents/MacOS/BullshitNotch-arm64" Sources/*.swift && \
   /usr/bin/xcrun --sdk macosx swiftc -module-cache-path /tmp/swift-module-cache -target x86_64-apple-macos14.0 -parse-as-library -O -o "$APP/Contents/MacOS/BullshitNotch-x86_64" Sources/*.swift; then
    lipo -create -output "$APP/Contents/MacOS/BullshitNotch" "$APP/Contents/MacOS/BullshitNotch-arm64" "$APP/Contents/MacOS/BullshitNotch-x86_64"
    rm -f "$APP/Contents/MacOS/BullshitNotch-arm64" "$APP/Contents/MacOS/BullshitNotch-x86_64"
else
    ARCH=$(uname -m)
    /usr/bin/xcrun --sdk macosx swiftc -module-cache-path /tmp/swift-module-cache -target "${ARCH}-apple-macos14.0" -parse-as-library -O -o "$APP/Contents/MacOS/BullshitNotch" Sources/*.swift
fi

echo "==> Signing application bundle..."
codesign --force --deep --sign - "$APP"

# 2. Create ZIP archive
echo "==> Creating $ZIP_NAME..."
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST_DIR/$ZIP_NAME"

# 3. Create DMG with drag-and-drop /Applications symlink and Gatekeeper guide
echo "==> Creating $DMG_NAME..."
DMG_TEMP="dmg_temp"
rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP"
cp -R "$APP" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"

cat > "$DMG_TEMP/HOW TO OPEN (If Blocked by macOS).txt" << 'EOF'
====================================================================
  HOW TO OPEN BULLSHITNOTCH IF MACOS SAYS "CANNOT VERIFY" OR "MALWARE"
====================================================================

Because BullshitNotch is an open-source app distributed without a paid
Apple Developer ID certificate, macOS Gatekeeper flags downloaded
DMG files by default. BullshitNotch is 100% safe and open-source.

1. Drag "BullshitNotch.app" into the "Applications" folder.

2. Choose EITHER method below to open it the first time:

--------------------------------------------------------------------
METHOD A: Quick Terminal Command (Fastest)
--------------------------------------------------------------------
Open the Terminal app, paste this command, and press Enter:

    xattr -cr /Applications/BullshitNotch.app && open /Applications/BullshitNotch.app

--------------------------------------------------------------------
METHOD B: Using macOS System Settings (No Terminal)
--------------------------------------------------------------------
1. Try to open BullshitNotch from Applications, then click "Done" on the popup
   (do NOT click "Move to Trash").
2. Open macOS "System Settings" -> "Privacy & Security".
3. Scroll down to the "Security" section.
4. Click "Open Anyway" next to "BullshitNotch.app was blocked".

====================================================================
Source code: https://github.com/ansxy/bullshit-notch
EOF

hdiutil create -volname "BullshitNotch" \
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
