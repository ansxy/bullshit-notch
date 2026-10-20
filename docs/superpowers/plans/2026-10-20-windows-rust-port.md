# BullshitNotch for Windows (Pure Rust `egui` + `wgpu`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port BullshitNotch to Windows 10/11 in pure Rust using `eframe`/`egui` + `wgpu`, delivering the top-center flared notch overlay with click-through transparency, 8 procedural agent animations, GSMTC media controls with vibrant palette extraction, Claude/Antigravity session & token limit tracking, Docker/Podman/WSL container management, project runner, and GitHub PR dashboard under a <35 MB RAM footprint.

**Architecture:** A single-binary Rust crate under `windows/` powered by `eframe` (`wgpu` backend) and a `tokio` background runtime. Background stores communicate state snapshots to the UI thread via `tokio::sync::watch` channels and call `egui::Context::request_repaint()` only when state changes. Win32 extended window styles (`WS_EX_TRANSPARENT`, `WS_EX_LAYERED`, `WS_EX_TOOLWINDOW`, `WS_EX_NOACTIVATE`) provide click-through outside the custom cubic-Bezier `NotchShape` silhouette.

**Tech Stack:** Rust 2021, `eframe` 0.29 (`wgpu`), `egui` 0.29, `windows` 0.58 (Win32 + WinRT GSMTC/Audio/Power/Processes), `tray-icon` 0.19, `tokio` 1.x, `serde` + `serde_json`, `directories` 5.0, `chrono` 0.4, `image` 0.25.

