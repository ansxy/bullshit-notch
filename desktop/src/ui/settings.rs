//! Settings window: Notch / Theme / Activities / Tabs / Menus / System.

use crate::config::{AgentAnimationStyle, ContainerCli, GlassMaterial, NotchTheme, Prefs, TerminalApp};
use eframe::egui::{self, Color32, RichText};

const MUTED: Color32 = Color32::from_gray(140);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SettingsTab {
    #[default]
    Notch,
    Theme,
    Activities,
    Tabs,
    Menus,
    System,
}

impl SettingsTab {
    pub const ALL: [SettingsTab; 6] = [
        SettingsTab::Notch,
        SettingsTab::Theme,
        SettingsTab::Activities,
        SettingsTab::Tabs,
        SettingsTab::Menus,
        SettingsTab::System,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::Notch => "Notch",
            Self::Theme => "Theme",
            Self::Activities => "Activities",
            Self::Tabs => "Tabs",
            Self::Menus => "Menus",
            Self::System => "System",
        }
    }
}

pub fn show_window(ctx: &egui::Context, prefs: &mut Prefs, tab: &mut SettingsTab, open: &mut bool, quit: &mut bool) {
    let viewport = egui::ViewportBuilder::default()
        .with_title("BullshitNotch Settings")
        .with_inner_size([460.0, 540.0])
        .with_decorations(true)
        .with_transparent(false)
        .with_always_on_top();
    ctx.show_viewport_immediate(egui::ViewportId::from_hash_of("bn-settings"), viewport, |ctx, _| {
        if ctx.input(|i| i.viewport().close_requested()) {
            *open = false;
        }
        egui::CentralPanel::default().show(ctx, |ui| {
            let before = prefs.clone();
            ui.horizontal(|ui| {
                for t in SettingsTab::ALL {
                    if ui.selectable_label(*tab == t, t.label()).clicked() {
                        *tab = t;
                    }
                }
            });
            ui.separator();
            egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| match *tab {
                SettingsTab::Notch => notch(ui, prefs),
                SettingsTab::Theme => theme(ui, prefs),
                SettingsTab::Activities => activities(ui, prefs),
                SettingsTab::Tabs => tabs(ui, prefs),
                SettingsTab::Menus => menus(ui, prefs),
                SettingsTab::System => system(ui, prefs),
            });
            if *prefs != before {
                let _ = prefs.save();
            }
            ui.separator();
            if ui.button("Quit BullshitNotch").clicked() {
                *quit = true;
                *open = false;
            }
        });
    });
}

fn notch(ui: &mut egui::Ui, p: &mut Prefs) {
    ui.checkbox(&mut p.open_on_hover, "Open on hover");
    slider(ui, "Idle width", &mut p.idle_width, 0.0..=120.0);
    slider(ui, "Width adjust", &mut p.width_adjust, -40.0..=80.0);
    slider(ui, "Height adjust", &mut p.height_adjust, -8.0..=24.0);
}

fn theme(ui: &mut egui::Ui, p: &mut Prefs) {
    ui.horizontal(|ui| {
        ui.label("Theme");
        for t in [NotchTheme::Dark, NotchTheme::Glass] {
            let label = match t {
                NotchTheme::Dark => "Dark",
                NotchTheme::Glass => "Glass",
            };
            if ui.selectable_label(p.theme == t, label).clicked() {
                p.theme = t;
            }
        }
    });
    ui.horizontal(|ui| {
        ui.label("Glass material");
        for m in [
            GlassMaterial::UltraThin,
            GlassMaterial::Thin,
            GlassMaterial::Regular,
            GlassMaterial::Thick,
            GlassMaterial::UltraThick,
            GlassMaterial::Bar,
        ] {
            let label = match m {
                GlassMaterial::UltraThin => "Ultra thin",
                GlassMaterial::Thin => "Thin",
                GlassMaterial::Regular => "Regular",
                GlassMaterial::Thick => "Thick",
                GlassMaterial::UltraThick => "Ultra thick",
                GlassMaterial::Bar => "Bar",
            };
            if ui.selectable_label(p.glass_material == m, label).clicked() {
                p.glass_material = m;
            }
        }
    });
    slider(ui, "Blur", &mut p.glass_blur_opacity, 0.0..=1.0);
    slider(ui, "Tint", &mut p.glass_tint_opacity, 0.0..=1.0);
    slider(ui, "Top fade", &mut p.glass_top_fade, 0.0..=1.0);
    slider(ui, "Sheen", &mut p.glass_sheen, 0.0..=1.0);
    slider(ui, "Border", &mut p.glass_border_opacity, 0.0..=1.0);
    slider(ui, "Shadow", &mut p.glass_shadow_opacity, 0.0..=1.0);
    slider(ui, "Accent glow", &mut p.glass_accent_glow, 0.0..=1.0);
    slider(ui, "Card opacity", &mut p.glass_card_opacity, 0.0..=1.0);
    ui.checkbox(&mut p.glass_card_blur, "Blur cards");
    ui.checkbox(&mut p.glass_closed, "Glass when closed");
    ui.checkbox(&mut p.music_ambient, "Music ambient glow");
    slider(ui, "Ambient intensity", &mut p.music_ambient_intensity, 0.0..=1.0);
}

