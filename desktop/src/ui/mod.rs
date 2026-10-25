pub mod wings;

use crate::config::Prefs;
use crate::palette::Palette;
use crate::shape::NotchShape;
use crate::stores::agents::{Agent, AgentSnapshot};
use crate::stores::battery::BatterySnapshot;
use crate::stores::hud::HudSnapshot;
use crate::stores::now_playing::{MediaCommand, NowPlayingSnapshot};
use eframe::egui::{self, Color32, Mesh, Pos2, Rect, Sense, Shape, Stroke, TextureId, Vec2};
use eframe::epaint::Vertex;

/// Everything one frame of the notch needs to draw.
pub struct View<'a> {
    pub prefs: &'a Prefs,
    pub agents: &'a AgentSnapshot,
    pub music: &'a NowPlayingSnapshot,
    pub battery: &'a BatterySnapshot,
    pub hud: &'a HudSnapshot,
    pub fire_tex: Option<&'a egui::TextureHandle>,
    pub art_tex: Option<&'a egui::TextureHandle>,
    pub burning: bool,
    pub face_frame: usize,
    pub fire_accent: [u8; 4],
    /// Seconds since launch, for decorative animation.
    pub time: f64,
    /// Open spring position 0..1.
    pub t: f32,
}

/// Side effects requested by the UI, applied by the app after the frame.
#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    Media(MediaCommand),
}

pub const CLOSED_BASE_W: f32 = 200.0;
pub const OPEN_W: f32 = 620.0;
pub const OPEN_H: f32 = 280.0;

/// Draw the notch silhouette + closed wings or expanded panel.
/// Returns the logical shape rect used for hit-testing, plus requested actions.
pub fn draw_notch(ctx: &egui::Context, v: &View) -> (Rect, Vec<Action>) {
    let t = v.t.clamp(0.0, 1.0);
    let shape = NotchShape::lerp(NotchShape::collapsed(), NotchShape::expanded(), t);
    let prefs = v.prefs;
    let mut actions = Vec::new();

    let screen = ctx.screen_rect();
    // macOS closed ≈ physical notch (~200) + idleWidth wings (48).
    let closed_w = CLOSED_BASE_W + prefs.idle_width + prefs.width_adjust;
    let width = closed_w + (OPEN_W - closed_w) * t;
    let closed_h = 30.0 + prefs.height_adjust;
    let height = closed_h + (OPEN_H - closed_h) * t;

    let rect = Rect::from_center_size(Pos2::new(screen.center().x, height * 0.5), Vec2::new(width, height));

    egui::CentralPanel::default().frame(egui::Frame::none()).show(ctx, |ui| {
        let painter = ui.painter().clone();
        let pts = shape.sample_points(rect, 20);
        if pts.len() >= 3 {
            painter.add(Shape::convex_polygon(pts.clone(), Color32::from_rgb(8, 8, 10), Stroke::NONE));

            // Fire clipped to notch path (== macOS `.clipShape(NotchShape)`).
            if v.burning && t < 0.35 {
                if let Some(tex) = v.fire_tex {
                    let [r, g, b, _] = v.fire_accent;
                    let wash = Color32::from_rgba_unmultiplied(r, g, b, 70);
                    painter.add(Shape::convex_polygon(pts.clone(), wash, Stroke::NONE));
                    painter.add(Shape::mesh(textured_convex_mesh(tex.id(), &pts, rect, Color32::WHITE)));
                }
            }

            if t > 0.05 {
                let fade = ((t - 0.05) / 0.6).clamp(0.0, 1.0);
                let music_pal = (prefs.music_ambient).then(|| v.music.active_palette()).flatten();
                if let Some(pal) = music_pal {
                    let level = prefs.music_ambient_intensity as f32 * if v.music.playing { 1.0 } else { 0.58 };
                    painter.add(Shape::mesh(ambient_mesh(&pts, rect, &pal, level * fade, v.time)));
                } else if let Some(acc) = wings::accent(v) {
                    painter.add(Shape::mesh(glow_mesh(&pts, rect, acc, 0.22 * fade)));
                }
            }

            painter.add(Shape::closed_line(pts.clone(), Stroke::new(1.0_f32, Color32::from_white_alpha(if t > 0.5 { 40 } else { 22 }))));
        }

        if t < 0.35 {
            let inner = Rect::from_min_max(
                Pos2::new(rect.min.x + shape.flare, rect.min.y),
                Pos2::new(rect.max.x - shape.flare, rect.max.y),
            );
            wings::draw(&painter, v, inner);
            if !v.burning && wings::activity(v) == wings::Activity::None {
                painter.text(rect.center(), egui::Align2::CENTER_CENTER, "bullshit", egui::FontId::proportional(11.0), Color32::from_gray(120));
            }
        } else {
            draw_expanded(ui, rect, &shape, v, &mut actions);
        }

        let _ = ui.allocate_rect(rect.expand(4.0), Sense::hover());
    });

    (rect, actions)
}

