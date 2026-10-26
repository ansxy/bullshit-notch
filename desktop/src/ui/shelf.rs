//! Shelf tab: drop files, list, reveal parent, clear.

use super::{card, pill, Action, View};
use eframe::egui::{self, Color32, RichText};

const MUTED: Color32 = Color32::from_gray(140);

pub fn show(ui: &mut egui::Ui, v: &View, actions: &mut Vec<Action>) {
    ui.horizontal(|ui| {
        ui.label(RichText::new("Shelf").size(12.0).strong().color(Color32::WHITE));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if !v.shelf.items.is_empty() && ui.add(egui::Button::new(RichText::new("Clear").size(10.0))).clicked() {
                actions.push(Action::ShelfClear);
            }
            pill(ui, &v.shelf.items.len().to_string(), false);
        });
    });
    ui.add_space(4.0);

    let drop = ui.ctx().input(|i| i.raw.dropped_files.clone());
    if !drop.is_empty() {
        let paths: Vec<_> = drop.into_iter().filter_map(|f| f.path).collect();
        if !paths.is_empty() {
            actions.push(Action::ShelfAdd(paths));
        }
    }

    let hovering_drop = ui.ctx().input(|i| !i.raw.hovered_files.is_empty());
    card(ui, |ui| {
        ui.set_min_height(48.0);
        ui.centered_and_justified(|ui| {
            let msg = if hovering_drop { "Drop to add" } else { "Drop files here" };
            ui.label(RichText::new(msg).size(11.0).color(MUTED));
        });
    });
    ui.add_space(4.0);

    if v.shelf.items.is_empty() {
        ui.centered_and_justified(|ui| {
            ui.label(RichText::new("Empty shelf").size(12.0).color(MUTED));
        });
        return;
    }

    egui::ScrollArea::vertical().id_salt("shelf").auto_shrink([false, false]).show(ui, |ui| {
        for item in &v.shelf.items {
            ui.horizontal(|ui| {
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.small_button("✕").on_hover_text("Remove").clicked() {
                        actions.push(Action::ShelfRemove(item.path.clone()));
                    }
                    if ui.small_button("↗").on_hover_text("Reveal").clicked() {
                        actions.push(Action::Reveal(item.path.clone()));
                    }
                    ui.with_layout(egui::Layout::left_to_right(egui::Align::Center), |ui| {
                        let gone = !item.exists();
                        let name = RichText::new(&item.name)
                            .size(12.0)
                            .color(if gone { MUTED } else { Color32::WHITE });
                        if ui.add(egui::Label::new(name).sense(egui::Sense::click()).truncate()).clicked() {
                            actions.push(Action::OpenPath(item.path.clone()));
                        }
                    });
                });
            });
        }
    });
}
