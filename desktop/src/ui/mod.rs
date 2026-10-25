pub mod agents;
pub mod home;
pub mod shelf;
pub mod wings;

use crate::config::Prefs;
use crate::palette::Palette;
use crate::shape::NotchShape;
use crate::stores::agenda::AgendaSnapshot;
use crate::stores::agents::{AgentSnapshot, Harness};
use crate::stores::battery::BatterySnapshot;
use crate::stores::hud::HudSnapshot;
use crate::stores::now_playing::{MediaCommand, NowPlayingSnapshot};
use crate::stores::shelf::ShelfSnapshot;
use crate::stores::usage::UsageSnapshot;
use eframe::egui::{self, Color32, Mesh, Pos2, Rect, Sense, Shape, Stroke, TextureId, Vec2};
use eframe::epaint::Vertex;

/// Everything one frame of the notch needs to draw.
pub struct View<'a> {
    pub prefs: &'a Prefs,
    pub agents: &'a AgentSnapshot,
    pub music: &'a NowPlayingSnapshot,
    pub battery: &'a BatterySnapshot,
    pub hud: &'a HudSnapshot,
    pub usage: &'a UsageSnapshot,
    pub shelf: &'a ShelfSnapshot,
    pub agenda: &'a AgendaSnapshot,
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
    /// (harness, 5h limit, weekly limit) in effective tokens.
    SetLimits(Harness, u64, u64),
    RefreshUsage,
    ShelfAdd(Vec<std::path::PathBuf>),
    ShelfRemove(std::path::PathBuf),
    ShelfClear,
    Reveal(std::path::PathBuf),
    OpenPath(std::path::PathBuf),
    OpenUrl(String),
}

/// Panel UI state that survives frames (not persisted).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum NotchTab {
    #[default]
    Home,
    Shelf,
    Workspace,
}

#[derive(Default)]
pub struct UiState {
    pub tab: NotchTab,
    pub agent_filter: Option<Harness>,
    pub show_daily: Vec<Harness>,
    pub custom_limits: Option<(Harness, String, String)>,
}

/// Rounded translucent card (`NotchCardBackground`).
pub fn card<R>(ui: &mut egui::Ui, add: impl FnOnce(&mut egui::Ui) -> R) -> R {
    egui::Frame::none()
        .fill(crate::ui::white(9))
        .stroke(Stroke::new(1.0_f32, crate::ui::white(15)))
        .rounding(10.0)
        .inner_margin(8.0)
        .show(ui, add)
        .inner
}

/// Small capsule label.
pub fn pill(ui: &mut egui::Ui, text: &str, strong: bool) -> egui::Response {
    egui::Frame::none()
        .fill(crate::ui::white(if strong { 40 } else { 30 }))
        .rounding(8.0)
        .inner_margin(egui::Margin::symmetric(6.0, 1.0))
        .show(ui, |ui| ui.label(egui::RichText::new(text).size(10.0).strong().color(Color32::WHITE)))
        .response
}

pub const CLOSED_BASE_W: f32 = 200.0;
pub const OPEN_W: f32 = 620.0;
pub const OPEN_H: f32 = 340.0;

