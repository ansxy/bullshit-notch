# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

TopBar is a macOS (14+) menu-bar-less app that turns the MacBook camera notch into a boring.notch-style panel: live activities beside the notch (Claude agents "fire", music, charger, volume/brightness HUD) and, on hover, an expanded panel with Home (music, calendar/reminders, camera mirror), Shelf (file drop + AirDrop), and a Git / Work / Agents workspace. The menu bar icon only opens Settings.

## Build & run

```sh
./build.sh   # swiftc → TopBar.app, ad-hoc codesign, then `open` it
```

- Quit the running copy first (`pkill -f "TopBar.app/Contents/MacOS/TopBar"`), or `open` just re-activates the old one.
- Type-check only: `swiftc -parse-as-library -typecheck Sources/*.swift`
- `Package.swift` exists only so SourceKit-LSP resolves types across files; the real build is the `swiftc` one-liner in `build.sh`. There are no tests and no linter.
- Always run the **bundle**. A bare binary has no `Info.plist`, so the privacy usage strings (calendar, reminders, camera, Apple Events) are missing and those features fail. `build.sh` codesigns the bundle so TCC can read them.
- The build is ad-hoc signed: every rebuild looks like a new app to macOS, so permission grants (especially Accessibility for the HUD key tap) may need re-granting.
- Without Screen Recording permission you can't screenshot the notch. To check layout, render views off-screen with `ImageRenderer` in a scratch copy of the sources (strip `private` from the view structs and `@main` from `TopBarApp`). Unsupported views (ScrollView, drop targets, some button styles) render as yellow placeholders.

## Architecture

**Entry point.** `TopBarApp` has no visible scene (an empty `Settings {}` placeholder). All UI is owned by `NotchController` (the `NSApplicationDelegate`, in `Notch.swift`): the notch panel, the status-bar button, and global/local event monitors.

**Notch window mechanics.** The panel is a fixed, transparent 760×820 `NSPanel` centered under the notch at `mainMenu + 3`. The black notch shape is drawn by SwiftUI inside it, and its laid-out size is written back to `NotchModel.shapeSize`. `NotchController.track()` hit-tests the mouse against that size on every mouse-move/drag. It toggles `panel.ignoresMouseEvents`, so the menu bar under the transparent area stays clickable, and it opens or closes the notch. Changing the shape's size or padding changes the hover area automatically. File drags open the notch via the global `leftMouseDragged` monitor.

**State.** Feature stores are `@MainActor` `ObservableObject` singletons (`static let shared`): `AgentStore`, `NowPlaying`, `Battery`, `HUD`, `Agenda`, `Shelf`. `PullRequestStore` and `CustomStore` are statics on `TopBarApp`, injected as environment objects. Settings use the `Pref` keys and defaults in `NotchSettings.swift`, read with `@AppStorage`. C callbacks and notification handlers hop to the main actor with `MainActor.assumeIsolated`.

**Live activity priority.** `NotchView.activity` picks one: HUD > charger change > agents busy > music playing. Its `accent` colour tints the open panel's glow. The closed notch is deliberately plain black so it disappears into the physical notch.

**Data sources (all unofficial/undocumented, by necessity):**
- **GitHub**: shells out to `gh` in a login zsh (`GitHub.swift`), reusing the user's gh auth.
- **Claude agents** (`Agents.swift`):
  - Sessions come from `~/.claude/sessions/<pid>.json` (status busy/idle/waiting; dead pids filtered with `kill(pid, 0)`).
  - Tokens come from transcripts in `~/.claude/projects/<cwd with non-alphanumerics → "-">/<sessionId>.jsonl`. They're parsed incrementally by byte offset and deduped by `requestId`.
  - Subagents come from `<sessionId>/subagents/agent-<id>.{jsonl,meta.json}`. A subagent counts as finished when the parent transcript has `<task-id>ID</task-id>` or a non-"Async agent launched" `tool_result` for its `toolUseId`.
- **Music** (`NowPlaying.swift`): MediaRemote has been blocked for third-party apps since macOS 15.4. Instead, Spotify/Music distributed notifications trigger an `osascript` query. Only running players are queried, because `tell application` would launch them.
- **HUD** (`HUD.swift`): a CGEvent tap on `NX_SYSDEFINED` media keys (needs Accessibility). It swallows them and sets volume via CoreAudio and brightness via the private `DisplayServices` framework (`dlsym`).
- **Battery**: IOKit power-source notifications. **Calendar/Reminders**: EventKit, with access requested the first time Home is shown.

**`shell(path, args)`** (in `Agents.swift`) is the shared blocking process runner. Call it off the main thread.

**Leftovers.** `ContentView` (the old menu-bar dropdown) and `EdgePanel.swift` (an old right-edge slide-in panel) are no longer shown. `ContentView.swift` is still needed for the shared `Tab`, `PullRequestRow`, and `CustomSectionView`, which `Workspace.swift` reuses.

## Conventions

- `// ponytail:` comments mark deliberate shortcuts and name their limits or upgrade paths (e.g. single-screen setup at launch, decorative visualizer). Keep that style when taking a shortcut.
- The notch can't host sheets or alerts, so text input is inline (`TextField` rows). `KeyablePanel` exists so those fields can become key.
- Prefer adding a feature as its own `Sources/<Feature>.swift` with a `shared` store, and wire it into `NotchView`.
