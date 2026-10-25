use crate::config::Prefs;
use crate::fire::Fire;
use crate::platform::{self, Overlay};
use crate::shape::Spring;
use crate::stores::agents::{AgentParseState, AgentSnapshot};
use crate::ui;
use eframe::egui;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::watch;

const WINDOW_W: f32 = 680.0;
const WINDOW_H: f32 = 420.0;

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
}

impl BullshitNotchApp {
    pub fn new(cc: &eframe::CreationContext<'_>, demo: bool) -> Self {
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
            std::thread::spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("tokio");
                rt.block_on(async move {
                    let mut state = AgentParseState::default();
                    loop {
                        let snap = AgentSnapshot::refresh_blocking(&claude_dir, &mut state);
                        let _ = tx.send(snap);
                        ctx.request_repaint();
                        tokio::time::sleep(Duration::from_secs(3)).await;
                    }
                });
            });
        }

        Self {
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
        let mon = ctx.input(|i| i.viewport().monitor_size).unwrap_or(egui::vec2(1920.0, 1080.0));
        let x = ((mon.x - WINDOW_W) * 0.5).max(0.0);
        ctx.send_viewport_cmd(egui::ViewportCommand::OuterPosition(egui::pos2(x, 0.0)));
        ctx.send_viewport_cmd(egui::ViewportCommand::InnerSize(egui::vec2(WINDOW_W, WINDOW_H)));
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
        let busy = snap.busy_count();
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

        let want_open = self.prefs.open_on_hover
            && hovering
            && (already_open || self.reopen_armed);
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
            self.fire
                .render_rgba(self.prefs.agent_animation, &mut buf);
            let color = egui::ColorImage::from_rgba_premultiplied(
                [Fire::COLS, Fire::DRAW_ROWS],
                &buf,
            );
            match &mut self.fire_texture {
                Some(tex) => tex.set(color, egui::TextureOptions::NEAREST),
                None => {
                    self.fire_texture = Some(ctx.load_texture(
                        "fire",
                        color,
                        egui::TextureOptions::NEAREST,
                    ));
                }
            }
        }

        self.face_frame = self.face_frame.wrapping_add(1);

        let shape_rect = ui::draw_notch(
            ctx,
            &self.prefs,
            &self.open_spring,
            &snap,
            self.fire_texture.as_ref(),
            burning,
            self.face_frame,
            self.fire.accent(self.prefs.agent_animation),
        );
        self.last_shape_rect = shape_rect;

        // Open/animating → full-window input so mouse-leave reaches egui.
        // Closed → pill-only so chrome underneath stays clickable.
        // Threshold 0.08 (not 0.01) avoids XShape thrash while spring settles.
        let capture_full = self.open_spring.pos > 0.08 || want_open;
        let win_size = ctx.screen_rect().size();
        self.overlay
            .set_hit_rect(shape_rect, scale, capture_full, win_size);

        let wants_keyboard = ctx.memory(|m| m.focused().is_some());
        let _ = self.overlay.update_mouse_passthrough(
            shape_rect,
            scale,
            win_origin,
            wants_keyboard,
        );

        let delay = compute_repaint_delay(expanded, spring_moving, burning, false);
        ctx.request_repaint_after(delay);
    }
}

impl AgentSnapshot {
    fn refresh_blocking(claude_dir: &PathBuf, state: &mut AgentParseState) -> Self {
        crate::stores::agents::refresh_from_dirs(claude_dir, state)
    }
}

fn dirs_claude() -> PathBuf {
    directories::UserDirs::new()
        .map(|u| u.home_dir().join(".claude"))
        .unwrap_or_else(|| PathBuf::from(".claude"))
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
