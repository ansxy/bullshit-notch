# BullshitNotch for Windows (Pure Rust `egui` + `wgpu`) — Design Spec

**Date:** 2026-10-20
**Target Platform:** Windows 10 (1903+) & Windows 11 (`x86_64-pc-windows-msvc` / `aarch64-pc-windows-msvc`)
**Language & Stack:** Pure Rust (2021 edition), `eframe` / `egui` + `wgpu`, `windows` crate (Win32 + WinRT APIs), `tray-icon`, `serde`, `tokio` (lightweight async worker runtime).

---

## 1. Intent & Why

Port **BullshitNotch** (`TopBar`) from macOS (SwiftUI/AppKit) to Windows as a native, ultra-lightweight, single-binary Rust desktop utility (~15–30 MB RAM footprint, 0% CPU when idle).

On Windows monitors (which usually lack a physical camera housing cutout), BullshitNotch renders a sleek, flared black pill ("virtual notch") flush with the top-center bezel of the primary display. In its closed state, it displays live wing badges (Media artwork + visualizer, Claude/Antigravity agent animations, Battery/Charger state, Volume/Brightness HUD) and passes mouse clicks through transparent regions (`WS_EX_TRANSPARENT` + `WS_EX_LAYERED`) so title bars and browser tabs underneath remain clickable. Hovering over the pill (or dragging a file onto it) smoothly springs open the expanded workspace (`Home`, `Shelf`, and `Git / Work / Agents / Containers`).

---

## 2. Goals, Non-Goals, and Anti-Goals

### Goals
- **Ultra-low resource usage:** Under 35 MB RAM idle, reactive repainting (`ctx.request_repaint_after(...)` only when animating or polling), and incremental file parsing for Claude/Antigravity transcripts.
- **Pixel-accurate Notch Silhouette & Click-Through Mechanics:**
  - Always-on-top, borderless, non-activating (`WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED`) window anchored at top-center of the target monitor (`680×420` logical points).
  - Custom `wgpu` / `egui::Painter` meniscus curve path matching the macOS `NotchShape` (flared top corners melting into the top screen edge, squircle bottom corners, hairline rim stroke, and ambient aurora radial glow).
  - Per-frame cursor hit-testing against the current animated notch rect (`shape_rect`): dynamically toggles `WS_EX_TRANSPARENT` via `SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ...)` so only the drawn notch area intercepts pointer events.
- **Full Feature Parity with macOS BullshitNotch:**
  1. **Closed Notch & 8 Procedural Pixel Animations:** Doom Fire, Laser Scanner (Knight Rider), Electric Lightning (Tesla Arc), Liquid Plasma Wave, Matrix Glitch Stream, Rainbow Rave, Warp Speed Starfield, and Random Bullshit Go! rendered into a `140×14` RGBA texture with nearest-neighbor scaling.
  2. **Live Wing Activities (Priority: HUD > Charger > Music > Agents):**
     - **Music (`NowPlaying`):** Uses Windows Runtime `GlobalSystemMediaTransportControlsSessionManager` (GSMTC) to read track title, artist, playback status, timeline position, and thumbnail stream from *any* Windows media player (Spotify, Apple Music, Chrome/YouTube, Foobar2000), plus 16×16 vibrant 3-color palette extraction.
     - **Agents (`AgentStore` & `AgentUsageTracker`):** Reads `%USERPROFILE%\.claude\sessions\*.json`, `%USERPROFILE%\.claude\projects\*\*.jsonl`, and `%USERPROFILE%\.gemini\antigravity*\brain\*\transcript.jsonl`. Checks process liveness via Win32 `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)` + `GetExitCodeProcess`. Tracks 5h session, daily, and 7d weekly token limits with incremental `(mtime, size)` file caching and optional Anthropic OAuth `/usage` sync (reading credentials from `%USERPROFILE%\.claude\.credentials.json` or Windows Credential Manager).
     - **Battery (`BatteryStore`):** Reads `GetSystemPowerStatus` + listens to `WM_POWERBROADCAST` (`PBT_APMPOWERSTATUSCHANGE`) for instant charger plug/unplug notifications.
     - **Volume & Brightness HUD (`HudStore`):** Low-level keyboard hook (`WH_KEYBOARD_LL`) or media key listener for `VK_VOLUME_UP`, `VK_VOLUME_DOWN`, `VK_VOLUME_MUTE`, coupled with Windows CoreAudio `IAudioEndpointVolume` and WMI / `Dxva2` monitor brightness APIs.
  3. **Expanded Tabs (`Home`, `Shelf`, `Workspace`, `Settings`):**
     - **Home Tab:** Music card (album art background, scrubbing bar, play/pause/skip controls, ambient aurora) + Agenda card (local `.ics` / Windows Calendar / Outlook or built-in local tasks + upcoming meeting URL detector with 1-click "Join").
     - **Shelf Tab:** Drag-and-drop file tray (`egui::ViewportCommand` / `HoveredFile` / `DroppedFile` + Win32 `IDropTarget` / `CF_HDROP` drag-out via `DoDragDrop`), plus Nearby Share / Explorer share sheet integration.
     - **Workspace Tab:**
       - **Git:** Queries `gh search prs` in background tasks (`CREATE_NO_WINDOW`) for "Mine" and "To Review" PRs with merge status dots.
       - **Work (Project Runner):** Auto-detects project scripts (`package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`), runs background dev servers with live tail logs, kills process trees via Win32 Job Objects or `taskkill /F /T /PID`, and launches projects in **Windows Terminal (`wt.exe`)**, **PowerShell**, **WezTerm**, **Alacritty**, or **VS Code**.
       - **Containers:** Discovers and controls **Docker Desktop**, **Podman**, and **WSL2** containers (`docker ps -a`, start/stop/restart/rm, inline logs, open shell in Windows Terminal, click exposed ports).
       - **Agents:** Filterable session list (`All`, `Claude`, `Antigravity`), subagent tree rows, ASCII animated faces (`[o_o]..`), click-to-focus terminal/VS Code window, and `HarnessLimitsCard` with 5h/Daily/7d progress bars.
       - **Custom Sections:** User-defined shortcuts for folders, `ssh://` targets, and URLs.

