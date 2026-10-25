//! Agents tab: harness filter pills, running sessions, `HarnessLimitsCard`
//! (port of `AgentsView` / `HarnessLimitsCard` / `LimitBlock`).

use super::{card, compact, pill, Action, UiState, View};
use crate::stores::agents::{Agent, Harness, SubAgent};
use crate::stores::usage::{self, UsageStats};
use eframe::egui::{self, Color32, RichText, Vec2};

const ORANGE: Color32 = Color32::from_rgb(255, 159, 10);
const YELLOW: Color32 = Color32::from_rgb(255, 214, 10);
const MUTED: Color32 = Color32::from_gray(140);

pub fn show(ui: &mut egui::Ui, v: &View, st: &mut UiState, actions: &mut Vec<Action>) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 4.0;
        filter_pill(ui, v, st, None);
        for h in Harness::ALL {
            filter_pill(ui, v, st, Some(h));
        }
    });
    ui.add_space(4.0);
    let area = ui.available_rect_before_wrap();
    match st.agent_filter {
        Some(h) => {
            let card_w = 250.0;
            let gap = 8.0;
            let list_rect = egui::Rect::from_min_max(area.min, egui::pos2(area.max.x - card_w - gap, area.max.y));
            let card_rect = egui::Rect::from_min_max(egui::pos2(area.max.x - card_w, area.min.y), area.max);
            column(ui, list_rect, |ui| {
                card(ui, |ui| {
                    ui.set_min_size(list_rect.size() - Vec2::splat(18.0));
                    let shown: Vec<&Agent> = v.agents.agents.iter().filter(|a| a.harness == h).collect();
                    ui.horizontal(|ui| {
                        ui.label(RichText::new("Running").size(11.0).strong().color(MUTED));
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            pill(ui, &shown.len().to_string(), false);
                        });
                    });
                    if shown.is_empty() {
                        ui.centered_and_justified(|ui| {
                            ui.label(RichText::new(format!("No {} sessions", h.label())).size(11.0).color(MUTED));
                        });
                    } else {
                        list(ui, v, &shown, "agents-h");
                    }
                });
            });
            column(ui, card_rect, |ui| limits_card(ui, v, st, h, actions));
            ui.allocate_rect(area, egui::Sense::hover());
        }
        None => {
            let all: Vec<&Agent> = v.agents.agents.iter().collect();
            if all.is_empty() {
                ui.centered_and_justified(|ui| {
                    ui.label(RichText::new("No agent sessions running").size(12.0).color(MUTED));
                });
            } else {
                list(ui, v, &all, "agents-all");
            }
        }
    }
}

fn filter_pill(ui: &mut egui::Ui, v: &View, st: &mut UiState, h: Option<Harness>) {
    let (busy, n) = v.agents.count(h);
    let selected = st.agent_filter == h;
    let resp = egui::Frame::none()
        .fill(if selected { crate::ui::white(40) } else { Color32::TRANSPARENT })
        .rounding(10.0)
        .inner_margin(egui::Margin::symmetric(8.0, 3.0))
        .show(ui, |ui| {
            ui.spacing_mut().item_spacing.x = 4.0;
            if let Some(h) = h {
                dot(ui, h.color());
            }
            ui.label(RichText::new(h.map_or("All", |h| h.label())).size(11.0).color(if selected { Color32::WHITE } else { MUTED }));
            let count = if busy > 0 { format!("{busy}/{n}") } else { n.to_string() };
            ui.label(RichText::new(count).size(11.0).color(if busy > 0 { ORANGE } else { MUTED }));
        })
        .response
        .interact(egui::Sense::click());
    if resp.clicked() {
        st.agent_filter = h;
    }
}

/// Top-down child UI confined to `rect`.
pub fn column<R>(ui: &mut egui::Ui, rect: egui::Rect, add: impl FnOnce(&mut egui::Ui) -> R) -> R {
    ui.allocate_new_ui(egui::UiBuilder::new().max_rect(rect).layout(egui::Layout::top_down(egui::Align::Min)), |ui| {
        ui.set_clip_rect(rect.intersect(ui.clip_rect()));
        add(ui)
    })
    .inner
}

pub fn dot(ui: &mut egui::Ui, c: Color32) {
    let (r, _) = ui.allocate_exact_size(Vec2::splat(7.0), egui::Sense::hover());
    ui.painter().circle_filled(r.center(), 3.0, c);
}

fn list(ui: &mut egui::Ui, v: &View, agents: &[&Agent], id: &str) {
    egui::ScrollArea::vertical().id_salt(id).auto_shrink([false, false]).show(ui, |ui| {
        for agent in agents {
            row(ui, v, agent);
            for sub in v.agents.subagents.get(&agent.session_id).into_iter().flatten() {
                sub_row(ui, sub, v.face_frame);
            }
            ui.separator();
        }
    });
}

