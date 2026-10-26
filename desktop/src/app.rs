use crate::config::Prefs;
use crate::fire::Fire;
use crate::platform::tray::{self, TrayAction, TrayHandle};
use crate::platform::{self, Overlay};
use crate::shape::Spring;
use crate::stores::agents::{AgentParseState, AgentSnapshot};
use crate::stores::antigravity::AntigravitySessions;
use crate::stores::battery::BatterySnapshot;
use crate::stores::hud::HudSnapshot;
use crate::stores::now_playing::NowPlayingSnapshot;
use crate::stores::agenda::AgendaSnapshot;
use crate::stores::containers::ContainerSnapshot;
use crate::stores::github::GithubSnapshot;
use crate::stores::shelf::ShelfSnapshot;
use crate::stores::usage::UsageSnapshot;
use crate::stores::work::WorkSnapshot;
use crate::ui;
use eframe::egui;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::watch;

const WINDOW_W: f32 = 680.0;
const WINDOW_H: f32 = 480.0;

pub fn compute_repaint_delay(
    expanded: bool,
    spring_moving: bool,
    agents_burning: bool,
    music_playing: bool,
) -> Duration {
    if spring_moving {
        return Duration::from_millis(16);
    }
    // While open (even settled): keep polling. XShape/click-through means mouse-leave
    // never wakes the event loop — without this, full-open sticks forever.
    if expanded {
        return Duration::from_millis(50);
    }
    if agents_burning {
        return Duration::from_millis(80);
    }
    if music_playing {
        return Duration::from_millis(440);
    }
    Duration::from_millis(2000)
}

pub struct BullshitNotchApp {
    prefs: Prefs,
    overlay: Overlay,
    overlay_ready: bool,
    pinned_top: bool,
    open_spring: Spring,
    fire: Fire,
    fire_texture: Option<egui::TextureHandle>,
    agents_rx: watch::Receiver<AgentSnapshot>,
    face_frame: usize,
    demo: bool,
    last_shape_rect: egui::Rect,
    /// Wake egui while notch is open — `request_repaint_after` alone misses leave under XShape.
    wake_poll: Arc<AtomicBool>,
    /// After a close, require cursor to leave the pill before it may open again.
    /// Stops rare end-of-close reopen bounce when pointer still sits on the shrink path.
    reopen_armed: bool,
    /// Wall-clock fire pacing (macOS 80ms timer) — independent of frame/mouse rate.
    last_fire_tick: Instant,
    music_rx: watch::Receiver<NowPlayingSnapshot>,
    battery_rx: watch::Receiver<BatterySnapshot>,
    hud_rx: watch::Receiver<HudSnapshot>,
    art_tex: Option<(String, egui::TextureHandle)>,
    started: Instant,
    usage_rx: watch::Receiver<UsageSnapshot>,
    shelf_rx: watch::Receiver<ShelfSnapshot>,
    agenda_rx: watch::Receiver<AgendaSnapshot>,
    github_rx: watch::Receiver<GithubSnapshot>,
    work_rx: watch::Receiver<WorkSnapshot>,
    containers_rx: watch::Receiver<ContainerSnapshot>,
    ui_state: ui::UiState,
    /// `--open`: keep the panel expanded (layout debugging / screenshots).
    pin_open: bool,
    tray: TrayHandle,
}