### Non-Goals
- Supporting Windows 7 or Windows 8 (Windows 10 1903+ and Windows 11 only).
- Bundling Node.js, Electron, or WebView2 (strictly native GPU-rendered Rust GUI).

### Anti-Goals
- Consuming >50 MB RAM or spinning a 60 FPS render loop when the notch is closed and idle.
- Flashing console windows (`cmd.exe` / `powershell.exe` popups) when polling `gh`, `docker`, or `podman` (every child process must set `creation_flags(CREATE_NO_WINDOW)`).
- Stealing keyboard focus from the user's active game or editor when hovering the notch (only activate focus when an inline `TextEdit` is clicked).

---

## 3. Architecture & Technical Choices (Builder Calls)

1. **GUI Framework: `eframe` / `egui` (0.29+) with `wgpu` backend**
   - Why `egui` over `iced` for a notch overlay: `egui` gives immediate, deterministic control over exact pixel coordinates, custom cubic Bezier path tessellation (`epaint::PathShape` for the flared meniscus notch silhouette), zero-copy `TextureHandle` updates for the `140×14` procedural fire bitmap, and trivial per-frame hit-box inspection (`ctx.pointer_latest_pos()`) to toggle Win32 click-through without fighting a retained layout tree.
2. **Repository Layout: `windows/` Cargo Workspace Root**
   - Placed in `windows/` inside this repository (or standalone Cargo crate `bullshit-notch-win`) so macOS (`Sources/*.swift`) and Windows (`windows/src/*.rs`) coexist cleanly in the same repo and share release workflows.
3. **Win32 Window Interop (`src/platform/win32.rs`)**
   - Uses `raw-window-handle` from `eframe::Frame` to obtain the Win32 `HWND`.
   - Configures extended window styles: `WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE`.
   - Runs a lightweight 60 Hz cursor poll (or `egui` pointer check) via `GetCursorPos`: when the cursor enters `shape_rect.expand(4.0)` (or when OLE drag-and-drop is active over the top bezel), clears `WS_EX_TRANSPARENT` so the window receives mouse/scroll events and springs open; when the cursor leaves, restores `WS_EX_TRANSPARENT` and collapses.
   - Temporarily clears `WS_EX_NOACTIVATE` and calls `SetForegroundWindow` only while an inline text field (`egui::TextEdit`) has focus.
4. **Reactive Frame Pacing (0% Idle CPU)**
   - When closed and idle (no agent animation burning, no music visualizer): `egui` sleeps until an OS event or store channel wakeup (`ctx.request_repaint()`).
   - When closed with active Fire animation: repaints every `80ms` (~12.5 FPS).
   - When closed with Music visualizer only: repaints every `440ms`.
   - When open/animating spring transition: repaints at display refresh rate until spring settles (`|vel| < 0.5 && |target - pos| < 0.5`).
5. **Subprocess Execution (`src/platform/process.rs`)**
   - Shared async helper `run_hidden(program, args)` using `tokio::process::Command` with `.creation_flags(0x08000000)` (`CREATE_NO_WINDOW`) so background `docker`, `podman`, and `gh` invocations never flash a console window.
