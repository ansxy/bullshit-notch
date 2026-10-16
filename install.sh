#!/usr/bin/env bash
set -e

# ==============================================================================
# TopBar Installer for macOS (14+)
# https://github.com/ansxy/top-bar
# ==============================================================================

BOLD="\033[1m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
RESET="\033[0m"

echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║                   TOPBAR INSTALLER                ║"
echo "  ║        macOS Dynamic Notch & AI Agent Monitor     ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${RESET}"

# 1. OS check
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo -e "${RED}Error: TopBar is only supported on macOS.${RESET}"
    exit 1
fi

MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if (( MACOS_MAJOR < 14 )); then
    echo -e "${RED}Error: TopBar requires macOS 14.0 (Sonoma) or newer (found $(sw_vers -productVersion)).${RESET}"
    exit 1
fi

# Determine source location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
TEMP_DIR=""

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Check if we have source code locally or need to clone
if [[ -f "$SCRIPT_DIR/Package.swift" && -d "$SCRIPT_DIR/Sources" ]]; then
    SOURCE_DIR="$SCRIPT_DIR"
else
    echo -e "${CYAN}==>${RESET} Downloading latest TopBar source from GitHub..."
    TEMP_DIR=$(mktemp -d)
    git clone --depth 1 https://github.com/ansxy/top-bar.git "$TEMP_DIR"
    SOURCE_DIR="$TEMP_DIR"
fi

# 2. Determine installation destination
TARGET_APP="/Applications/TopBar.app"
USER_APP="$HOME/Applications/TopBar.app"

if [[ -w "/Applications" ]]; then
    INSTALL_DIR="/Applications"
    DEST_APP="$TARGET_APP"
else
    # Try user Applications directory
    mkdir -p "$HOME/Applications"
    INSTALL_DIR="$HOME/Applications"
    DEST_APP="$USER_APP"
fi

BUILD_APP="$SOURCE_DIR/TopBar.app"
rm -rf "$BUILD_APP"

build_from_source() {
    if ! /usr/bin/xcrun --sdk macosx --find swiftc &>/dev/null; then
        return 1
    fi
    echo -e "${CYAN}==>${RESET} Building TopBar from source (${BOLD}release mode${RESET})..."
    mkdir -p "$BUILD_APP/Contents/MacOS"
    mkdir -p "$BUILD_APP/Contents/Resources"
    cp "$SOURCE_DIR/Info.plist" "$BUILD_APP/Contents/Info.plist"

    if [[ ! -f "$SOURCE_DIR/Resources/AppIcon.icns" && -f "$SOURCE_DIR/scripts/generate_icon.swift" ]]; then
        echo -e "${CYAN}==>${RESET} Generating application icon..."
        (cd "$SOURCE_DIR" && /usr/bin/xcrun --sdk macosx swift scripts/generate_icon.swift && iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns && rm -rf AppIcon.iconset) || true
    fi

    if [[ -f "$SOURCE_DIR/Resources/AppIcon.icns" ]]; then
        cp "$SOURCE_DIR/Resources/AppIcon.icns" "$BUILD_APP/Contents/Resources/AppIcon.icns"
    fi

    local arch
    arch="$(uname -m)"
    local sdk_path
    sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    local dev_dir
    dev_dir="$(xcode-select -p 2>/dev/null || true)"

    local plugin_flags=()
    for p in \
        "$dev_dir/usr/lib/swift/host/plugins" \
        "$dev_dir/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
        "$dev_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins" \
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins" \
        "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins"; do
        if [[ -d "$p" ]]; then
            plugin_flags+=("-plugin-path" "$p")
        fi
    done

    /usr/bin/xcrun --sdk macosx swiftc \
        -target "${arch}-apple-macos14.0" \
        ${sdk_path:+-sdk "$sdk_path"} \
        "${plugin_flags[@]}" \
        -parse-as-library -O \
        -o "$BUILD_APP/Contents/MacOS/TopBar" \
        "$SOURCE_DIR"/Sources/*.swift
}

download_prebuilt() {
    echo -e "${CYAN}==>${RESET} Downloading pre-built TopBar.app from GitHub Releases..."
    local zip_tmp
    zip_tmp="$(mktemp -d)/TopBar.zip"
    if curl -fsSL "https://github.com/ansxy/top-bar/releases/latest/download/TopBar.zip" -o "$zip_tmp"; then
        rm -rf "$BUILD_APP"
        ditto -x -k "$zip_tmp" "$SOURCE_DIR"
        rm -f "$zip_tmp"
        [[ -d "$BUILD_APP" ]]
        return $?
    fi
    return 1
}

if ! build_from_source; then
    echo -e "${YELLOW}==>${RESET} Local Swift build failed or compiler unavailable; falling back to pre-built release..."
    if ! download_prebuilt; then
        echo -e "${RED}Error: Could not build from source or download pre-built release.${RESET}"
        echo -e "If you have Homebrew Swift installed, ensure Xcode Command Line Tools are selected:"
        echo -e "    ${BOLD}sudo xcode-select --switch /Library/Developer/CommandLineTools${RESET}"
        exit 1
    fi
fi

# Codesign ad-hoc
echo -e "${CYAN}==>${RESET} Signing application bundle..."
codesign --force --deep --sign - "$BUILD_APP" 2>/dev/null || true

# 4. Install into Applications
echo -e "${CYAN}==>${RESET} Installing to ${BOLD}$DEST_APP${RESET}..."

# Close existing instance if running
if pgrep -x "TopBar" &>/dev/null; then
    echo -e "${YELLOW}==>${RESET} Closing currently running TopBar..."
    pkill -x "TopBar" 2>/dev/null || true
    sleep 1
fi

rm -rf "$DEST_APP"
cp -R "$BUILD_APP" "$DEST_APP"

# Clear macOS quarantine attributes
xattr -cr "$DEST_APP" 2>/dev/null || true

# Re-sign bundle in destination
codesign --force --deep --sign - "$DEST_APP" 2>/dev/null || true

# 5. Launch TopBar
echo -e "${CYAN}==>${RESET} Launching TopBar..."
open "$DEST_APP"

echo ""
echo -e "${GREEN}${BOLD}✓ TopBar successfully installed and launched!${RESET}"
echo ""
echo -e "${BOLD}Tips & Permissions:${RESET}"
echo -e "  • ${BOLD}Open Notch:${RESET} Move your mouse to the top center of your screen (or swipe down)."
echo -e "  • ${BOLD}Settings:${RESET} Click the menu bar icon or open the Notch settings to configure tabs and limits."
echo -e "  • ${BOLD}Launch at Login:${RESET} Open TopBar Settings → System → Enable 'Launch at login'."
echo -e "  • ${BOLD}HUD Replacement:${RESET} Enable in Settings → System (requires macOS Accessibility permission)."
echo -e "  • ${BOLD}Calendar & Reminders:${RESET} Grant permission when prompted to see today's agenda."
echo -e "  • ${BOLD}GitHub PRs:${RESET} Ensure GitHub CLI (${CYAN}gh auth login${RESET}) is configured."
echo ""
echo -e "Enjoy TopBar! To uninstall in the future, run ${BOLD}./uninstall.sh${RESET} or remove ${BOLD}$DEST_APP${RESET}."