/// Fan-triangulate a convex notch path and map the fire texture across `rect` UVs.
fn textured_convex_mesh(tex: TextureId, pts: &[Pos2], rect: Rect, tint: Color32) -> Mesh {
    let mut mesh = Mesh::with_texture(tex);
    let w = rect.width().max(1.0);
    let h = rect.height().max(1.0);
    for p in pts {
        let uv = Pos2::new(((p.x - rect.min.x) / w).clamp(0.0, 1.0), ((p.y - rect.min.y) / h).clamp(0.0, 1.0));
        mesh.vertices.push(Vertex { pos: *p, uv, color: tint });
    }
    for i in 1..pts.len().saturating_sub(1) {
        mesh.indices.extend_from_slice(&[0, i as u32, (i + 1) as u32]);
    }
    mesh
}

/// Concentric-ring mesh over the notch path; vertex colours come from `color_at`.
/// Stands in for SwiftUI `RadialGradient`s clipped to the shape.
fn shaded_mesh(pts: &[Pos2], center: Pos2, color_at: impl Fn(Pos2) -> Color32) -> Mesh {
    const RINGS: [f32; 5] = [0.0, 0.25, 0.5, 0.75, 1.0];
    let n = pts.len();
    let mut mesh = Mesh::default();
    for &k in &RINGS {
        for p in pts {
            let q = center + (*p - center) * k;
            mesh.colored_vertex(q, color_at(q));
        }
    }
    for r in 0..RINGS.len() - 1 {
        for i in 0..n {
            let j = (i + 1) % n;
            let a = (r * n + i) as u32;
            let b = (r * n + j) as u32;
            let c = ((r + 1) * n + i) as u32;
            let d = ((r + 1) * n + j) as u32;
            mesh.add_triangle(a, c, d);
            mesh.add_triangle(a, d, b);
        }
    }
    mesh
}

fn premul(c: Color32, a: f32) -> Color32 {
    let a = a.clamp(0.0, 1.0);
    Color32::from_rgba_premultiplied(
        (c.r() as f32 * a) as u8,
        (c.g() as f32 * a) as u8,
        (c.b() as f32 * a) as u8,
        (255.0 * a) as u8,
    )
}

/// Accent glow rising from the bottom centre of the open panel.
fn glow_mesh(pts: &[Pos2], rect: Rect, accent: Color32, strength: f32) -> Mesh {
    let origin = Pos2::new(rect.center().x, rect.max.y);
    let radius = rect.width() * 0.5;
    shaded_mesh(pts, rect.center(), move |p| {
        let f = (1.0 - p.distance(origin) / radius).max(0.0);
        premul(accent, strength * f * f)
    })
}