**Spec:** [`docs/superpowers/specs/2026-10-20-windows-rust-port-design.md`](file:///Users/ansar/project/top-bar/docs/superpowers/specs/2026-10-20-windows-rust-port-design.md)

## Global Constraints

- Target OS: Windows 10 (1903+) & Windows 11 (`x86_64-pc-windows-msvc` and `aarch64-pc-windows-msvc`), while keeping pure-Rust domain/model modules (`config`, `fire`, `palette`, `agents`, `usage`, `containers`, `work`, `github`, `shape`) cross-platform testable with `cargo test` on macOS/Linux/Windows.
- Memory budget: <35 MB resident set size when idle; 0% CPU when closed and no animation is active.
- Subprocesses: Every `Command` spawned on Windows MUST set `.creation_flags(0x08000000)` (`CREATE_NO_WINDOW`) so console windows never flash on screen.
- Window behavior: Borderless `680×420` logical-point overlay centered at the top of the primary monitor (`y = 0`), non-activating (`WS_EX_NOACTIVATE`) except when an inline `egui::TextEdit` requests keyboard focus, and click-through (`WS_EX_TRANSPARENT`) whenever the cursor is outside `shape_rect.expand(4.0)`.

## Review Focus

1. **Partial or half-written `.jsonl` transcript lines during live agent streaming:** `AgentStore` and `AntigravitySessions` must only consume bytes up to the last `\n` and keep the byte offset at that newline so a mid-flush line is parsed on the next tick instead of dropped or panicking.
2. **Zombie child processes when stopping a Work project dev server:** Stopping a service spawned via `cmd.exe /C` or `powershell.exe` must kill the entire process tree (`taskkill /F /T /PID <pid>`), not just the parent shell wrapper.
3. **Console window flashing during periodic polling:** Polling `gh`, `docker`, `podman`, or `wsl` every few seconds without `CREATE_NO_WINDOW` makes Windows unusable; `run_hidden` must enforce `0x08000000` on all background commands.
4. **Click-through lockup if Settings or inline text input is active:** If the cursor moves outside `shape_rect`, `WS_EX_TRANSPARENT` must be restored immediately so the user's desktop/browser tabs underneath are never blocked.
5. **High-resolution album art or unbounded `.jsonl` history inflating RAM:** Album thumbnails from GSMTC must be downscaled to `<= 240×240` RGBA on decode, and `UsageFileCache` must key by `(PathBuf, SystemTime, u64)` so unchanged 7-day transcripts are parsed once.

---

## File Structure

```text
windows/
├── Cargo.toml
├── build.rs                          # Embeds Windows icon / manifest when targeting Windows
└── src/
    ├── main.rs                       # Entry point, eframe native options, tray icon setup
    ├── app.rs                        # TopBarApp state, reactive repaint scheduler, settings window
    ├── config.rs                     # Prefs struct persisted to %APPDATA%\BullshitNotch\settings.json
    ├── shape.rs                      # NotchShape cubic-Bezier meniscus path builder & DampedSpring
    ├── fire.rs                       # 8 procedural 140x14 pixel animations (Doom fire, scanner, etc.)
    ├── palette.rs                    # 16x16 vibrancy-weighted 3-color palette extraction & seed fallback
    ├── platform/
    │   ├── mod.rs                    # Platform trait & cross-platform stub vs #[cfg(windows)] impl
    │   ├── process.rs                # Hidden subprocess runner (CREATE_NO_WINDOW) & tree killer
    │   └── win32.rs                  # HWND styles (WS_EX_TRANSPARENT/NOACTIVATE), cursor & power hooks
    ├── stores/
    │   ├── mod.rs
    │   ├── battery.rs                # BatteryStore (GetSystemPowerStatus + charger just_changed timer)
    │   ├── hud.rs                    # HudStore (CoreAudio volume/mute + monitor brightness + media keys)
    │   ├── now_playing.rs            # NowPlayingStore (WinRT GSMTC session, timeline, artwork, palette)
    │   ├── agents.rs                 # AgentStore (~/.claude/sessions, subagents, Antigravity flock/PID)
    │   ├── usage.rs                  # AgentUsageTracker (5h/Daily/7d cache + Anthropic OAuth /usage)
    │   ├── containers.rs             # ContainerStore (Docker Desktop / Podman / WSL2 ps & actions)
    │   ├── work.rs                   # ProjectStore (saved projects, script auto-detect, terminal launch)
    │   ├── github.rs                 # PullRequestStore (`gh search prs` Mine / To Review + merge status)
    │   ├── shelf.rs                  # ShelfStore (dropped file paths, drag-out, Windows Share / Explorer)
    │   └── agenda.rs                 # AgendaStore (daily events, reminders, meeting link detector)
    └── ui/
        ├── mod.rs                    # Notch root view (collapsed wings vs expanded header + tab router)
        ├── home.rs                   # MusicCard + AgendaCard
        ├── shelf.rs                  # ShelfView (drop zone, file tiles, Nearby Share / Explorer button)
        ├── workspace.rs              # Section pills + Git / Work / Containers / Agents / Custom views
        └── settings.rs               # 6-tab Settings panel (Notch, Theme, Activities, Tabs, Menus, System)
```

---

### Task 1: Crate Scaffolding, Persistent `Prefs` Config, and Hidden Process Runner

**Files:**
- Create: `windows/Cargo.toml`
- Create: `windows/src/main.rs`
- Create: `windows/src/config.rs`
- Create: `windows/src/platform/mod.rs`
- Create: `windows/src/platform/process.rs`

**Interfaces:**
- Produces:
  - `config::Prefs` (`Serialize`, `Deserialize`, `Clone`, `PartialEq`) with `Prefs::load() -> Self`, `Prefs::save(&self) -> io::Result<()>`, `Prefs::migrate_legacy_limits(&mut self)`
  - `config::AgentAnimationStyle`, `config::NotchTheme`, `config::GlassMaterial`, `config::TerminalApp`, `config::ContainerCli`
  - `platform::process::run_hidden(program: &str, args: &[&str]) -> io::Result<CommandOutput>`
  - `platform::process::kill_process_tree(pid: u32) -> io::Result<()>`

- [ ] **Step 1: Create `windows/Cargo.toml` and minimal module stubs with failing config & process tests**

Create `windows/Cargo.toml` with `eframe = "0.29"`, `egui = "0.29"`, `serde = { version = "1", features = ["derive"] }`, `serde_json = "1"`, `tokio = { version = "1", features = ["rt-multi-thread", "process", "sync", "time", "macros", "fs"] }`, `directories = "5"`, `chrono = { version = "0.4", features = ["serde"] }`, `image = { version = "0.25", default-features = false, features = ["png", "jpeg", "webp"] }`, `reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }`, and target-specific `[target.'cfg(windows)'.dependencies]` (`windows = { version = "0.58", features = ["Win32_Foundation", "Win32_UI_WindowsAndMessaging", "Win32_System_Threading", "Win32_System_Power", "Win32_Graphics_Gdi", "Win32_Media_Audio", "Win32_Media_Audio_Endpoints", "Media_Control", "Storage_Streams"] }`, `tray-icon = "0.19"`, `raw-window-handle = "0.6"`).

Write unit tests in `windows/src/config.rs` and `windows/src/platform/process.rs`:
```rust
#[test]
fn prefs_defaults_and_legacy_limit_migration() {
    let mut p = Prefs::default();
    assert!(p.open_on_hover);
    assert_eq!(p.idle_width, 48.0);
    assert_eq!(p.claude_daily_limit, 12_500_000);
    assert_eq!(p.claude_weekly_limit, 90_000_000);

    // Legacy inflated defaults migrate automatically
    p.claude_daily_limit = 250_000_000;
    p.claude_weekly_limit = 1_500_000_000;
    p.agy_daily_limit = 25_000_000;
    p.agy_weekly_limit = 100_000_000;
    p.migrate_legacy_limits();
    assert_eq!(p.claude_daily_limit, 12_500_000);
    assert_eq!(p.agy_daily_limit, 8_000_000);
}

#[test]
fn prefs_roundtrip_json() {
    let mut p = Prefs::default();
    p.agent_animation = AgentAnimationStyle::Matrix;
    let json = serde_json::to_string(&p).unwrap();
    let decoded: Prefs = serde_json::from_str(&json).unwrap();
    assert_eq!(decoded.agent_animation, AgentAnimationStyle::Matrix);
}

#[tokio::test]
async fn run_hidden_captures_stdout_without_window() {
    let out = run_hidden("echo", &["bullshit-notch"]).await.unwrap();
    assert_eq!(out.status, 0);
    assert!(out.stdout.trim().contains("bullshit-notch"));
}
```

- [ ] **Step 2: Run `cargo test` to verify the tests fail**

Run: `cargo test --manifest-path windows/Cargo.toml`
Expected: FAIL (unimplemented `Prefs` methods and `run_hidden`).

- [ ] **Step 3: Implement `Prefs` in `windows/src/config.rs` and `run_hidden` / `kill_process_tree` in `windows/src/platform/process.rs`**

Mirror all keys and defaults from `NotchSettings.swift` (`Pref.register()`), persisting to `ProjectDirs::from("com", "ansxy", "BullshitNotch")?.config_dir().join("settings.json")`. In `platform/process.rs`, configure `tokio::process::Command` with `#[cfg(windows)] cmd.creation_flags(0x08000000);` (`CREATE_NO_WINDOW`), and implement `kill_process_tree(pid: u32)` using `taskkill /F /T /PID <pid>` on Windows and `pkill -TERM -P <pid>` on Unix.

- [ ] **Step 4: Run `cargo test` to verify all Task 1 tests pass**

Run: `cargo test --manifest-path windows/Cargo.toml`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add windows/
git commit -m "feat(windows): scaffold Rust crate, Prefs config, and hidden process runner"
```

---

### Task 2: Notch Silhouette Geometry (`NotchShape`) and Spring Animator

**Files:**
- Create: `windows/src/shape.rs`

**Interfaces:**
- Produces:
  - `shape::NotchShape` (`pub flare: f32, pub flare_depth: f32, pub bottom: f32, pub bulge: f32`)
  - `NotchShape::collapsed() -> Self` (`flare: 8.0, flare_depth: 8.0, bottom: 10.0, bulge: 0.0`)
  - `NotchShape::expanded() -> Self` (`flare: 24.0, flare_depth: 26.0, bottom: 26.0, bulge: 0.0`)
  - `NotchShape::lerp(a: Self, b: Self, t: f32) -> Self`
  - `NotchShape::sample_points(&self, rect: egui::Rect, segments_per_curve: usize) -> Vec<egui::Pos2>`
  - `shape::Spring` (`pub pos: f32, pub vel: f32, pub target: f32`) with `Spring::step(&mut self, dt: f32, response: f32, damping_fraction: f32) -> bool` (returns `true` while still moving)

- [ ] **Step 1: Write failing tests for `NotchShape` meniscus geometry and `Spring` physics**

```rust
#[test]
fn notch_shape_starts_and_ends_on_top_bezel() {
    let shape = NotchShape::expanded();
    let rect = egui::Rect::from_min_size(egui::pos2(30.0, 0.0), egui::vec2(620.0, 340.0));
    let pts = shape.sample_points(rect, 12);
    assert!((pts.first().unwrap().y - 0.0).abs() < 1e-4);
    assert!((pts.last().unwrap().y - 0.0).abs() < 1e-4);
    // Bottom points never exceed rect.max.y
    assert!(pts.iter().all(|p| p.y >= 0.0 && p.y <= 340.001));
    // Inner body is inset horizontally by flare (24pt)
    let mid_left = pts.iter().find(|p| (p.y - 170.0).abs() < 20.0 && p.x < 340.0).unwrap();
    assert!((mid_left.x - (rect.min.x + 24.0)).abs() < 1.0);
}

#[test]
fn underdamped_open_spring_overshoots_and_settles() {
    let mut s = Spring { pos: 0.0, vel: 0.0, target: 1.0 };
    let mut max_seen = 0.0_f32;
    for _ in 0..120 {
        s.step(1.0 / 60.0, 0.45, 0.62);
        max_seen = max_seen.max(s.pos);
    }
    assert!(max_seen > 1.02, "open spring should overshoot slightly like liquid");
    assert!((s.pos - 1.0).abs() < 0.01);
}
```

- [ ] **Step 2: Run `cargo test` to verify failure**

Run: `cargo test --manifest-path windows/Cargo.toml shape`
Expected: FAIL.

- [ ] **Step 3: Implement `NotchShape` cubic-Bezier evaluation and `Spring` in `windows/src/shape.rs`**

Port the exact cubic Bezier control points from `NotchShape.path(in:)` in `Sources/Notch.swift:1400-1436`:
- Top-left flare curve from `(r.min.x, r.min.y)` to `(left, r.min.y + depth)` with `c1 = (left - flare * 0.45, r.min.y)` and `c2 = (left, r.min.y + depth * 0.45)`
- Left vertical edge to `(left, r.max.y - radius)`
- Bottom-left squircle curve to `(left + radius, r.max.y)`
- Bottom edge to `(right - radius, r.max.y)`
- Bottom-right squircle curve to `(right, r.max.y - radius)`
- Right vertical edge to `(right, r.min.y + depth)`
- Top-right flare curve back to `(r.max.x, r.min.y)`

Implement second-order harmonic oscillator in `Spring::step` (`omega = 2 * PI / response`, `zeta = damping_fraction`).

- [ ] **Step 4: Run `cargo test` to verify pass**

Run: `cargo test --manifest-path windows/Cargo.toml shape`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/src/shape.rs windows/src/main.rs
git commit -m "feat(windows): add NotchShape meniscus Bezier geometry and spring physics"
```

---

### Task 3: Procedural Pixel Animations (`Fire` Engine) & Vibrant Artwork Palette Extractor

**Files:**
- Create: `windows/src/fire.rs`
- Create: `windows/src/palette.rs`

**Interfaces:**
- Produces:
  - `fire::Fire` (`COLS = 140`, `ROWS = 15`, `DRAW_ROWS = 14`, `MAX_HEAT = 14`)
  - `Fire::new() -> Self`
  - `Fire::step(&mut self)`
  - `Fire::accent(&self, style: AgentAnimationStyle) -> [u8; 4]`
  - `Fire::render_rgba(&self, style: AgentAnimationStyle, buf: &mut [u8; 140 * 14 * 4])`
  - `palette::Palette` (`pub primary: [u8; 3], pub secondary: [u8; 3], pub tertiary: [u8; 3]`)
  - `Palette::extract_from_rgba(width: u32, height: u32, rgba: &[u8]) -> Option<Self>`
  - `Palette::seed_for_key(key: &str) -> Self`
  - `palette::downscale_image_rgba(bytes: &[u8], max_dim: u32) -> Option<(u32, u32, Vec<u8>)>`

- [ ] **Step 1: Write failing tests for all 8 `Fire` styles, `Palette` extraction, and artwork downscaling**

```rust
#[test]
fn fire_renders_non_transparent_pixels_for_all_styles() {
    let mut fire = Fire::new();
    for _ in 0..25 {
        fire.step();
    }
    let mut buf = [0u8; Fire::COLS * Fire::DRAW_ROWS * 4];
    for style in AgentAnimationStyle::ALL {
        fire.render_rgba(style, &mut buf);
        let non_zero_alpha = buf.chunks_exact(4).filter(|px| px[3] > 0).count();
        assert!(non_zero_alpha > 20, "style {:?} produced blank buffer", style);
    }
}

#[test]
fn palette_extracts_distinct_vibrant_colors_and_seeds_deterministically() {
    // 16x16 image: top half vivid magenta, bottom half vivid cyan
    let mut rgba = Vec::with_capacity(16 * 16 * 4);
    for y in 0..16 {
        for _x in 0..16 {
            if y < 8 {
                rgba.extend_from_slice(&[240, 30, 180, 255]);
            } else {
                rgba.extend_from_slice(&[20, 220, 240, 255]);
            }
        }
    }
    let p = Palette::extract_from_rgba(16, 16, &rgba).unwrap();
    assert_ne!(p.primary, p.secondary);

    let s1 = Palette::seed_for_key("Track|Artist");
    let s2 = Palette::seed_for_key("Track|Artist");
    assert_eq!(s1, s2);
}
```

- [ ] **Step 2: Run `cargo test` to verify failure**

Run: `cargo test --manifest-path windows/Cargo.toml`
Expected: FAIL.

- [ ] **Step 3: Implement `Fire` in `windows/src/fire.rs` and `Palette` in `windows/src/palette.rs`**

Port the exact pixel shaders from `Sources/Agents.swift:488-755` (`Fire`, `Scanner`, `Lightning`, `Plasma`, `Matrix`, `Rave`, `Warp`, `RandomBullshit`) writing premultiplied or straight RGBA directly into `&mut [u8; 140 * 14 * 4]` (zero heap allocations per frame).
Port `NowPlaying.extractPalette(from:)` and `seedPalette(for:)` (`djb2` hash `5381`) from `Sources/NowPlaying.swift:191-305`, plus `downscale_image_rgba` using `image::load_from_memory` and `image::imageops::FilterType::Triangle` capped at `240×240`.

- [ ] **Step 4: Run `cargo test` to verify pass**

Run: `cargo test --manifest-path windows/Cargo.toml`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/src/fire.rs windows/src/palette.rs windows/src/main.rs
git commit -m "feat(windows): port 8 procedural notch animations and artwork palette extractor"
```

---

### Task 4: Claude & Antigravity Live Sessions (`AgentStore`) and Incremental Token Usage (`AgentUsageTracker`)

**Files:**
- Create: `windows/src/stores/mod.rs`
- Create: `windows/src/stores/agents.rs`
- Create: `windows/src/stores/usage.rs`

**Interfaces:**
- Produces:
  - `stores::agents::{Harness, Agent, SubAgent, AgentSnapshot, AgentStore}`
  - `Agent::face(status: Option<&str>, frame: usize) -> &'static str`
  - `AgentStore::refresh_from_dirs(claude_dir: &Path, gemini_dir: &Path, state: &mut AgentParseState) -> AgentSnapshot`
  - `stores::usage::{UsageStats, LimitPreset, UsageFileCache, AgentUsageTracker}`
  - `AgentUsageTracker::compute_claude(claude_dir: &Path, cache: &mut UsageFileCache, now: DateTime<Utc>) -> UsageStats`
  - `AgentUsageTracker::compute_antigravity(gemini_dir: &Path, cache: &mut UsageFileCache, now: DateTime<Utc>) -> UsageStats`

- [ ] **Step 1: Write failing tests for incremental `.jsonl` parsing, partial-line safety, subagent completion, and cached 5h/Daily/7d usage**

```rust
#[test]
fn incremental_claude_transcript_handles_partial_lines_and_dedupes_request_id() {
    let tmp = std::env::temp_dir().join(format!("bn-test-{}", uuid_stub()));
    std::fs::create_dir_all(&tmp).unwrap();
    let file = tmp.join("session-1.jsonl");

    // Write 1 complete line + 1 half-written line (no trailing newline)
    let line1 = r#"{"requestId":"req_1","timestamp":"2026-10-20T08:00:00Z","message":{"usage":{"input_tokens":100,"cache_creation_input_tokens":50,"cache_read_input_tokens":1000,"output_tokens":40},"content":[]}}"#;
    let partial = r#"{"requestId":"req_2","message":{"usage":{"input_tokens":500"#;
    std::fs::write(&file, format!("{}\n{}", line1, partial)).unwrap();

    let mut state = AgentParseState::default();
    let parsed1 = state.parse_claude_jsonl(&file);
    // 100 + 50 + 1000/10 = 250 input, 40 output; partial line ignored
    assert_eq!(parsed1.total(), (250, 40));

    // Complete the second line and repeat req_1
    let rest = r#","output_tokens":60}}}"#;
    std::fs::write(&file, format!("{}\n{}{}\n{}\n", line1, partial, rest, line1)).unwrap();
    let parsed2 = state.parse_claude_jsonl(&file);
    assert_eq!(parsed2.total(), (750, 100));
    let _ = std::fs::remove_dir_all(&tmp);
}

#[test]
fn usage_tracker_caches_unchanged_files_and_weights_cache_reads_at_10_percent() {
    let mut stats = UsageStats::default();
    stats.session_input = 1_000;
    stats.session_cache_write = 2_000;
    stats.session_cache_read = 10_000;
    stats.session_output = 500;
    assert_eq!(stats.session_effective(), 1_000 + 2_000 + 1_000 + 500);
}
```

- [ ] **Step 2: Run `cargo test` to verify failure**

Run: `cargo test --manifest-path windows/Cargo.toml stores`
Expected: FAIL.

- [ ] **Step 3: Implement `AgentStore` (`windows/src/stores/agents.rs`) and `AgentUsageTracker` (`windows/src/stores/usage.rs`)**

- In `agents.rs`:
  - Read `%USERPROFILE%\.claude\sessions\*.json`, check PID liveness (`OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)` + `GetExitCodeProcess == STILL_ACTIVE` on Windows; `kill(pid, 0) == 0` on Unix).
  - Slugify `cwd` (`c.is_ascii_alphanumeric() ? c : '-'`), incrementally read `<sessionId>.jsonl` from `entry.offset` up to `data.iter().rposition(|&b| b == b'\n')`, track `<task-id>` and `tool_result` completions, and scan `<sessionId>/subagents/agent-*.jsonl`.
  - Scan `%USERPROFILE%\.gemini\antigravity*\presence\*.lock` and parse `.system_generated/logs/transcript.jsonl` steps (`PLANNER_RESPONSE`).
  - Prune dead session URLs and IDs on every refresh.
- In `usage.rs`:
  - Implement `UsageFileCache` keyed by `(PathBuf, SystemTime, u64)` so unchanged `.jsonl` files are never re-parsed.
  - Support reading Anthropic OAuth token from `%USERPROFILE%\.claude\.credentials.json` and querying `https://api.anthropic.com/api/oauth/usage` with header `anthropic-beta: oauth-2025-04-20`.

- [ ] **Step 4: Run `cargo test` to verify pass**

Run: `cargo test --manifest-path windows/Cargo.toml stores`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/src/stores/ windows/src/main.rs
git commit -m "feat(windows): implement AgentStore and incremental AgentUsageTracker"
```

---

### Task 5: Containers (`Docker` / `Podman` / `WSL2`), Project Runner (`Work`), and `GitHub` PR Store

**Files:**
- Create: `windows/src/stores/containers.rs`
- Create: `windows/src/stores/work.rs`
- Create: `windows/src/stores/github.rs`
- Create: `windows/src/stores/shelf.rs`
- Create: `windows/src/stores/agenda.rs`

**Interfaces:**
- Produces:
  - `stores::containers::{ContainerItem, ContainerStore}` with `parse_docker_ndjson(text: &str, cli: &str) -> Vec<ContainerItem>`, `parse_podman_json(text: &str) -> Vec<ContainerItem>`, `extract_host_ports(text: &str) -> Vec<u16>`
  - `stores::work::{ProjectItem, ProjectStore}` with `detect_default_service_command(folder: &Path) -> String`, `launch_in_terminal(dir: &Path, command: Option<&str>, pref: TerminalApp)`
  - `stores::github::{PullRequest, PrList, PullRequestStore}`
  - `stores::shelf::ShelfStore`
  - `stores::agenda::{AgendaEvent, AgendaReminder, AgendaStore}` with `extract_meeting_link(texts: &[&str]) -> Option<String>`

- [ ] **Step 1: Write failing unit tests for Docker/Podman JSON parsing, port extraction, project script detection, and meeting URL detection**

```rust
#[test]
fn parses_docker_ndjson_and_host_ports() {
    let raw = r#"{"ID":"abcdef1234567890","Names":"/postgres-local","Image":"postgres:16","State":"running","Status":"Up 2 hours","Ports":"0.0.0.0:5432->5432/tcp, :::8080->80/tcp","Labels":"com.docker.compose.project=my-stack"}"#;
    let list = ContainerStore::parse_docker_ndjson(raw, "docker");
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].id, "abcdef123456");
    assert_eq!(list[0].name, "postgres-local");
    assert_eq!(list[0].ports, vec![5432, 8080]);
    assert_eq!(list[0].compose_project.as_deref(), Some("my-stack"));
}

