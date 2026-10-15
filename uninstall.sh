#!/usr/bin/env bash
set -e

# ==============================================================================
# TopBar Uninstaller for macOS
# ==============================================================================

BOLD="\033[1m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
RESET="\033[0m"

echo -e "${BOLD}${CYAN}TopBar Uninstaller${RESET}"

# 1. Close running TopBar
if pgrep -x "TopBar" &>/dev/null; then
    echo -e "${YELLOW}==>${RESET} Closing TopBar..."
    pkill -x "TopBar" 2>/dev/null || true
    sleep 1
fi

# 2. Remove application bundles
REMOVED=0

if [[ -d "/Applications/TopBar.app" ]]; then
    echo -e "${YELLOW}==>${RESET} Removing /Applications/TopBar.app..."
    rm -rf "/Applications/TopBar.app"
    REMOVED=1
fi

if [[ -d "$HOME/Applications/TopBar.app" ]]; then
    echo -e "${YELLOW}==>${RESET} Removing $HOME/Applications/TopBar.app..."
    rm -rf "$HOME/Applications/TopBar.app"
    REMOVED=1
fi

# 3. Clean up preferences if requested
echo -e "${CYAN}==>${RESET} Cleaning up user preferences (id.rey.topbar)..."
defaults delete id.rey.topbar 2>/dev/null || true

if (( REMOVED == 1 )); then
    echo -e "${GREEN}${BOLD}✓ TopBar has been completely removed from your system.${RESET}"
else
    echo -e "${YELLOW}No TopBar installation was found in /Applications or ~/Applications.${RESET}"
fi