fn activities(ui: &mut egui::Ui, p: &mut Prefs) {
    ui.checkbox(&mut p.live_agents, "Live agents");
    ui.checkbox(&mut p.live_music, "Live music");
    ui.checkbox(&mut p.live_battery, "Live battery");
    ui.checkbox(&mut p.agenda, "Agenda");
    ui.checkbox(&mut p.replace_hud, "Replace system HUD");
    ui.checkbox(&mut p.agent_animation_always_on, "Always animate fire");
    ui.label(RichText::new("Agent animation").size(11.0).color(MUTED));
    ui.horizontal_wrapped(|ui| {
        for style in AgentAnimationStyle::ALL {
            let label = match style {
                AgentAnimationStyle::Fire => "Fire",
                AgentAnimationStyle::Scanner => "Scanner",
                AgentAnimationStyle::Lightning => "Lightning",
                AgentAnimationStyle::Plasma => "Plasma",
                AgentAnimationStyle::Matrix => "Matrix",
                AgentAnimationStyle::Rave => "Rave",
                AgentAnimationStyle::Warp => "Warp",
                AgentAnimationStyle::RandomBullshit => "Random",
            };
            if ui.selectable_label(p.agent_animation == style, label).clicked() {
                p.agent_animation = style;
            }
        }
    });
}

fn tabs(ui: &mut egui::Ui, p: &mut Prefs) {
    ui.checkbox(&mut p.tab_home, "Home tab");
    ui.checkbox(&mut p.tab_shelf, "Shelf tab");
    ui.checkbox(&mut p.tab_topbar, "Workspace tab");
    ui.checkbox(&mut p.music, "Music card");
    ui.checkbox(&mut p.air_drop, "AirDrop (macOS only)");
    ui.checkbox(&mut p.mirror, "Camera mirror (macOS only)");
}

fn menus(ui: &mut egui::Ui, p: &mut Prefs) {
    ui.checkbox(&mut p.section_git, "Git");
    ui.checkbox(&mut p.section_work, "Work");
    ui.checkbox(&mut p.section_containers, "Containers");
    ui.checkbox(&mut p.section_agents, "Agents");
    ui.checkbox(&mut p.section_qa, "QA (macOS only)");
}

fn system(ui: &mut egui::Ui, p: &mut Prefs) {
    ui.label("Preferred terminal");
    ui.horizontal_wrapped(|ui| {
        for t in [
            TerminalApp::Auto,
            TerminalApp::WindowsTerminal,
            TerminalApp::Powershell,
            TerminalApp::Wezterm,
            TerminalApp::Alacritty,
            TerminalApp::Iterm,
            TerminalApp::Terminal,
            TerminalApp::Warp,
            TerminalApp::Ghostty,
        ] {
            let label = match t {
                TerminalApp::Auto => "Auto",
                TerminalApp::WindowsTerminal => "Windows Terminal",
                TerminalApp::Powershell => "PowerShell",
                TerminalApp::Wezterm => "WezTerm",
                TerminalApp::Alacritty => "Alacritty",
                TerminalApp::Iterm => "iTerm",
                TerminalApp::Terminal => "Terminal.app",
                TerminalApp::Warp => "Warp",
                TerminalApp::Ghostty => "Ghostty",
            };
            if ui.selectable_label(p.preferred_terminal == t, label).clicked() {
                p.preferred_terminal = t;
            }
        }
    });
    ui.label("Default agent command");
    ui.add(egui::TextEdit::singleline(&mut p.default_agent_command).desired_width(200.0));
    ui.label("Container CLI");
    ui.horizontal(|ui| {
        for c in [ContainerCli::Auto, ContainerCli::Docker, ContainerCli::Podman] {
            let label = match c {
                ContainerCli::Auto => "Auto",
                ContainerCli::Docker => "Docker",
                ContainerCli::Podman => "Podman",
            };
            if ui.selectable_label(p.container_cli == c, label).clicked() {
                p.container_cli = c;
            }
        }
    });
}

fn slider(ui: &mut egui::Ui, label: &str, value: &mut f32, range: std::ops::RangeInclusive<f32>) {
    ui.horizontal(|ui| {
        ui.label(RichText::new(label).size(11.0).color(MUTED));
        ui.add(egui::Slider::new(value, range).show_value(true));
    });
}
