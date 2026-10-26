//! Workspace: Git / Work / Containers / Agents + custom shortcuts.

use super::{agents, card, pill, Action, UiState, View};
use crate::stores::github::PrList;
use crate::stores::work::ItemKind;
use eframe::egui::{self, Color32, RichText};

const MUTED: Color32 = Color32::from_gray(140);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum WorkSection {
    Git,
    Work,
    Containers,
    #[default]
    Agents,
}

impl WorkSection {
    pub const ALL: [WorkSection; 4] = [WorkSection::Git, WorkSection::Work, WorkSection::Containers, WorkSection::Agents];

    pub fn label(self) -> &'static str {
        match self {
            Self::Git => "Git",
            Self::Work => "Work",
            Self::Containers => "Containers",
            Self::Agents => "Agents",
        }
    }

    pub fn enabled(self, v: &View) -> bool {
        match self {
            Self::Git => v.prefs.section_git,
            Self::Work => v.prefs.section_work,
            Self::Containers => v.prefs.section_containers,
            Self::Agents => v.prefs.section_agents,
        }
    }
}

pub fn show(ui: &mut egui::Ui, v: &View, st: &mut UiState, actions: &mut Vec<Action>) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 4.0;
        for s in WorkSection::ALL {
            if !s.enabled(v) {
                continue;
            }
            let on = st.work_section == s;
            let resp = egui::Frame::none()
                .fill(if on { crate::ui::white(40) } else { Color32::TRANSPARENT })
                .rounding(8.0)
                .inner_margin(egui::Margin::symmetric(6.0, 2.0))
                .show(ui, |ui| {
                    ui.label(RichText::new(s.label()).size(10.0).color(if on { Color32::WHITE } else { MUTED }));
                })
                .response
                .interact(egui::Sense::click());
            if resp.clicked() {
                st.work_section = s;
            }
        }
    });
    ui.add_space(4.0);
    match st.work_section {
        WorkSection::Git if v.prefs.section_git => git(ui, v, st, actions),
        WorkSection::Work if v.prefs.section_work => work(ui, v, st, actions),
        WorkSection::Containers if v.prefs.section_containers => containers(ui, v, actions),
        _ => agents::show(ui, v, st, actions),
    }
}

fn git(ui: &mut egui::Ui, v: &View, st: &mut UiState, actions: &mut Vec<Action>) {
    ui.horizontal(|ui| {
        for list in PrList::ALL {
            let on = st.pr_list == list;
            if ui.selectable_label(on, list.label()).clicked() {
                st.pr_list = list;
            }
        }
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if ui.small_button("↻").clicked() {
                actions.push(Action::RefreshGit);
            }
        });
    });
    if let Some(err) = &v.github.error {
        ui.label(RichText::new(err).size(10.0).color(Color32::from_rgb(255, 69, 58)));
    }
    let prs = v.github.list(st.pr_list);
    if prs.is_empty() {
        ui.centered_and_justified(|ui| {
            ui.label(RichText::new("No open PRs").size(12.0).color(MUTED));
        });
        return;
    }
    egui::ScrollArea::vertical().id_salt("prs").auto_shrink([false, false]).show(ui, |ui| {
        for pr in prs {
            card(ui, |ui| {
                ui.horizontal(|ui| {
                    pill(ui, &format!("#{}", pr.number), false);
                    if ui.add(egui::Label::new(RichText::new(&pr.title).size(12.0).color(Color32::WHITE)).sense(egui::Sense::click()).truncate()).clicked()
                    {
                        actions.push(Action::OpenUrl(pr.url.clone()));
                    }
                });
                ui.label(RichText::new(&pr.repository.name_with_owner).size(10.0).color(MUTED));
            });
        }
    });
}

