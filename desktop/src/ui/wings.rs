//! Closed-notch live activity wings (port of `NotchView.collapsed` / `leftWing` / `rightWing`).

use super::View;
use crate::stores::hud::HudKind;
use eframe::egui::{self, Color32, Pos2, Rect, Rounding, Shape, Stroke, Vec2};

/// What shows beside the closed notch, highest priority first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Activity {
    None,
    Hud,
    Battery,
    Music,
    Agents,
}

pub fn activity(v: &View) -> Activity {
    if v.prefs.replace_hud && v.hud.visible() {
        Activity::Hud
    } else if v.prefs.live_battery && v.battery.just_changed() {
        Activity::Battery
    } else if v.prefs.live_music && v.music.playing {
        Activity::Music
    } else if v.prefs.live_agents && v.agents.busy_count() > 0 {
        Activity::Agents
    } else {
        Activity::None
    }
}

/// Glow colour from the live activity (tints the open panel).
pub fn accent(v: &View) -> Option<Color32> {
    let fire = || {
        let [r, g, b, _] = v.fire_accent;
        Color32::from_rgb(r, g, b)
    };
    match activity(v) {
        Activity::Agents => Some(fire()),
        Activity::Music => Some(
            v.music
                .active_palette()
                .map(|p| p.primary)
                .unwrap_or(Color32::WHITE),
        ),
        Activity::Battery => Some(Color32::from_rgb(60, 220, 100)),
        Activity::Hud => Some(Color32::WHITE),
        Activity::None => v.burning.then(fire),
    }
}

/// Paint the wing contents inside the closed pill. `inner` excludes the flare padding.
pub fn draw(painter: &egui::Painter, v: &View, inner: Rect) {
    let wing = (v.prefs.idle_width * 0.5).max(0.0);
    if wing < 6.0 {
        return;
    }
    let h = inner.height();
    let left = Rect::from_min_size(inner.min, Vec2::new(wing, h));
    let right = Rect::from_min_size(
        Pos2::new(inner.max.x - wing, inner.min.y),
        Vec2::new(wing, h),
    );
    let glyph = (h - 6.0).clamp(8.0, 13.0);

    match activity(v) {
        Activity::Hud => {
            if v.hud.kind == HudKind::Brightness {
                sun(painter, left.center(), glyph * 0.5, Color32::WHITE);
            } else {
                speaker(
                    painter,
                    left.center(),
                    glyph,
                    v.hud.muted || v.hud.level <= 0.0,
                );
            }
            let bar = Vec2::new((wing - 8.0).clamp(10.0, 42.0), (h - 6.0).clamp(3.0, 5.0));
            level_bar(
                painter,
                Rect::from_center_size(right.center(), bar),
                if v.hud.muted { 0.0 } else { v.hud.level },
            );
        }
        Activity::Battery => {
            let c = if v.battery.plugged_in {
                Color32::from_rgb(60, 220, 100)
            } else {
                Color32::WHITE
            };
            bolt(painter, left.center(), glyph, c);
            painter.text(
                right.center(),
                egui::Align2::CENTER_CENTER,
                format!("{}%", v.battery.level),
                egui::FontId::proportional((h * 0.36).clamp(8.0, 11.0)),
                if v.battery.charging {
                    Color32::from_rgb(60, 220, 100)
                } else {
                    Color32::WHITE
                },
            );
        }
        Activity::Music => {
            let icon = (h - 4.0).min(wing - 4.0).clamp(10.0, 22.0);
            let r = Rect::from_center_size(left.center(), Vec2::splat(icon));
            artwork(painter, r, v.art_tex, (icon * 0.25).min(5.0));
            let viz = Vec2::new((wing - 6.0).clamp(10.0, 22.0), (h - 6.0).clamp(6.0, 14.0));
            visualizer(
                painter,
                Rect::from_center_size(right.center(), viz),
                v.music.playing,
                v.time,
                accent(v),
            );
        }
        Activity::Agents | Activity::None => {}
    }
}

pub fn artwork(painter: &egui::Painter, r: Rect, tex: Option<&egui::TextureHandle>, radius: f32) {
    match tex {
        Some(t) => {
            let mut shape =
                egui::epaint::RectShape::filled(r, Rounding::same(radius), Color32::WHITE);
            shape.fill_texture_id = t.id();
            shape.uv = Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0));
            painter.add(shape);
        }
        None => {
            painter.rect_filled(r, radius, Color32::from_gray(50));
            painter.text(
                r.center(),
                egui::Align2::CENTER_CENTER,
                "♪",
                egui::FontId::proportional(r.height() * 0.6),
                Color32::from_gray(160),
            );
        }
    }
}