impl BullshitNotchApp {
    pub fn new(cc: &eframe::CreationContext<'_>, demo: bool) -> Self {
        let pin_open = std::env::args().any(|a| a == "--open");
        let prefs = Prefs::load();
        let (tx, rx) = watch::channel(if demo {
            AgentSnapshot::demo()
        } else {
            AgentSnapshot::default()
        });

        let wake_poll = Arc::new(AtomicBool::new(false));
        {
            let ctx = cc.egui_ctx.clone();
            let wake = Arc::clone(&wake_poll);
            std::thread::spawn(move || {
                while Arc::strong_count(&wake) > 1 {
                    if wake.load(Ordering::Relaxed) {
                        ctx.request_repaint();
                    }
                    std::thread::sleep(Duration::from_millis(33));
                }
            });
        }

        if !demo {
            let ctx = cc.egui_ctx.clone();
            let claude_dir = dirs_claude();
            let gemini_dir = dirs_home().join(".gemini");
            std::thread::spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("tokio");
                rt.block_on(async move {
                    let mut state = AgentParseState::default();
                    let mut agy = AntigravitySessions::default();
                    loop {
                        let cursor_dir = dirs_home().join(".cursor");
                        let commandcode_dir = dirs_home().join(".commandcode");
                        let snap = crate::stores::agents::refresh_all(
                            &claude_dir,
                            &gemini_dir,
                            &cursor_dir,
                            &commandcode_dir,
                            &mut state,
                            &mut agy,
                        );
                        let _ = tx.send(snap);
                        ctx.request_repaint();
                        tokio::time::sleep(Duration::from_secs(3)).await;
                    }
                });
            });
        }

        let (music_rx, battery_rx, hud_rx) = crate::stores::spawn_live(&cc.egui_ctx, demo);
        let usage_rx = if demo {
            crate::stores::fixed(UsageSnapshot::demo())
        } else {
            crate::stores::usage::spawn(
                cc.egui_ctx.clone(),
                dirs_claude(),
                dirs_home().join(".gemini"),
                dirs_home().join(".cursor"),
                dirs_home().join(".commandcode"),
            )
        };
        let shelf_rx = crate::stores::shelf::spawn(demo);
        let agenda_rx = crate::stores::agenda::spawn(cc.egui_ctx.clone(), demo);
        let github_rx = crate::stores::github::spawn(cc.egui_ctx.clone(), demo);
        let work_rx = crate::stores::work::spawn(demo);
        let containers_rx = crate::stores::containers::spawn(cc.egui_ctx.clone(), demo, prefs.container_cli);

        Self {
            music_rx,
            battery_rx,
            hud_rx,
            art_tex: None,
            started: Instant::now(),
            usage_rx,
            shelf_rx,
            agenda_rx,
            github_rx,
            work_rx,
            containers_rx,
            ui_state: ui::UiState {
                // `--demo --open`: land on Agents so usage pills/cards are screenshotable.
                tab: if demo && pin_open {
                    ui::NotchTab::Workspace
                } else {
                    ui::NotchTab::Home
                },
                ..Default::default()
            },
            pin_open,
            tray: tray::spawn(),
            prefs,
            overlay: Overlay::new(),
            overlay_ready: false,
            pinned_top: false,
            open_spring: Spring::new(0.0),
            fire: Fire::new(),
            fire_texture: None,
            agents_rx: rx,
            face_frame: 0,
            demo,
            last_shape_rect: egui::Rect::NOTHING,
            wake_poll,
            reopen_armed: true,
            last_fire_tick: Instant::now(),
        }
    }

    fn pin_top_center(&mut self, ctx: &egui::Context) {
        if self.pinned_top {
            return;
        }
        let mon = ctx
            .input(|i| i.viewport().monitor_size)
            .unwrap_or(egui::vec2(1920.0, 1080.0));
        let x = ((mon.x - WINDOW_W) * 0.5).max(0.0);
        ctx.send_viewport_cmd(egui::ViewportCommand::OuterPosition(egui::pos2(x, 0.0)));
        ctx.send_viewport_cmd(egui::ViewportCommand::InnerSize(egui::vec2(
            WINDOW_W, WINDOW_H,
        )));
        self.pinned_top = true;
    }
}