#[test]
fn detects_default_service_command_and_meeting_links() {
    let link = AgendaStore::extract_meeting_link(&[
        "Notes: join https://example.com/doc or https://meet.google.com/abc-defg-hij now"
    ]);
    assert_eq!(link.as_deref(), Some("https://meet.google.com/abc-defg-hij"));
}
```

- [ ] **Step 2: Run `cargo test` to verify failure**

Run: `cargo test --manifest-path windows/Cargo.toml`
Expected: FAIL.

- [ ] **Step 3: Implement `containers.rs`, `work.rs`, `github.rs`, `shelf.rs`, and `agenda.rs`**

- `containers.rs`: Parse Docker NDJSON and Podman JSON array; probe `docker.exe` (`C:\Program Files\Docker\Docker\resources\bin\docker.exe` or `PATH`) and `podman.exe`; support starting Docker Desktop (`Start-Process "Docker Desktop"`) or `podman machine start`; open container shell in Windows Terminal (`wt.exe -d <home> docker exec -it <name> sh`).
- `work.rs`: Port `detectDefaultServiceCommand` (`package.json` with `pnpm`/`bun`/`yarn`/`npm`, `Cargo.toml`, `go.mod`, `docker-compose.yml`, `manage.py`). Spawn background dev servers with `tokio::process::Command` (`cmd.exe /C <cmd>` on Windows, `sh -lc <cmd>` on Unix) with a 4,000-char ring buffer for logs and `kill_process_tree` on stop. Support launching in Windows Terminal (`wt.exe -d <dir> cmd /K <cmd>`), PowerShell, WezTerm, Alacritty, or VS Code (`code <dir>`).
- `github.rs`: Run `gh search prs --author=@me` and `--review-requested=@me` via `run_hidden`.
- `shelf.rs`: Persist file paths in config dir, filter existing files, open in Explorer (`explorer.exe /select,<path>`).
- `agenda.rs`: Meeting URL detector matching `zoom.us`, `meet.google.com`, `teams.microsoft.com`, `teams.live.com`, `webex.com`, `whereby.com`, `slack.com/huddle`, plus local `.ics` / task items.

- [ ] **Step 4: Run `cargo test` to verify pass**

Run: `cargo test --manifest-path windows/Cargo.toml`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/src/stores/
git commit -m "feat(windows): implement ContainerStore, ProjectStore, PullRequestStore, ShelfStore, and AgendaStore"
```

