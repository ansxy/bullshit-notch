#!/usr/bin/env bash
set -e

# ==============================================================================
# BullshitNotch Uninstaller for macOS
# ==============================================================================

BOLD="\033[1m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
RESET="\033[0m"

echo -e "${BOLD}${CYAN}BullshitNotch Uninstaller${RESET}"

# 1. Close running BullshitNotch
if pgrep -x "BullshitNotch" &>/dev/null || pgrep -x "TopBar" &>/dev/null; then
    echo -e "${YELLOW}==>${RESET} Closing BullshitNotch..."
    pkill -x "BullshitNotch" 2>/dev/null || true
    pkill -x "TopBar" 2>/dev/null || true
    sleep 1
fi

# 2. Remove application bundles
REMOVED=0

for app_path in "/Applications/BullshitNotch.app" "$HOME/Applications/BullshitNotch.app" "/Applications/TopBar.app" "$HOME/Applications/TopBar.app"; do
    if [[ -d "$app_path" ]]; then
        echo -e "${YELLOW}==>${RESET} Removing $app_path..."
        rm -rf "$app_path"
        REMOVED=1
    fi
done

# 3. Clean up preferences if requested
echo -e "${CYAN}==>${RESET} Cleaning up user preferences (com.ansxy.bullshitnotch)..."
defaults delete com.ansxy.bullshitnotch 2>/dev/null || true
defaults delete com.ansxy.topbar 2>/dev/null || true
defaults delete id.rey.topbar 2>/dev/null || true

if (( REMOVED == 1 )); then
    echo -e "${GREEN}${BOLD}✓ BullshitNotch has been completely removed from your system.${RESET}"
else
    echo -e "${YELLOW}No BullshitNotch installation was found in /Applications or ~/Applications.${RESET}"
fi