impl eframe::App for BullshitNotchApp {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        [0.0, 0.0, 0.0, 0.0]
    }

    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        if !self.overlay_ready {
            self.overlay.configure(frame);
            self.overlay_ready = true;
        }
        self.pin_top_center(ctx);

        let snap = self.agents_rx.borrow().clone();
        let busy = snap
            .agents
            .iter()
            .filter(|a| a.status.as_deref() == Some("busy") && self.prefs.harness_enabled(a.harness))
            .count();
        let burning = (self.prefs.live_agents && busy > 0)
            || self.prefs.agent_animation_always_on
            || (self.demo && busy > 0);

        let scale = ctx.pixels_per_point();
        let win_origin = ctx
            .input(|i| i.viewport().outer_rect)
            .map(|r| r.min)
            .unwrap_or(egui::pos2(0.0, 0.0));
        let already_open = self.open_spring.pos > 0.12;
        // CRITICAL: while open, never trust a missing/stale pointer as "still hovering".
        // XShape-only input previously froze egui's last hover_pos inside the pill → stuck open.
        // While open we capture the full window (below) so leave clears hover_pos → close.
        let hovering = if let Some(p) = ctx.input(|i| i.pointer.hover_pos()) {
            self.last_shape_rect.expand(8.0).contains(p)
        } else if already_open {
            false
        } else {
            // Closed: pill may not have delivered egui events yet — probe X11.
            platform::is_hovering_shape(self.last_shape_rect, scale, win_origin)
        };

        // Leave-then-reenter gate: after close starts, ignore hover until cursor
        // has left the pill at least once. Kills rare settle-edge reopen bounce.
        if already_open {
            if !hovering {
                self.reopen_armed = false;
            }
        } else if !hovering {
            self.reopen_armed = true;
        }

        let file_hover = ctx.input(|i| !i.raw.hovered_files.is_empty() || !i.raw.dropped_files.is_empty());
        let want_open =
            self.pin_open || file_hover || (self.prefs.open_on_hover && hovering && (already_open || self.reopen_armed));
        self.open_spring.target = if want_open { 1.0 } else { 0.0 };
        let dt = ctx.input(|i| i.stable_dt).clamp(1.0 / 120.0, 0.05);
        // Higher damping — close must not bounce.
        let spring_moving = self.open_spring.step(dt, 0.38, 0.90);
        let expanded = self.open_spring.pos > 0.15;
        // Keep waking while fire burns — otherwise idle closed starves updates
        // and animation only advances when the cursor moves.
        self.wake_poll.store(
            expanded || spring_moving || want_open || (burning && !expanded),
            Ordering::Relaxed,
        );

        // Wall clock @ 80ms (macOS Timer). Not frame dt — mouse was speeding it,
        // then clamped dt made idle fire crawl.
        const FIRE_DT: Duration = Duration::from_millis(80);
        if burning && !expanded {
            let now = Instant::now();
            let mut guarded = 0;
            while now.duration_since(self.last_fire_tick) >= FIRE_DT && guarded < 4 {
                self.fire.step();
                self.last_fire_tick += FIRE_DT;
                guarded += 1;
            }
            // If we fell far behind (tab suspend), resync instead of catch-up burst.
            if now.duration_since(self.last_fire_tick) > FIRE_DT * 4 {
                self.last_fire_tick = now;
            }
        } else if !burning && self.fire.steps > 0 && !self.prefs.agent_animation_always_on {
            self.fire = Fire::new();
            self.last_fire_tick = Instant::now();
        } else if !burning || expanded {
            self.last_fire_tick = Instant::now();
        }

        if burning {
            let mut buf = [0u8; Fire::COLS * Fire::DRAW_ROWS * 4];
            self.fire.render_rgba(self.prefs.agent_animation, &mut buf);
            let color =
                egui::ColorImage::from_rgba_premultiplied([Fire::COLS, Fire::DRAW_ROWS], &buf);
            match &mut self.fire_texture {
                Some(tex) => tex.set(color, egui::TextureOptions::NEAREST),
                None => {
                    self.fire_texture =
                        Some(ctx.load_texture("fire", color, egui::TextureOptions::NEAREST));
                }
            }
        }

        // Faces tick every 0.3s like the macOS TimelineView.
        self.face_frame = (self.started.elapsed().as_secs_f64() / 0.3) as usize;

        let music = self.music_rx.borrow().clone();
        let battery = self.battery_rx.borrow().clone();
        let hud = self.hud_rx.borrow().clone();
        let usage = self.usage_rx.borrow().clone();
        let shelf = self.shelf_rx.borrow().clone();
        let agenda = self.agenda_rx.borrow().clone();
        let github = self.github_rx.borrow().clone();
        let work = self.work_rx.borrow().clone();
        let containers = self.containers_rx.borrow().clone();
        self.sync_artwork(ctx, &music);

        let view = ui::View {
            prefs: &self.prefs,
            agents: &snap,
            music: &music,
            battery: &battery,
            hud: &hud,
            usage: &usage,
            shelf: &shelf,
            agenda: &agenda,
            github: &github,
            work: &work,
            containers: &containers,
            fire_tex: self.fire_texture.as_ref(),
            art_tex: self.art_tex.as_ref().map(|(_, t)| t),
            burning,
            face_frame: self.face_frame,
            fire_accent: self.fire.accent(self.prefs.agent_animation),
            time: self.started.elapsed().as_secs_f64(),
            t: self.open_spring.pos,
        };
        let (shape_rect, actions) = ui::draw_notch(ctx, &view, &mut self.ui_state);
        let transient = hud.visible() || battery.just_changed();
        self.last_shape_rect = shape_rect;
        let mut quit = false;
        for action in actions {
            if matches!(action, ui::Action::Quit) {
                quit = true;
            } else {
                self.apply(action);
            }
        }
        while let Some(ev) = self.tray.poll() {
            match ev {
                TrayAction::Settings => self.ui_state.settings_open = true,
                TrayAction::Quit => quit = true,
            }
        }
        if self.ui_state.settings_open {
            ui::settings::show_window(
                ctx,
                &mut self.prefs,
                &mut self.ui_state.settings_tab,
                &mut self.ui_state.settings_open,
                &mut quit,
            );
        }
        if quit {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }

        // Open/animating → full-window input so mouse-leave reaches egui.
        // Closed → pill-only so chrome underneath stays clickable.
        // Threshold 0.08 (not 0.01) avoids XShape thrash while spring settles.
        let capture_full = self.open_spring.pos > 0.08 || want_open;
        let win_size = ctx.screen_rect().size();
        self.overlay
            .set_hit_rect(shape_rect, scale, capture_full, win_size);

        let wants_keyboard = ctx.memory(|m| m.focused().is_some());
        let _ =
            self.overlay
                .update_mouse_passthrough(shape_rect, scale, win_origin, wants_keyboard);

        // HUD/charger pills expire on a timer; keep ticking so they disappear on time.
        let delay =
            compute_repaint_delay(expanded, spring_moving || transient, burning, music.playing);
        ctx.request_repaint_after(delay);
    }
}

