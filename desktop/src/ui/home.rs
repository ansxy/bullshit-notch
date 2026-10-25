//! Home tab: music card, next meeting, local tasks.

use super::{card, Action, View};
use crate::stores::now_playing::MediaCommand;
use chrono::{Local, Utc};
use eframe::egui::{self, Color32, RichText, Vec2};

const MUTED: Color32 = Color32::from_gray(140);

pub fn show(ui: &mut egui::Ui, v: &View, actions: &mut Vec<Action>) {
    egui::ScrollArea::vertical().id_salt("home").auto_shrink([false, false]).show(ui, |ui| {
        if v.prefs.music {
            music_card(ui, v, actions);
            ui.add_space(6.0);
        }
        if v.prefs.agenda {
            meeting_card(ui, v, actions);
            ui.add_space(6.0);
            if !v.agenda.tasks.is_empty() {
                tasks_card(ui, v);
            }
        }
    });
}

fn music_card(ui: &mut egui::Ui, v: &View, actions: &mut Vec<Action>) {
    card(ui, |ui| {
        if !v.music.has_track() {
            ui.horizontal(|ui| {
                ui.label(RichText::new("♪").size(16.0).color(MUTED));
                ui.label(RichText::new("Nothing playing").size(12.0).color(MUTED));
            });
            return;
        }
        ui.horizontal(|ui| {
            let (art, _) = ui.allocate_exact_size(Vec2::splat(52.0), egui::Sense::hover());
            if let Some(tex) = v.art_tex {
                ui.painter().image(tex.id(), art, egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0)), Color32::WHITE);
            } else {
                ui.painter().rect_filled(art, 6.0, crate::ui::white(28));
                ui.painter().text(art.center(), egui::Align2::CENTER_CENTER, "♪", egui::FontId::proportional(16.0), MUTED);
            }
            ui.vertical(|ui| {
                ui.add(egui::Label::new(RichText::new(&v.music.title).size(13.0).strong().color(Color32::WHITE)).truncate());
                ui.add(egui::Label::new(RichText::new(format!("{} · {}", v.music.artist, v.music.album)).size(10.0).color(MUTED)).truncate());
                let elapsed = v.music.elapsed();
                let dur = v.music.duration.max(1.0);
                let frac = (elapsed / dur).clamp(0.0, 1.0) as f32;
                let (bar, _) = ui.allocate_exact_size(Vec2::new(ui.available_width(), 4.0), egui::Sense::hover());
                ui.painter().rect_filled(bar, 2.0, crate::ui::white(28));
                let mut fill = bar;
                fill.max.x = bar.min.x + bar.width() * frac;
                ui.painter().rect_filled(fill, 2.0, Color32::WHITE);
                ui.horizontal(|ui| {
                    ui.label(RichText::new(mmss(elapsed)).monospace().size(9.0).color(MUTED));
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        ui.label(RichText::new(mmss(dur)).monospace().size(9.0).color(MUTED));
                    });
                });
            });
        });
        ui.horizontal(|ui| {
            if ui.button(RichText::new("⏮").size(14.0)).clicked() {
                actions.push(Action::Media(MediaCommand::Previous));
            }
            let glyph = if v.music.playing { "⏸" } else { "▶" };
            if ui.button(RichText::new(glyph).size(14.0)).clicked() {
                actions.push(Action::Media(MediaCommand::PlayPause));
            }
            if ui.button(RichText::new("⏭").size(14.0)).clicked() {
                actions.push(Action::Media(MediaCommand::Next));
            }
            ui.label(RichText::new(v.music.player.as_deref().unwrap_or("")).size(10.0).color(MUTED));
        });
    });
}

fn meeting_card(ui: &mut egui::Ui, v: &View, actions: &mut Vec<Action>) {
    let now = Utc::now();
    card(ui, |ui| {
        ui.label(RichText::new("Next").size(10.0).strong().color(MUTED));
        match v.agenda.next_meeting(now) {
            Some(ev) => {
                let when = ev.start.with_timezone(&Local).format("%H:%M");
                ui.horizontal(|ui| {
                    ui.label(RichText::new(format!("{when}")).monospace().size(12.0).color(Color32::WHITE));
                    ui.add(egui::Label::new(RichText::new(&ev.title).size(12.0).color(Color32::WHITE)).truncate());
                });
                if let Some(link) = ev.meeting_link() {
                    if ui.link(RichText::new("Join meeting").size(11.0).color(Color32::from_rgb(10, 132, 255))).clicked() {
                        actions.push(Action::OpenUrl(link));
                    }
                } else if let Some(loc) = &ev.location {
                    ui.label(RichText::new(loc).size(10.0).color(MUTED));
                }
            }
            None => {
                ui.label(RichText::new("No upcoming meetings").size(12.0).color(MUTED));
            }
        }
    });
}

fn tasks_card(ui: &mut egui::Ui, v: &View) {
    card(ui, |ui| {
        ui.label(RichText::new("Tasks").size(10.0).strong().color(MUTED));
        for t in &v.agenda.tasks {
            ui.horizontal(|ui| {
                ui.label(RichText::new(if t.done { "☑" } else { "☐" }).size(12.0).color(MUTED));
                ui.add(egui::Label::new(RichText::new(&t.title).size(11.0).color(if t.done { MUTED } else { Color32::WHITE })).truncate());
            });
        }
    });
}

fn mmss(secs: f64) -> String {
    let s = secs.max(0.0) as u64;
    format!("{}:{:02}", s / 60, s % 60)
}