/// Three breathing colour blobs (port of `expandedMusicAmbient`).
fn ambient_mesh(pts: &[Pos2], rect: Rect, pal: &Palette, level: f32, time: f64) -> Mesh {
    let breathe = (0.5 - 0.5 * (time * std::f64::consts::TAU / 6.2).cos()) as f32;
    let at = |x0: f32, y0: f32, x1: f32, y1: f32| {
        Pos2::new(
            rect.min.x + rect.width() * (x0 + (x1 - x0) * breathe),
            rect.min.y + rect.height() * (y0 + (y1 - y0) * breathe),
        )
    };
    let blobs = [
        (pal.primary, 0.34, at(0.14, 0.88, 0.22, 0.55), 270.0 + 70.0 * breathe),
        (pal.secondary, 0.30, at(0.86, 0.46, 0.78, 0.86), 260.0 + 60.0 * breathe),
        (pal.tertiary, 0.24, at(0.48, 0.72, 0.52, 0.96), 240.0),
    ];
    let top = rect.min.y;
    let h = rect.height();
    shaded_mesh(pts, rect.center(), move |p| {
        let (mut r, mut g, mut b, mut a) = (0.0f32, 0.0, 0.0, 0.0);
        for (c, op, center, rad) in blobs {
            let f = (1.0 - p.distance(center) / rad).max(0.0);
            let w = op * level * f;
            r += c.r() as f32 * w;
            g += c.g() as f32 * w;
            b += c.b() as f32 * w;
            a += w;
        }
        // Darken toward the top so the panel melts into the bezel.
        let top_fade = ((p.y - top) / (h * 0.32)).clamp(0.0, 1.0);
        let k = top_fade.max(0.18);
        Color32::from_rgba_premultiplied(
            (r * k).min(255.0) as u8,
            (g * k).min(255.0) as u8,
            (b * k).min(255.0) as u8,
            (a * k * 255.0).min(255.0) as u8,
        )
    })
}

fn draw_expanded(ui: &mut egui::Ui, rect: Rect, shape: &NotchShape, v: &View, _actions: &mut Vec<Action>) {
    let pad_x = shape.flare + 10.0;
    let pad_top = shape.flare_depth + 10.0;
    let pad_bot = shape.bottom + 8.0;
    let inner = Rect::from_min_max(
        Pos2::new(rect.min.x + pad_x, rect.min.y + pad_top),
        Pos2::new(rect.max.x - pad_x, rect.max.y - pad_bot),
    );
    let snap = v.agents;

    ui.allocate_new_ui(egui::UiBuilder::new().max_rect(inner), |ui| {
        ui.spacing_mut().item_spacing = Vec2::new(8.0, 6.0);
        ui.vertical(|ui| {
            ui.horizontal(|ui| {
                ui.label(egui::RichText::new("Agents").color(Color32::WHITE).size(13.0).strong());
                ui.add_space(6.0);
                ui.label(egui::RichText::new(format!("{} busy", snap.busy_count())).color(Color32::from_rgb(255, 160, 60)).size(11.0));
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.label(egui::RichText::new(format!("{} sessions", snap.agents.len())).color(Color32::from_gray(130)).size(10.0));
                });
            });
            ui.add_space(8.0);
            egui::ScrollArea::vertical().max_height((inner.height() - 36.0).max(40.0)).show(ui, |ui| {
                if snap.agents.is_empty() {
                    ui.label(egui::RichText::new("No live Claude sessions").color(Color32::from_gray(140)).size(12.0));
                }
                for agent in &snap.agents {
                    agent_row(ui, agent, snap, v.face_frame);
                    ui.add_space(2.0);
                    ui.separator();
                    ui.add_space(2.0);
                }
            });
        });
    });
}

fn agent_row(ui: &mut egui::Ui, agent: &Agent, snap: &AgentSnapshot, face_frame: usize) {
    let face = Agent::face(agent.status.as_deref(), face_frame);
    let title = agent.name.clone().unwrap_or_else(|| agent.session_id.clone());
    let tokens = snap.tokens.get(&agent.session_id).copied().unwrap_or((0, 0));
    ui.horizontal(|ui| {
        ui.add_space(2.0);
        ui.label(egui::RichText::new(face).monospace().color(Color32::from_rgb(255, 180, 80)).size(12.0));
        ui.add_space(6.0);
        ui.vertical(|ui| {
            ui.label(egui::RichText::new(title).color(Color32::WHITE).size(12.0));
            ui.label(
                egui::RichText::new(format!(
                    "{} · in {} out {}",
                    agent.status.as_deref().unwrap_or("idle"),
                    compact(tokens.0),
                    compact(tokens.1)
                ))
                .color(Color32::from_gray(140))
                .size(10.0),
            );
        });
    });
}

pub fn compact(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}k", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}
