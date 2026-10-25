use crate::config::Prefs;
use crate::shape::{NotchShape, Spring};
use crate::stores::agents::{Agent, AgentSnapshot};
use eframe::egui::{self, Color32, Pos2, Rect, Sense, Shape, Stroke, Vec2};

/// Draw the notch silhouette + closed wings or expanded agents list.
/// Returns the logical shape rect used for hit-testing.
pub fn draw_notch(
    ctx: &egui::Context,
    prefs: &Prefs,
    open_spring: &Spring,
    snap: &AgentSnapshot,
    fire_tex: Option<&egui::TextureHandle>,
    burning: bool,
    face_frame: usize,
    accent: [u8; 4],
) -> Rect {
    let t = open_spring.pos.clamp(0.0, 1.0);
    let shape = NotchShape::lerp(NotchShape::collapsed(), NotchShape::expanded(), t);

    let screen = ctx.screen_rect();
    let closed_w = 280.0 + prefs.idle_width + prefs.width_adjust;
    let open_w = 620.0;
    let width = closed_w + (open_w - closed_w) * t;
    let closed_h = 32.0 + prefs.height_adjust;
    let open_h = 280.0;
    let height = closed_h + (open_h - closed_h) * t;

    let rect = Rect::from_center_size(
        Pos2::new(screen.center().x, height * 0.5),
        Vec2::new(width, height),
    );

    egui::CentralPanel::default()
        .frame(egui::Frame::none())
        .show(ctx, |ui| {
            let painter = ui.painter();
            let pts = shape.sample_points(rect, 16);
            if pts.len() >= 3 {
                painter.add(Shape::convex_polygon(
                    pts.clone(),
                    Color32::from_rgb(8, 8, 10),
                    Stroke::NONE,
                ));
                // Hairline rim
                painter.add(Shape::closed_line(
                    pts,
                    Stroke::new(1.0_f32, Color32::from_rgba_unmultiplied(255, 255, 255, 40)),
                ));
            }

            // Ambient accent glow
            let glow = Color32::from_rgba_unmultiplied(accent[0], accent[1], accent[2], 40);
            painter.circle_filled(rect.center(), rect.width() * 0.35, glow);

            if t < 0.35 {
                draw_closed(ui, rect, fire_tex, burning, prefs);
            } else {
                draw_expanded(ui, rect, snap, face_frame);
            }

            // Invisible interact layer over shape for hover
            let _ = ui.allocate_rect(rect.expand(4.0), Sense::hover());
        });

    rect
}

fn draw_closed(
    ui: &mut egui::Ui,
    rect: Rect,
    fire_tex: Option<&egui::TextureHandle>,
    burning: bool,
    prefs: &Prefs,
) {
    let painter = ui.painter();
    let spacer = 48.0 + prefs.width_adjust.max(0.0);
    let mid = rect.center();

    // Camera spacer (empty center)
    let _ = spacer;

    if burning {
        if let Some(tex) = fire_tex {
            let fire_rect = Rect::from_center_size(
                Pos2::new(mid.x, rect.max.y - 10.0),
                Vec2::new(rect.width() * 0.85, 14.0),
            );
            painter.image(
                tex.id(),
                fire_rect,
                Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0)),
                Color32::WHITE,
            );
        }
    } else {
        painter.text(
            mid,
            egui::Align2::CENTER_CENTER,
            "bullshit",
            egui::FontId::proportional(11.0),
            Color32::from_gray(120),
        );
    }
}

fn draw_expanded(ui: &mut egui::Ui, rect: Rect, snap: &AgentSnapshot, face_frame: usize) {
    let inner = rect.shrink2(Vec2::new(24.0, 18.0));
    ui.allocate_new_ui(egui::UiBuilder::new().max_rect(inner), |ui| {
        ui.vertical(|ui| {
            ui.horizontal(|ui| {
                ui.label(
                    egui::RichText::new("Agents")
                        .color(Color32::WHITE)
                        .size(14.0)
                        .strong(),
                );
                ui.label(
                    egui::RichText::new(format!("{} busy", snap.busy_count()))
                        .color(Color32::from_rgb(255, 160, 60))
                        .size(11.0),
                );
            });
            ui.add_space(6.0);
            egui::ScrollArea::vertical()
                .max_height(inner.height() - 28.0)
                .show(ui, |ui| {
                    if snap.agents.is_empty() {
                        ui.label(
                            egui::RichText::new("No live Claude sessions")
                                .color(Color32::from_gray(140))
                                .size(12.0),
                        );
                    }
                    for agent in &snap.agents {
                        agent_row(ui, agent, snap, face_frame);
                    }
                });
        });
    });
}

fn agent_row(ui: &mut egui::Ui, agent: &Agent, snap: &AgentSnapshot, face_frame: usize) {
    let face = Agent::face(agent.status.as_deref(), face_frame);
    let title = agent
        .name
        .clone()
        .unwrap_or_else(|| agent.session_id.clone());
    let tokens = snap
        .tokens
        .get(&agent.session_id)
        .copied()
        .unwrap_or((0, 0));
    ui.horizontal(|ui| {
        ui.label(
            egui::RichText::new(face)
                .monospace()
                .color(Color32::from_rgb(255, 180, 80))
                .size(12.0),
        );
        ui.vertical(|ui| {
            ui.label(
                egui::RichText::new(title)
                    .color(Color32::WHITE)
                    .size(12.0),
            );
            ui.label(
                egui::RichText::new(format!(
                    "{} · in {:} out {:}",
                    agent.status.as_deref().unwrap_or("idle"),
                    compact(tokens.0),
                    compact(tokens.1)
                ))
                .color(Color32::from_gray(140))
                .size(10.0),
            );
        });
    });
    ui.add_space(4.0);
}

fn compact(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}k", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}
