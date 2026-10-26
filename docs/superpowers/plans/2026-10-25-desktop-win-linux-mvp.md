# Desktop (Windows + Linux) MVP Plan

> **For agentic workers:** Implement task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port BullshitNotch closed-notch + agents fire MVP to Windows 10/11 and Linux as a pure Rust `eframe`/`egui` + `wgpu` binary under `desktop/`, with click-through overlay, Claude session tracking, and a minimal expanded agents list.

**Architecture:** Single crate `desktop/`. Background stores push snapshots over `tokio::sync::watch` and call `egui::Context::request_repaint()` only on change. Platform overlay behind a trait: Win32 `WS_EX_TRANSPARENT` toggle; Linux X11 XShape input region (forced X11 / XWayland backend).

**Tech Stack:** Rust 2021, `eframe` 0.29 (`wgpu`), `egui` 0.29, `tokio` 1.x, `serde` + `serde_json`, `directories` 5.0, `chrono` 0.4; Windows: `windows` 0.58; Linux: `x11rb` (shape).

**Spec:** [`docs/superpowers/specs/2026-10-20-windows-rust-port-design.md`](../specs/2026-10-20-windows-rust-port-design.md) (plus Linux section).

## Changes vs Windows-only plan

- Crate path: `desktop/` (not `windows/`).
- Targets: Windows + Linux.
- MVP only: closed notch, fire when Claude agents busy, hover opens Agents list. Music, battery, HUD, shelf, Git/Work/Containers, settings UI, usage tracker, palette, tray, CI release deferred.
- Linux: force winit X11 backend; click-through via XShape input region = `shape_rect.expand(4.0)`; `_NET_WM_WINDOW_TYPE_DOCK` + `_NET_WM_STATE_ABOVE` + `SKIP_TASKBAR`. Native Wayland layer-shell is the upgrade path (`// ponytail:`).

## File Structure

```text
desktop/
├── Cargo.toml
└── src/
    ├── main.rs
    ├── app.rs
    ├── config.rs
    ├── shape.rs
    ├── fire.rs
    ├── platform/
    │   ├── mod.rs
    │   ├── process.rs
    │   ├── win32.rs
    │   └── x11.rs
    ├── stores/
    │   ├── mod.rs
    │   └── agents.rs
    └── ui/
        └── mod.rs
```

## Tasks

### Task 0: Housekeeping

- [x] Remove leftover `desktop/target`, refresh graphify, save this plan, document Linux overlay in the design spec.

### Task 1: Scaffold, Prefs, Hidden Process Runner

- [ ] `desktop/Cargo.toml`, `main.rs`, `config.rs`, `platform/mod.rs`, `platform/process.rs`
- [ ] Tests: prefs defaults/migration/roundtrip, `run_hidden`
- [ ] Commit: `feat(desktop): scaffold Rust crate, Prefs config, and hidden process runner`

### Task 2: NotchShape + Spring

- [ ] `shape.rs` ported from `Sources/Notch.swift` NotchShape
- [ ] Tests: meniscus starts/ends on top bezel; underdamped spring overshoots
- [ ] Commit: `feat(desktop): add NotchShape meniscus Bezier geometry and spring physics`

### Task 3: Fire Animations

- [ ] `fire.rs` + `AgentAnimationStyle` (8 styles from `Sources/Agents.swift`)
- [ ] Test: all styles render non-transparent pixels
- [ ] Commit: `feat(desktop): port 8 procedural notch animations`

### Task 4: Overlay (Win32 + X11)

- [ ] `Overlay` trait; `win32.rs`; `x11.rs`; pure `is_cursor_inside_shape` + test
- [ ] Commit: `feat(desktop): add Win32 and X11 click-through overlay controllers`

### Task 5: Claude AgentStore

- [ ] `stores/agents.rs`: sessions, liveness, incremental jsonl (partial-line safe), requestId dedupe, subagents
- [ ] Commit: `feat(desktop): implement Claude AgentStore with incremental transcript parse`

### Task 6: Notch UI MVP

- [ ] `app.rs` (`compute_repaint_delay`), `ui/mod.rs`, `--demo`
- [ ] Commit: `feat(desktop): implement egui notch UI MVP with agents list`

## Verification

- `/path/to/toolchain/bin/cargo test --manifest-path desktop/Cargo.toml`
- Manual Linux overlay check on Bazzite (XWayland)
- `graphify update .` after code changes