fn status_color(status: Option<&str>) -> Color32 {
    match status {
        Some("busy") => ORANGE,
        Some("waiting") => YELLOW,
        _ => MUTED,
    }
}

fn now_ms() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0)
}

pub fn timer(since_ms: f64) -> String {
    let s = ((now_ms() - since_ms) / 1000.0).max(0.0) as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, (s / 60) % 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

pub fn tilde(path: &str) -> String {
    match directories::UserDirs::new().map(|u| u.home_dir().display().to_string()) {
        Some(home) if !home.is_empty() && path.starts_with(&home) => format!("~{}", &path[home.len()..]),
        _ => path.to_string(),
    }
}

fn row(ui: &mut egui::Ui, v: &View, a: &Agent) {
    let status = a.status.as_deref();
    let col = status_color(status);
    let mono = |s: &str, size: f32, c: Color32| RichText::new(s).monospace().size(size).color(c);
    ui.horizontal(|ui| {
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            ui.label(mono(&timer(a.status_updated_at.unwrap_or(a.started_at)), 11.0, Color32::from_gray(200)));
            ui.label(mono(status.unwrap_or("?"), 11.0, col));
            ui.with_layout(egui::Layout::left_to_right(egui::Align::Center), |ui| {
                ui.label(mono(Agent::face(status, v.face_frame), 12.0, col));
                let h = a.harness;
                ui.label(mono(h.tag(), 10.0, h.color()).background_color(h.color().gamma_multiply(0.15)).strong());
                let name = a.name.clone().unwrap_or_else(|| {
                    std::path::Path::new(&a.cwd).file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
                });
                ui.add(egui::Label::new(mono(&name, 12.0, Color32::WHITE)).truncate());
            });
        });
    });
    ui.horizontal(|ui| {
        let tokens = v.agents.tokens.get(&a.session_id).copied();
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if let Some((i, o)) = tokens {
                ui.label(mono(&format!("↑{} ↓{}", compact(i), compact(o)), 10.0, MUTED));
            }
            ui.label(mono(&format!("up {}", timer(a.started_at)), 10.0, MUTED));
            ui.with_layout(egui::Layout::left_to_right(egui::Align::Center), |ui| {
                ui.add(egui::Label::new(mono(&tilde(&a.cwd), 10.0, MUTED)).truncate());
            });
        });
    });
}

fn sub_row(ui: &mut egui::Ui, s: &SubAgent, frame: usize) {
    let (face, col) = if s.finished { ("[^_^] ✔", Color32::from_rgb(48, 209, 88)) } else { (Agent::face(Some("busy"), frame), ORANGE) };
    let mono = |t: &str, c: Color32| RichText::new(t).monospace().size(10.0).color(c);
    ui.horizontal(|ui| {
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            ui.label(mono(&format!("↑{} ↓{}", compact(s.tokens.0), compact(s.tokens.1)), MUTED));
            ui.with_layout(egui::Layout::left_to_right(egui::Align::Center), |ui| {
                ui.add_space(16.0);
                ui.label(mono("└", Color32::from_gray(90)));
                ui.label(mono(face, col));
                ui.add(egui::Label::new(mono(&s.description, if s.finished { MUTED } else { Color32::WHITE })).truncate())
                    .on_hover_text(format!("{}: {}", s.agent_type, s.description));
            });
        });
    });
}