---

### Task 6: Windows Native Integrations (`Win32` Click-Through Overlay, `GSMTC` NowPlaying, `Battery`, and `HUD`)

**Files:**
- Create: `windows/src/platform/win32.rs`
- Create: `windows/src/stores/battery.rs`
- Create: `windows/src/stores/hud.rs`
- Create: `windows/src/stores/now_playing.rs`

**Interfaces:**
- Produces:
  - `platform::win32::OverlayWindowController` with:
    - `configure_hwnd(&mut self, frame: &eframe::Frame)`
    - `update_mouse_passthrough(&mut self, shape_rect_logical: egui::Rect, scale_factor: f32, window_origin_screen: egui::Pos2, wants_keyboard: bool) -> (bool, bool)` (returns `(cursor_inside_shape, left_mouse_dragging)`)
  - `stores::battery::{BatterySnapshot, BatteryStore}`
  - `stores::hud::{HudKind, HudSnapshot, HudStore}`
  - `stores::now_playing::{NowPlayingSnapshot, MediaCommand, NowPlayingStore}`

- [ ] **Step 1: Write unit tests for hit-test rect math, battery state transition (`just_changed`), and media elapsed calculation**

```rust
#[test]
fn cursor_hit_test_expands_by_4pt_margin() {
    let shape = egui::Rect::from_min_size(egui::pos2(220.0, 0.0), egui::vec2(240.0, 32.0));
    let win_origin = egui::pos2(620.0, 0.0);
    assert!( platform::win32::is_cursor_inside_shape(egui::pos2(840.0, 34.0), win_origin, shape));
    assert!(!platform::win32::is_cursor_inside_shape(egui::pos2(840.0, 40.0), win_origin, shape));
}

#[test]
fn battery_plug_change_triggers_3s_announcement() {
    let mut b = BatterySnapshot::default();
    b.apply_raw(85, true, true, false);
    assert!(!b.just_changed);
    b.apply_raw(85, false, false, true);
    assert!(b.just_changed);
}
```

