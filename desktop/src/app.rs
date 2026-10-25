use crate::config::Prefs;
use crate::fire::Fire;
use crate::platform::Overlay;
use crate::shape::Spring;
use crate::stores::agents::{AgentParseState, AgentSnapshot};
use crate::ui;
use eframe::egui;
use std::path::PathBuf;
use std::time::Duration;
use tokio::sync::watch;

pub fn compute_repaint_delay(
    expanded: bool,
    spring_moving: bool,
    agents_burning: bool,
    music_playing: bool,
) -> Duration {
    if spring_moving || expanded && spring_moving {
        return Duration::from_millis(16);
    }
    if spring_moving {
        return Duration::from_millis(16);
    }
    // Open with settled spring: still modest pace for face animation
    if expanded {
        return Duration::from_millis(80);
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
    open_spring: Spring,
    fire: Fire,
    fire_texture: Option<egui::TextureHandle>,
    agents_rx: watch::Receiver<AgentSnapshot>,
    face_frame: usize,
    demo: bool,
    last_shape_rect: egui::Rect,
}

impl BullshitNotchApp {
    pub fn new(cc: &eframe::CreationContext<'_>, demo: bool) -> Self {
        let prefs = Prefs::load();
        let (tx, rx) = watch::channel(if demo {
            AgentSnapshot::demo()
        } else {
            AgentSnapshot::default()
        });

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
            open_spring: Spring::new(0.0),
            fire: Fire::new(),
            fire_texture: None,
            agents_rx: rx,
            face_frame: 0,
            demo,
            last_shape_rect: egui::Rect::NOTHING,
        }
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

        let snap = self.agents_rx.borrow().clone();
        let busy = snap.busy_count();
        let burning = (self.prefs.live_agents && busy > 0)
            || self.prefs.agent_animation_always_on
            || (self.demo && busy > 0);

        let pointer = ctx.input(|i| i.pointer.hover_pos());
        let want_open = if self.prefs.open_on_hover {
            pointer
                .map(|p| self.last_shape_rect.expand(4.0).contains(p) || self.open_spring.pos > 0.5)
                .unwrap_or(self.open_spring.pos > 0.5)
        } else {
            false
        };
        self.open_spring.target = if want_open { 1.0 } else { 0.0 };
        let dt = ctx.input(|i| i.stable_dt).min(0.05);
        let spring_moving = self.open_spring.step(dt, 0.45, 0.62);
        let expanded = self.open_spring.pos > 0.15;

        if burning && !expanded {
            self.fire.step();
        } else if !burning && self.fire.steps > 0 && !self.prefs.agent_animation_always_on {
            self.fire = Fire::new();
        }

        if burning {
            let mut buf = [0u8; Fire::COLS * Fire::DRAW_ROWS * 4];
            self.fire
                .render_rgba(self.prefs.agent_animation, &mut buf);
            let color = egui::ColorImage::from_rgba_unmultiplied(
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

        let scale = ctx.pixels_per_point();
        self.overlay.set_hit_rect(shape_rect, scale);

        let screen = ctx
            .input(|i| i.viewport().outer_rect)
            .map(|r| r.min)
            .unwrap_or(egui::pos2(0.0, 0.0));
        let wants_keyboard = ctx.memory(|m| m.focused().is_some());
        let _ = self.overlay.update_mouse_passthrough(
            shape_rect,
            scale,
            screen,
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