fn limits_card(ui: &mut egui::Ui, v: &View, st: &mut UiState, h: Harness, actions: &mut Vec<Action>) {
    let stats: &UsageStats = if h == Harness::Claude { &v.usage.claude } else { &v.usage.agy };
    let (sess_limit, week_limit) = match h {
        Harness::Claude => (v.prefs.claude_daily_limit, v.prefs.claude_weekly_limit),
        Harness::Antigravity => (v.prefs.agy_daily_limit, v.prefs.agy_weekly_limit),
    };
    card(ui, |ui| {
        ui.set_width(234.0);
        ui.horizontal(|ui| {
            dot(ui, h.color());
            ui.label(RichText::new(format!("{} Limits", h.label())).size(11.0).strong().color(Color32::WHITE));
            if h == Harness::Claude && v.usage.oauth_connected {
                ui.label(
                    RichText::new(" LIVE ").monospace().size(8.0).strong().color(Color32::from_rgb(48, 209, 88))
                        .background_color(Color32::from_rgba_unmultiplied(48, 209, 88, 50)),
                )
                .on_hover_text("Synced with Anthropic /usage OAuth endpoint");
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.menu_button(RichText::new("⚙").size(11.0).color(MUTED), |ui| {
                    ui.label(RichText::new("Limit Tier Presets").size(10.0).color(MUTED));
                    for (title, s, w) in h.limit_presets() {
                        let on = *s == sess_limit && *w == week_limit;
                        if ui.selectable_label(on, *title).clicked() {
                            actions.push(Action::SetLimits(h, *s, *w));
                            ui.close_menu();
                        }
                    }
                    ui.separator();
                    if ui.button("Set Custom Limits (M)…").clicked() {
                        st.custom_limits = Some((
                            h,
                            format!("{:.1}", sess_limit as f64 / 1e6),
                            format!("{:.1}", week_limit as f64 / 1e6),
                        ));
                        ui.close_menu();
                    }
                    if ui.button("Refresh Usage Now").clicked() {
                        actions.push(Action::RefreshUsage);
                        ui.close_menu();
                    }
                });
                let daily = st.show_daily.contains(&h);
                if ui.add(egui::Button::new(RichText::new(if daily { "Today" } else { "5h Win" }).monospace().size(9.0)).rounding(8.0)).clicked() {
                    if daily {
                        st.show_daily.retain(|x| *x != h);
                    } else {
                        st.show_daily.push(h);
                    }
                }
            });
        });

        if let Some((ch, s, w)) = st.custom_limits.as_mut().filter(|c| c.0 == h).map(|c| (c.0, &mut c.1, &mut c.2)) {
            let mut save = false;
            ui.horizontal(|ui| {
                ui.add(egui::TextEdit::singleline(s).hint_text("5h (M)").desired_width(60.0).font(egui::TextStyle::Monospace));
                ui.add(egui::TextEdit::singleline(w).hint_text("7d (M)").desired_width(60.0).font(egui::TextStyle::Monospace));
                save = ui.button("Save").clicked();
            });
            if save {
                let parse = |t: &str| t.trim().parse::<f64>().ok().filter(|x| *x > 0.0).map(|x| (x * 1e6) as u64);
                actions.push(Action::SetLimits(ch, parse(s).unwrap_or(sess_limit), parse(w).unwrap_or(week_limit)));
                st.custom_limits = None;
            }
        }

        ui.separator();
        if st.show_daily.contains(&h) {
            limit_block(ui, "Today (Daily)", Some("since midnight".into()), &stats.daily, sess_limit, None, h.color());
        } else {
            limit_block(
                ui,
                "5h Session",
                usage::reset_text(stats.session_resets_at()),
                &stats.session,
                sess_limit,
                stats.live_five_hour_percent.map(|p| p / 100.0),
                h.color(),
            );
        }
        ui.separator();
        limit_block(
            ui,
            "7d Weekly",
            usage::reset_text(stats.weekly_resets_at()),
            &stats.weekly,
            week_limit,
            stats.live_seven_day_percent.map(|p| p / 100.0),
            h.color(),
        );
    });
}

fn limit_block(
    ui: &mut egui::Ui,
    title: &str,
    subtitle: Option<String>,
    b: &usage::Bucket,
    limit: u64,
    override_pct: Option<f64>,
    color: Color32,
) {
    let used = b.effective();
    let pct = override_pct
        .map(|p| p.clamp(0.0, 1.0))
        .unwrap_or_else(|| if limit > 0 { (used as f64 / limit as f64).min(1.0) } else { 0.0 });
    let status = if pct >= 0.9 {
        Color32::from_rgb(255, 69, 58)
    } else if pct >= 0.7 {
        YELLOW
    } else {
        color
    };
    ui.horizontal(|ui| {
        ui.label(RichText::new(title).size(10.0).strong().color(Color32::WHITE));
        if let Some(s) = subtitle {
            ui.label(RichText::new(format!("· {s}")).size(9.0).color(MUTED));
        }
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            ui.label(RichText::new(format!("{}%", (pct * 100.0).round() as i64)).size(10.0).strong().color(status));
        });
    });
    let (rect, _) = ui.allocate_exact_size(Vec2::new(ui.available_width(), 5.0), egui::Sense::hover());
    ui.painter().rect_filled(rect, 2.5, crate::ui::white(30));
    let mut fill = rect;
    fill.max.x = rect.min.x + (rect.width() * pct as f32).max(3.0);
    ui.painter().rect_filled(fill, 2.5, status);
    ui.horizontal(|ui| {
        let mono = |t: String, c: Color32| RichText::new(t).monospace().size(9.0).color(c);
        ui.label(mono(format!("{} / {}", compact(used), compact(limit)), MUTED));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            ui.label(mono(
                format!("↑{} ↓{} ⚡{}", compact(b.input + b.cache_write), compact(b.output), compact(b.cache_read)),
                Color32::from_gray(100),
            ))
            .on_hover_text("Uncached input · Output · Prompt cache hits (weighted 0.1x)");
        });
    });
}