- [ ] **Step 2: Run `cargo test` to verify failure**

Run: `cargo test --manifest-path windows/Cargo.toml`
Expected: FAIL.

- [ ] **Step 3: Implement `win32.rs`, `battery.rs`, `hud.rs`, and `now_playing.rs`**

- `platform/win32.rs`:
  - Pure helper `is_cursor_inside_shape(cursor_logical, win_origin_logical, shape_rect_logical)` (`shape_rect_logical.expand(4.0).contains(cursor_logical - win_origin_logical.to_vec2())`).
  - On `#[cfg(windows)]`: extract `HWND` via `raw_window_handle::HasWindowHandle`, apply `WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT`. Poll `GetCursorPos` + `GetAsyncKeyState(VK_LBUTTON)`: toggle `WS_EX_TRANSPARENT` only when `inside` state changes (avoiding redundant Win32 calls), and toggle `WS_EX_NOACTIVATE` when `wants_keyboard` changes.
- `stores/battery.rs`:
  - On `#[cfg(windows)]`: call `GetSystemPowerStatus` (`ACLineStatus`, `BatteryFlag`, `BatteryLifePercent`). Set `just_changed = true` for 3 seconds whenever `plugged_in` flips. Include `--demo` preset (`88%`, charging).
- `stores/hud.rs`:
  - On `#[cfg(windows)]`: COM `IMMDeviceEnumerator` -> `IAudioEndpointVolume` for master volume (`GetMasterVolumeLevelScalar` / `SetMasterVolumeLevelScalar`) and mute state.
