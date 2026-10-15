# 🏔️ TopBar

[![macOS](https://img.shields.io/badge/macOS-14.0%2B%20%28Sonoma%20%2F%20Sequoia%29-blue?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.10%20%2F%206.0-orange?logo=swift)](https://swift.org)
[![Platform](https://img.shields.io/badge/Architecture-Apple%20Silicon%20%26%20Intel-black)](https://github.com/ansxy/top-bar)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**A living dynamic notch companion and multi-agent AI mission control for macOS.**

TopBar turns your MacBook notch into a functional dynamic island. It displays live activities beside the physical notch (Claude and Antigravity AI agents, Spotify/Apple Music, charger status, and volume/brightness HUD), and organically expands into a full workspace panel on hover or downward swipe.

---

## ✨ Features

- 🌊 **Organic Water-Drop Notch**: Slime and water-drop meniscus Bézier curve that clings naturally to the display bezel with straight lateral edges and fluid corners.
- 🤖 **AI Agent Mission Control**:
  - Live activity monitoring for **Claude Code** and **Antigravity** harnesses.
  - Animated flame indicator when agents are actively computing.
  - Side-by-side view showing currently running agent tasks alongside **Daily & Weekly token usage meters and limits**.
  - Subagent tree inspection and token breakdown.
- 🎵 **Now Playing & Music Controls**:
  - Real-time album artwork, audio visualizer wave, playback controls, and track scrubber for Apple Music and Spotify.
- 📦 **File Shelf & AirDrop**:
  - Instant drag-and-drop staging zone at the top of your screen to hold files while switching spaces.
  - One-click AirDrop trigger.
- 📅 **Agenda & Reminders**:
  - View today's meetings, countdowns to next events, and check off Reminders inline.
- 🪞 **Quick Mirror**:
  - Discreet selfie camera preview to quickly check your framing before video calls.
- 🎛️ **Modern System HUD**:
  - Replaces the bulky macOS volume and brightness popup with an elegant, non-intrusive notch overlay.
- ⚙️ **Categorized Modular Settings**:
  - Organized tabs (`Notch`, `Activities`, `Tabs`, `Menus`, `System`) to toggle individual menus and configure notch dimensions.
  - Native **Launch at Login** support.

---

## 🚀 Quick Install

### Option 1: One-Line Terminal Install (Recommended)

Run this one-liner in your terminal to build and install TopBar into `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/ansxy/top-bar/main/install.sh | bash
```

Or clone the repository and run the installer:

```bash
git clone https://github.com/ansxy/top-bar.git
cd top-bar
./install.sh
```

### Option 2: Pre-Built DMG

1. Download `TopBar.dmg` from the [Latest Release](https://github.com/ansxy/top-bar/releases).
2. Open `TopBar.dmg` and drag `TopBar.app` into **Applications**.
3. Launch **TopBar** from Launchpad, Spotlight, or Applications.

### Option 3: Local Development Build

```bash
git clone https://github.com/ansxy/top-bar.git
cd top-bar
./build.sh
```

---

## 🕹️ How to Use

- **Open the Notch**: Move your cursor over the notch at the top center of your display, or click / swipe down.
- **Drag & Drop Files**: Drag any file to the notch from Finder; the notch opens automatically and reveals the Shelf.
- **Settings**: Click the TopBar menu bar icon or open the Notch settings to configure tabs, limits, and behavior.
- **Start at Boot**: Open TopBar Settings → **System** → Turn on **Launch at login**.

---

## ⚙️ Requirements & Permissions

- **OS**: macOS 14.0 (Sonoma) or macOS 15+ (Sequoia).
- **Hardware**: MacBook Pro / Air (with or without physical notch) or any Mac with an external monitor.
- **Compiler**: Xcode Command Line Tools (`xcode-select --install`) if building from source.

### Permissions:
- **Accessibility**: Required only if you enable *Replace volume and brightness HUD* in Settings → System.
- **Calendars & Reminders**: Prompted when first viewing the Agenda widget.
- **Camera**: Prompted when viewing the Mirror preview.
- **Apple Events (Automation)**: Prompted to query track details from Spotify or Apple Music.
- **GitHub CLI**: Install and authenticate `gh` (`gh auth login`) to view pull requests in the Workspace tab.

---

## 🗑️ Uninstallation

Run the uninstaller script or delete the application:

```bash
./uninstall.sh
```

Or manually delete `/Applications/TopBar.app` and run:

```bash
defaults delete id.rey.topbar
```

---

## 📄 License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.