/// Draw the notch silhouette + closed wings or expanded panel.
/// Returns the logical shape rect used for hit-testing, plus requested actions.
pub fn draw_notch(ctx: &egui::Context, v: &View, st: &mut UiState) -> (Rect, Vec<Action>) {
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

    let rect = Rect::from_center_size(
        Pos2::new(screen.center().x, height * 0.5),
        Vec2::new(width, height),
    );

    egui::CentralPanel::default()
        .frame(egui::Frame::none())
        .show(ctx, |ui| {
            let painter = ui.painter().clone();
            let pts = shape.sample_points(rect, 20);
            if pts.len() >= 3 {
                painter.add(Shape::convex_polygon(
                    pts.clone(),
                    Color32::from_rgb(8, 8, 10),
                    Stroke::NONE,
                ));

                // Fire clipped to notch path (== macOS `.clipShape(NotchShape)`).
                if v.burning && t < 0.35 {
                    if let Some(tex) = v.fire_tex {
                        let [r, g, b, _] = v.fire_accent;
                        let wash = Color32::from_rgba_unmultiplied(r, g, b, 70);
                        painter.add(Shape::convex_polygon(pts.clone(), wash, Stroke::NONE));
                        painter.add(Shape::mesh(textured_convex_mesh(
                            tex.id(),
                            &pts,
                            rect,
                            Color32::WHITE,
                        )));
                    }
                }

                if t > 0.05 {
                    let fade = ((t - 0.05) / 0.6).clamp(0.0, 1.0);
                    let rect = rect.shrink2(Vec2::new(shape.flare, 0.0));
                    let music_pal = (prefs.music_ambient)
                        .then(|| v.music.active_palette())
                        .flatten();
                    if let Some(pal) = music_pal {
                        let level = prefs.music_ambient_intensity as f32
                            * if v.music.playing { 1.0 } else { 0.58 };
                        painter.add(Shape::mesh(ambient_mesh(
                            &pts,
                            rect,
                            &pal,
                            level * fade,
                            v.time,
                        )));
                    } else if let Some(acc) = wings::accent(v) {
                        painter.add(Shape::mesh(glow_mesh(&pts, rect, acc, 0.22 * fade)));
                    }
                }

                painter.add(Shape::closed_line(
                    pts.clone(),
                    Stroke::new(
                        1.0_f32,
                        crate::ui::white(if t > 0.5 { 40 } else { 22 }),
                    ),
                ));
            }

            if t < 0.35 {
                let inner = Rect::from_min_max(
                    Pos2::new(rect.min.x + shape.flare, rect.min.y),
                    Pos2::new(rect.max.x - shape.flare, rect.max.y),
                );
                wings::draw(&painter, v, inner);
                if !v.burning && wings::activity(v) == wings::Activity::None {
                    painter.text(
                        rect.center(),
                        egui::Align2::CENTER_CENTER,
                        "bullshit",
                        egui::FontId::proportional(11.0),
                        Color32::from_gray(120),
                    );
                }
            } else {
                draw_expanded(ui, rect, &shape, v, st, &mut actions);
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
        let uv = Pos2::new(
            ((p.x - rect.min.x) / w).clamp(0.0, 1.0),
            ((p.y - rect.min.y) / h).clamp(0.0, 1.0),
        );
        mesh.vertices.push(Vertex {
            pos: *p,
            uv,
            color: tint,
        });
    }
    for i in 1..pts.len().saturating_sub(1) {
        mesh.indices
            .extend_from_slice(&[0, i as u32, (i + 1) as u32]);
    }
    mesh
}

/// Concentric-ring mesh over the notch path; vertex colours come from `color_at`.
/// Stands in for SwiftUI `RadialGradient`s clipped to the shape.
fn shaded_mesh(pts: &[Pos2], body: Rect, color_at: impl Fn(Pos2) -> Color32) -> Mesh {
    const RINGS: [f32; 5] = [0.0, 0.25, 0.5, 0.75, 1.0];
    let center = body.center();
    // The flared top ears are concave; fanning into them overlaps triangles (visible seams).
    // Clamp to the body so the fan stays star-shaped from the centre.
    let pts: Vec<Pos2> = pts.iter().map(|p| Pos2::new(p.x.clamp(body.min.x, body.max.x), p.y)).collect();
    let n = pts.len();
    let mut mesh = Mesh::default();
    for &k in &RINGS {
        for p in &pts {
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
    shaded_mesh(pts, rect, move |p| {
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
        (
            pal.primary,
            0.34,
            at(0.14, 0.88, 0.22, 0.55),
            270.0 + 70.0 * breathe,
        ),
        (
            pal.secondary,
            0.30,
            at(0.86, 0.46, 0.78, 0.86),
            260.0 + 60.0 * breathe,
        ),
        (pal.tertiary, 0.24, at(0.48, 0.72, 0.52, 0.96), 240.0),
    ];
    let top = rect.min.y;
    let h = rect.height();
    shaded_mesh(pts, rect, move |p| {
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

fn draw_expanded(
    ui: &mut egui::Ui,
    rect: Rect,
    shape: &NotchShape,
    v: &View,
    st: &mut UiState,
    actions: &mut Vec<Action>,
) {
    let pad_x = shape.flare + 10.0;
    let pad_top = shape.flare_depth + 6.0;
    let pad_bot = shape.bottom * 0.5 + 6.0;
    let inner = Rect::from_min_max(
        Pos2::new(rect.min.x + pad_x, rect.min.y + pad_top),
        Pos2::new(rect.max.x - pad_x, rect.max.y - pad_bot),
    );
    ui.allocate_new_ui(egui::UiBuilder::new().max_rect(inner), |ui| {
        ui.set_clip_rect(inner.expand(2.0));
        ui.spacing_mut().item_spacing = Vec2::new(6.0, 4.0);
        tab_bar(ui, v, st);
        ui.add_space(4.0);
        match st.tab {
            NotchTab::Home if v.prefs.tab_home => home::show(ui, v, actions),
            NotchTab::Shelf if v.prefs.tab_shelf => shelf::show(ui, v, actions),
            NotchTab::Workspace if v.prefs.tab_topbar => agents::show(ui, v, st, actions),
            _ => {
                // Hidden tab still selected — fall back to first enabled.
                if v.prefs.tab_home {
                    home::show(ui, v, actions);
                } else if v.prefs.tab_shelf {
                    shelf::show(ui, v, actions);
                } else {
                    agents::show(ui, v, st, actions);
                }
            }
        }
    });
}

fn tab_bar(ui: &mut egui::Ui, v: &View, st: &mut UiState) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 4.0;
        if v.prefs.tab_home {
            tab_pill(ui, st, NotchTab::Home, "Home");
        }
        if v.prefs.tab_shelf {
            tab_pill(ui, st, NotchTab::Shelf, "Shelf");
        }
        if v.prefs.tab_topbar {
            tab_pill(ui, st, NotchTab::Workspace, "Workspace");
        }
    });
}

fn tab_pill(ui: &mut egui::Ui, st: &mut UiState, tab: NotchTab, label: &str) {
    let on = st.tab == tab;
    let resp = egui::Frame::none()
        .fill(if on { crate::ui::white(40) } else { Color32::TRANSPARENT })
        .rounding(10.0)
        .inner_margin(egui::Margin::symmetric(8.0, 3.0))
        .show(ui, |ui| {
            ui.label(egui::RichText::new(label).size(11.0).color(if on { Color32::WHITE } else { Color32::from_gray(140) }));
        })
        .response
        .interact(egui::Sense::click());
    if resp.clicked() {
        st.tab = tab;
    }
}

/// Compact count like Swift's `.compactName` with 0…1 fraction digits: 950, 1.2K, 142K, 3.8M, 1B.
pub fn compact(n: u64) -> String {
    let (v, suffix) = match n {
        0..=999 => return n.to_string(),
        1_000..=999_999 => (n as f64 / 1e3, "K"),
        1_000_000..=999_999_999 => (n as f64 / 1e6, "M"),
        _ => (n as f64 / 1e9, "B"),
    };
    let s = if v >= 100.0 { format!("{v:.0}") } else { format!("{v:.1}") };
    format!("{}{suffix}", s.strip_suffix(".0").unwrap_or(&s))
}

#[cfg(test)]
mod tests {
    #[test]
    fn compact_matches_swift_compact_name() {
        use super::compact;
        assert_eq!(compact(950), "950");
        assert_eq!(compact(1_200), "1.2K");
        assert_eq!(compact(142_000), "142K");
        assert_eq!(compact(3_000_000), "3M");
        assert_eq!(compact(12_500_000), "12.5M");
    }
}

/// sRGB-space translucent white, like SwiftUI `.white.opacity(a/255)`.
/// (`Color32::from_white_alpha` is linear-space and comes out far too bright.)
pub const fn white(a: u8) -> Color32 {
    Color32::from_rgba_premultiplied(a, a, a, a)
}
