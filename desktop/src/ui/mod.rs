use crate::config::Prefs;
use crate::shape::{NotchShape, Spring};
use crate::stores::agents::{Agent, AgentSnapshot};
use eframe::egui::{self, Color32, Mesh, Pos2, Rect, Sense, Shape, Stroke, TextureId, Vec2};
use eframe::epaint::Vertex;

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
    // macOS closed ≈ physical notch (~200) + idleWidth wings (48).
    let closed_w = 200.0 + prefs.idle_width + prefs.width_adjust;
    let open_w = 620.0;
    let width = closed_w + (open_w - closed_w) * t;
    let closed_h = 30.0 + prefs.height_adjust;
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
            let pts = shape.sample_points(rect, 20);
            if pts.len() >= 3 {
                // Base fill
                painter.add(Shape::convex_polygon(
                    pts.clone(),
                    Color32::from_rgb(8, 8, 10),
                    Stroke::NONE,
                ));

                // Fire clipped to notch path (== macOS `.clipShape(NotchShape)`).
                // Drawing a rectangle left flared corners empty → goofy side gaps.
                if burning && t < 0.35 {
                    if let Some(tex) = fire_tex {
                        let wash = Color32::from_rgba_unmultiplied(
                            accent[0],
                            accent[1],
                            accent[2],
                            70,
                        );
                        painter.add(Shape::convex_polygon(pts.clone(), wash, Stroke::NONE));
                        painter.add(Shape::mesh(textured_convex_mesh(
                            tex.id(),
                            &pts,
                            rect,
                            Color32::WHITE,
                        )));
                    }
                }

                painter.add(Shape::closed_line(
                    pts.clone(),
                    Stroke::new(1.0_f32, Color32::from_rgba_unmultiplied(255, 255, 255, 40)),
                ));
            }

            if t < 0.35 {
                draw_closed_chrome(ui, rect, burning);
            } else {
                draw_expanded(ui, rect, &shape, snap, face_frame);
            }

            let _ = ui.allocate_rect(rect.expand(4.0), Sense::hover());
        });

    rect
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
        mesh.indices.push(0);
        mesh.indices.push(i as u32);
        mesh.indices.push((i + 1) as u32);
    }
    mesh
}

fn draw_closed_chrome(ui: &mut egui::Ui, rect: Rect, burning: bool) {
    if burning {
        return; // fire mesh is the closed content (demo backdrop)
    }
    ui.painter().text(
        rect.center(),
        egui::Align2::CENTER_CENTER,
        "bullshit",
        egui::FontId::proportional(11.0),
        Color32::from_gray(120),
    );
}

fn draw_expanded(
    ui: &mut egui::Ui,
    rect: Rect,
    shape: &NotchShape,
    snap: &AgentSnapshot,
    face_frame: usize,
) {
    let pad_x = shape.flare + 10.0;
    let pad_top = shape.flare_depth + 10.0;
    let pad_bot = shape.bottom + 8.0;
    let inner = Rect::from_min_max(
        Pos2::new(rect.min.x + pad_x, rect.min.y + pad_top),
        Pos2::new(rect.max.x - pad_x, rect.max.y - pad_bot),
    );

    ui.allocate_new_ui(egui::UiBuilder::new().max_rect(inner), |ui| {
        ui.spacing_mut().item_spacing = Vec2::new(8.0, 6.0);
        ui.vertical(|ui| {
            ui.horizontal(|ui| {
                ui.label(
                    egui::RichText::new("Agents")
                        .color(Color32::WHITE)
                        .size(13.0)
                        .strong(),
                );
                ui.add_space(6.0);
                ui.label(
                    egui::RichText::new(format!("{} busy", snap.busy_count()))
                        .color(Color32::from_rgb(255, 160, 60))
                        .size(11.0),
                );
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.label(
                        egui::RichText::new(format!("{} sessions", snap.agents.len()))
                            .color(Color32::from_gray(130))
                            .size(10.0),
                    );
                });
            });
            ui.add_space(8.0);
            egui::ScrollArea::vertical()
                .max_height((inner.height() - 36.0).max(40.0))
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
        ui.add_space(2.0);
        ui.label(
            egui::RichText::new(face)
                .monospace()
                .color(Color32::from_rgb(255, 180, 80))
                .size(12.0),
        );
        ui.add_space(6.0);
        ui.vertical(|ui| {
            ui.label(
                egui::RichText::new(title)
                    .color(Color32::WHITE)
                    .size(12.0),
            );
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

fn compact(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}k", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}