impl BullshitNotchApp {
    /// Re-upload artwork texture only when the track's art changes.
    fn sync_artwork(&mut self, ctx: &egui::Context, music: &NowPlayingSnapshot) {
        match &music.artwork {
            Some(img) if self.art_tex.as_ref().map(|(k, _)| k) != Some(&music.art_key) => {
                let tex =
                    ctx.load_texture("artwork", (**img).clone(), egui::TextureOptions::LINEAR);
                self.art_tex = Some((music.art_key.clone(), tex));
            }
            None => self.art_tex = None,
            _ => {}
        }
    }

    fn apply(&mut self, action: ui::Action) {
        match action {
            ui::Action::Media(cmd) => crate::stores::now_playing::send(cmd),
            ui::Action::SetLimits(h, session, weekly) => {
                self.prefs.set_limits(h, session, weekly);
                let _ = self.prefs.save();
            }
            ui::Action::RefreshUsage => crate::stores::usage::refresh_now(),
            ui::Action::ShelfAdd(paths) => {
                crate::stores::shelf::add(paths);
                self.ui_state.tab = ui::NotchTab::Shelf;
            }
            ui::Action::ShelfRemove(path) => crate::stores::shelf::remove(&path),
            ui::Action::ShelfClear => crate::stores::shelf::clear(),
            ui::Action::Reveal(path) => platform::process::reveal_path(&path),
            ui::Action::OpenPath(path) => platform::process::open_path(&path),
            ui::Action::OpenUrl(url) => platform::process::open_url(&url),
            ui::Action::RefreshGit => crate::stores::github::refresh_now(),
            ui::Action::RefreshContainers => crate::stores::containers::refresh_now(),
            ui::Action::AddProject(name, path, agent) => crate::stores::work::add_project(name, path, agent),
            ui::Action::RemoveProject(id) => crate::stores::work::remove_project(&id),
            ui::Action::StartProject(id) => crate::stores::work::start_service(&id),
            ui::Action::StopProject(id) => crate::stores::work::stop_service(&id),
            ui::Action::LaunchTerm(id) => {
                if let Some(p) = self.work_rx.borrow().projects.iter().find(|p| p.id == id) {
                    crate::stores::work::launch_terminal(self.prefs.preferred_terminal, &p.expanded_path(), None);
                }
            }
            ui::Action::LaunchAgent(id) => {
                if let Some(p) = self.work_rx.borrow().projects.iter().find(|p| p.id == id) {
                    crate::stores::work::launch_terminal(
                        self.prefs.preferred_terminal,
                        &p.expanded_path(),
                        Some(&p.agent_command),
                    );
                }
            }
            ui::Action::ContainerCmd(cli, id, verb) => crate::stores::containers::container_action(&cli, &id, &verb),
            ui::Action::OpenSettings => self.ui_state.settings_open = true,
            ui::Action::Quit => {}
        }
    }
}

impl AgentSnapshot {
    fn refresh_blocking(claude_dir: &PathBuf, state: &mut AgentParseState) -> Self {
        crate::stores::agents::refresh_from_dirs(claude_dir, state)
    }
}

fn dirs_home() -> PathBuf {
    directories::UserDirs::new()
        .map(|u| u.home_dir().to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."))
}

fn dirs_claude() -> PathBuf {
    dirs_home().join(".claude")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_scheduler_sleeps_when_idle_and_paces_animations() {
        assert_eq!(
            compute_repaint_delay(true, true, false, false),
            Duration::from_millis(16)
        );
        assert_eq!(
            compute_repaint_delay(true, false, false, false),
            Duration::from_millis(50)
        );
        assert_eq!(
            compute_repaint_delay(false, false, true, false),
            Duration::from_millis(80)
        );
        assert_eq!(
            compute_repaint_delay(false, false, false, true),
            Duration::from_millis(440)
        );
        assert_eq!(
            compute_repaint_delay(false, false, false, false),
            Duration::from_millis(2000)
        );
    }
}