fn work(ui: &mut egui::Ui, v: &View, st: &mut UiState, actions: &mut Vec<Action>) {
    ui.horizontal(|ui| {
        ui.add(egui::TextEdit::singleline(&mut st.new_project_name).hint_text("name").desired_width(90.0));
        ui.add(egui::TextEdit::singleline(&mut st.new_project_path).hint_text("~/path").desired_width(140.0));
        if ui.small_button("Add").clicked() && !st.new_project_path.is_empty() {
            actions.push(Action::AddProject(st.new_project_name.clone(), st.new_project_path.clone(), v.prefs.default_agent_command.clone()));
            st.new_project_name.clear();
            st.new_project_path.clear();
        }
    });
    egui::ScrollArea::vertical().id_salt("work").auto_shrink([false, false]).show(ui, |ui| {
        for p in &v.work.projects {
            let running = v.work.running.contains_key(&p.id);
            card(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.label(RichText::new(&p.name).size(12.0).strong().color(Color32::WHITE));
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.small_button("✕").clicked() {
                            actions.push(Action::RemoveProject(p.id.clone()));
                        }
                        if ui.small_button("agent").clicked() {
                            actions.push(Action::LaunchAgent(p.id.clone()));
                        }
                        if ui.small_button("term").clicked() {
                            actions.push(Action::LaunchTerm(p.id.clone()));
                        }
                        if running {
                            if ui.small_button("stop").clicked() {
                                actions.push(Action::StopProject(p.id.clone()));
                            }
                        } else if ui.small_button("run").clicked() {
                            actions.push(Action::StartProject(p.id.clone()));
                        }
                    });
                });
                ui.label(RichText::new(&p.path).size(10.0).color(MUTED));
                ui.label(RichText::new(&p.service_command).monospace().size(9.0).color(MUTED));
                if let Some(log) = v.work.logs.get(&p.id) {
                    if !log.is_empty() {
                        ui.label(RichText::new(log.lines().rev().take(3).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n")).monospace().size(9.0).color(Color32::from_gray(160)));
                    }
                }
            });
        }
        for sec in &v.work.sections {
            ui.label(RichText::new(&sec.name).size(10.0).strong().color(MUTED));
            for item in &sec.items {
                if ui.link(RichText::new(&item.name).size(11.0)).clicked() {
                    match item.kind {
                        ItemKind::Folder => actions.push(Action::OpenPath(std::path::PathBuf::from(item.open_target()))),
                        _ => actions.push(Action::OpenUrl(item.open_target())),
                    }
                }
            }
        }
    });
}

fn containers(ui: &mut egui::Ui, v: &View, actions: &mut Vec<Action>) {
    ui.horizontal(|ui| {
        ui.label(RichText::new(if v.containers.engine_running { &v.containers.cli } else { "engine" }).size(10.0).color(MUTED));
        if v.containers.wsl2 {
            pill(ui, "WSL2", false);
        }
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if ui.small_button("↻").clicked() {
                actions.push(Action::RefreshContainers);
            }
        });
    });
    if let Some(err) = &v.containers.error {
        ui.label(RichText::new(err).size(10.0).color(Color32::from_rgb(255, 69, 58)));
    }
    egui::ScrollArea::vertical().id_salt("ct").auto_shrink([false, false]).show(ui, |ui| {
        for c in &v.containers.containers {
            card(ui, |ui| {
                ui.horizontal(|ui| {
                    let col = if c.is_running() { Color32::from_rgb(48, 209, 88) } else { MUTED };
                    ui.label(RichText::new("●").size(10.0).color(col));
                    ui.label(RichText::new(&c.name).size(12.0).color(Color32::WHITE));
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if c.is_running() {
                            if ui.small_button("stop").clicked() {
                                actions.push(Action::ContainerCmd(c.cli.clone(), c.id.clone(), "stop".into()));
                            }
                        } else if ui.small_button("start").clicked() {
                            actions.push(Action::ContainerCmd(c.cli.clone(), c.id.clone(), "start".into()));
                        }
                    });
                });
                ui.label(RichText::new(format!("{} · {}", c.image, c.status)).size(10.0).color(MUTED));
                if !c.ports.is_empty() {
                    ui.label(RichText::new(format!(":{}", c.ports.iter().map(|p| p.to_string()).collect::<Vec<_>>().join(" :"))).monospace().size(9.0).color(MUTED));
                }
            });
        }
    });
}