/// Decorative 4-bar visualizer. ponytail: not wired to audio, like the macOS one.
pub fn visualizer(
    painter: &egui::Painter,
    r: Rect,
    playing: bool,
    time: f64,
    tint: Option<Color32>,
) {
    let bars = 4;
    let gap = 2.0;
    let w = ((r.width() - gap * (bars as f32 - 1.0)) / bars as f32).max(1.5);
    let c = tint.unwrap_or(Color32::WHITE);
    for i in 0..bars {
        let phase = time * (5.0 + i as f64 * 1.7) + i as f64 * 1.3;
        let f = if playing {
            0.25 + 0.75 * (0.5 + 0.5 * phase.sin()) as f32
        } else {
            0.2
        };
        let bh = (r.height() * f).max(2.0);
        let x = r.min.x + i as f32 * (w + gap);
        painter.rect_filled(
            Rect::from_min_size(Pos2::new(x, r.center().y - bh * 0.5), Vec2::new(w, bh)),
            w * 0.5,
            c,
        );
    }
}

pub fn level_bar(painter: &egui::Painter, r: Rect, value: f32) {
    let rad = r.height() * 0.5;
    painter.rect_filled(r, rad, Color32::from_white_alpha(50));
    let mut fill = r;
    fill.max.x = r.min.x + r.width() * value.clamp(0.0, 1.0);
    if fill.width() > 0.5 {
        painter.rect_filled(fill, rad, Color32::WHITE);
    }
}

pub fn bolt(painter: &egui::Painter, c: Pos2, size: f32, color: Color32) {
    let s = size * 0.5;
    let pts = vec![
        Pos2::new(c.x + 0.15 * s, c.y - s),
        Pos2::new(c.x - 0.55 * s, c.y + 0.15 * s),
        Pos2::new(c.x - 0.05 * s, c.y + 0.15 * s),
        Pos2::new(c.x - 0.15 * s, c.y + s),
        Pos2::new(c.x + 0.55 * s, c.y - 0.15 * s),
        Pos2::new(c.x + 0.05 * s, c.y - 0.15 * s),
    ];
    painter.add(Shape::Path(egui::epaint::PathShape {
        points: pts,
        closed: true,
        fill: color,
        stroke: Stroke::NONE.into(),
    }));
}

pub fn speaker(painter: &egui::Painter, c: Pos2, size: f32, muted: bool) {
    let s = size * 0.5;
    let body = vec![
        Pos2::new(c.x - s, c.y - 0.3 * s),
        Pos2::new(c.x - 0.5 * s, c.y - 0.3 * s),
        Pos2::new(c.x, c.y - 0.8 * s),
        Pos2::new(c.x, c.y + 0.8 * s),
        Pos2::new(c.x - 0.5 * s, c.y + 0.3 * s),
        Pos2::new(c.x - s, c.y + 0.3 * s),
    ];
    painter.add(Shape::convex_polygon(body, Color32::WHITE, Stroke::NONE));
    let stroke = Stroke::new(1.2_f32, Color32::WHITE);
    if muted {
        painter.line_segment(
            [
                Pos2::new(c.x + 0.3 * s, c.y - 0.4 * s),
                Pos2::new(c.x + s, c.y + 0.4 * s),
            ],
            stroke,
        );
        painter.line_segment(
            [
                Pos2::new(c.x + 0.3 * s, c.y + 0.4 * s),
                Pos2::new(c.x + s, c.y - 0.4 * s),
            ],
            stroke,
        );
    } else {
        for r in [0.45, 0.85] {
            let arc: Vec<Pos2> = (0..=8)
                .map(|i| {
                    let a = -0.9 + 1.8 * i as f32 / 8.0;
                    Pos2::new(c.x + 0.1 * s + r * s * a.cos(), c.y + r * s * a.sin())
                })
                .collect();
            painter.add(Shape::line(arc, stroke));
        }
    }
}

pub fn sun(painter: &egui::Painter, c: Pos2, r: f32, color: Color32) {
    painter.circle_filled(c, r * 0.45, color);
    let stroke = Stroke::new(1.2_f32, color);
    for i in 0..8 {
        let a = i as f32 * std::f32::consts::TAU / 8.0;
        let d = Vec2::new(a.cos(), a.sin());
        painter.line_segment([c + d * r * 0.7, c + d * r], stroke);
    }
}