- `stores/now_playing.rs`:
  - On `#[cfg(windows)]`: WinRT `GlobalSystemMediaTransportControlsSessionManager::RequestAsync()`, read `GetCurrentSession()`, `TryGetMediaPropertiesAsync()` (Title, Artist, Thumbnail `IRandomAccessStreamReference`), `GetPlaybackInfo()` (Playing/Paused), `GetTimelineProperties()`. Decode thumbnail with `downscale_image_rgba(..., 240)` and compute `Palette::extract_from_rgba`. Support `PlayPause`, `Next`, `Previous` via `TryTogglePlayPauseAsync()`, `TrySkipNextAsync()`, `TrySkipPreviousAsync()`.

- [ ] **Step 4: Run `cargo test` to verify pass**

Run: `cargo test --manifest-path windows/Cargo.toml`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/src/platform/win32.rs windows/src/stores/battery.rs windows/src/stores/hud.rs windows/src/stores/now_playing.rs
git commit -m "feat(windows): add Win32 click-through controller, GSMTC NowPlaying, Battery, and Audio HUD"
```

---

### Task 7: `egui` + `wgpu` Notch UI (`NotchView`, `HomeView`, `ShelfView`, `WorkspaceView`, `SettingsView`, System Tray)

**Files:**
- Create: `windows/src/app.rs`
- Create: `windows/src/ui/mod.rs`
- Create: `windows/src/ui/home.rs`
- Create: `windows/src/ui/shelf.rs`
- Create: `windows/src/ui/workspace.rs`
- Create: `windows/src/ui/settings.rs`
- Modify: `windows/src/main.rs`

**Interfaces:**
- Produces:
  - `app::BullshitNotchApp` implementing `eframe::App` (`update` + `clear_color` returning `[0.0, 0.0, 0.0, 0.0]`)
  - `app::compute_repaint_delay(expanded: bool, spring_moving: bool, agents_burning: bool, music_playing: bool) -> Duration`
  - Complete UI modules `ui::home`, `ui::shelf`, `ui::workspace`, `ui::settings`

- [ ] **Step 1: Write unit test for the reactive frame-pacing scheduler (`compute_repaint_delay`)**

```rust
#[test]
fn frame_scheduler_sleeps_when_idle_and_paces_animations() {
    // Spring in motion -> ~16ms (60fps)
    assert_eq!(compute_repaint_delay(true, true, false, false), Duration::from_millis(16));
    // Closed + fire burning -> 80ms (~12.5fps)
    assert_eq!(compute_repaint_delay(false, false, true, false), Duration::from_millis(80));
    // Closed + music playing (visualizer only) -> 440ms
    assert_eq!(compute_repaint_delay(false, false, false, true), Duration::from_millis(440));
    // Closed + idle -> 2000ms slow heartbeat (stores wake UI immediately on events)
    assert_eq!(compute_repaint_delay(false, false, false, false), Duration::from_millis(2000));
}
```

- [ ] **Step 2: Run `cargo test` to verify failure**

Run: `cargo test --manifest-path windows/Cargo.toml frame_scheduler`
Expected: FAIL.

- [ ] **Step 3: Implement `app.rs`, `ui/mod.rs`, `ui/home.rs`, `ui/shelf.rs`, `ui/workspace.rs`, `ui/settings.rs`, and `main.rs`**

- `ui/mod.rs`:
  - Interpolate `NotchShape::collapsed()` and `NotchShape::expanded()` using `open_spring.pos`.
  - Draw the filled polygon path via `egui::Painter`, plus the hairline top-faded rim stroke and ambient radial aurora glow from `NowPlaying` `Palette` (or active `Fire` accent).
  - Closed state: left wing (HUD icon / Battery bolt / Album art thumbnail), center camera spacer (`notch_width + width_adjust`), right wing (HUD level bar / Battery % / 4-bar animated `Visualizer`), and full-width `140×14` nearest-neighbor `egui::TextureOptions::NEAREST` `Fire` animation when `agents_burning`.
  - Expanded state (`620pt` wide): header bar with `Home`, `Shelf`, `Workspace` tab pills on the left of the notch spacer and Battery % + Settings gear button on the right.
- `ui/home.rs`: `MusicCard` (150×150 square with album cover backdrop, equalizer badge, track title/artist, click-to-seek progress bar, prev/play-pause/next buttons) + `AgendaCard` (week day strip `-1..=5`, event/reminder list, "Next meeting" banner with "Join" button).
- `ui/shelf.rs`: File drop target (`ctx.input(|i| i.raw.dropped_files)`), horizontal scrollable file cards with double-click to open and right-click context menu ("Open", "Show in Explorer", "Remove"), plus "Share / Explorer" and "Clear" buttons.
- `ui/workspace.rs`: Section pills (`Git`, `Work`, `Containers`, `Agents`, + user custom sections).
  - `Git`: Two-column `Mine` & `To Review` PR cards with merge status dots.
  - `Work`: Project list with inline path/command add bar, folder picker, Start/Stop dev server button, expandable live terminal output log, and quick-launch buttons for Terminal, Agent CLI (`claude`, `agy`, `codex`), Explorer, and VS Code.
  - `Containers`: Engine status badge (`Docker Desktop` / `Podman`), `Running Only` filter, container rows with clickable `:port` badges, Start/Stop/Restart/Remove buttons, inline logs, and "Shell in Terminal".
  - `Agents`: Filter pills (`All`, `Claude`, `Antigravity`), running session rows with animated ASCII faces (`[o_o]..`), subagent tree rows, and `HarnessLimitsCard` (`5h Session` / `Today` toggle + `7d Weekly` progress bars + preset tier selector + custom limit editor).
- `ui/settings.rs`: Separate viewport or modal panel with the 6 tabs (`Notch`, `Theme`, `Activities`, `Tabs`, `Menus`, `System`).
- `main.rs`: Configure `eframe::NativeOptions` (`ViewportBuilder::default().with_decorations(false).with_transparent(true).with_always_on_top().with_inner_size([680.0, 420.0])`), system tray icon (`tray-icon`) to open Settings or Quit, and `--demo` flag support.

- [ ] **Step 4: Run `cargo test` and `cargo check` to verify everything compiles and passes tests cleanly**

Run: `cargo test --manifest-path windows/Cargo.toml`
Expected: PASS (all unit tests pass with zero errors).

- [ ] **Step 5: Commit**

```bash
git add windows/
git commit -m "feat(windows): implement full egui+wgpu Notch UI, tabs, settings, and tray integration"
```

---

### Task 8: GitHub Actions Windows Release Workflow & Packaging Script

**Files:**
- Create: `.github/workflows/release-windows.yml`
- Create: `windows/package-windows.ps1`

**Interfaces:**
- Produces:
  - Automated CI/CD build for `x86_64-pc-windows-msvc` producing `BullshitNotch-Windows-x64.exe` and `BullshitNotch-Windows-x64.zip` with LTO and symbol stripping enabled (`[profile.release] lto = true, codegen-units = 1, strip = true, panic = "abort"`).

- [ ] **Step 1: Add release profile optimizations to `windows/Cargo.toml` and create `windows/package-windows.ps1` + `.github/workflows/release-windows.yml`**

Configure `[profile.release]` in `windows/Cargo.toml`:
```toml
[profile.release]
opt-level = 3
lto = "thin"
codegen-units = 1
strip = true
panic = "abort"
```
Create `windows/package-windows.ps1` and `.github/workflows/release-windows.yml` that builds `cargo build --release --manifest-path windows/Cargo.toml` on `windows-latest` and uploads `BullshitNotch-Windows-x64.zip` to GitHub Releases.

- [ ] **Step 2: Verify release build compiles cleanly**

Run: `cargo build --release --manifest-path windows/Cargo.toml`
Expected: Exits 0 and produces optimized binary in `windows/target/release/`.

- [ ] **Step 3: Commit**

```bash
git add windows/Cargo.toml windows/package-windows.ps1 .github/workflows/release-windows.yml
git commit -m "ci(windows): add Windows Rust release profile, packaging script, and GitHub Actions workflow"
```
