use serde::{Deserialize, Serialize};
use std::fs;
use std::io;
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum AgentAnimationStyle {
    #[default]
    Fire,
    Scanner,
    Lightning,
    Plasma,
    Matrix,
    Rave,
    Warp,
    RandomBullshit,
}

impl AgentAnimationStyle {
    pub const ALL: [Self; 8] = [
        Self::Fire,
        Self::Scanner,
        Self::Lightning,
        Self::Plasma,
        Self::Matrix,
        Self::Rave,
        Self::Warp,
        Self::RandomBullshit,
    ];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum NotchTheme {
    Dark,
    #[default]
    Glass,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum GlassMaterial {
    #[default]
    UltraThin,
    Thin,
    Regular,
    Thick,
    UltraThick,
    Bar,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum TerminalApp {
    #[default]
    Auto,
    Iterm,
    Terminal,
    Warp,
    Ghostty,
    WindowsTerminal,
    Powershell,
    Wezterm,
    Alacritty,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ContainerCli {
    #[default]
    Auto,
    Docker,
    Podman,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Prefs {
    pub open_on_hover: bool,
    pub live_agents: bool,
    pub live_music: bool,
    pub live_battery: bool,
    pub agenda: bool,
    pub mirror: bool,
    pub replace_hud: bool,
    pub width_adjust: f32,
    pub height_adjust: f32,
    pub idle_width: f32,
    pub tab_home: bool,
    pub tab_shelf: bool,
    pub tab_topbar: bool,
    pub music: bool,
    pub air_drop: bool,
    pub section_git: bool,
    pub section_work: bool,
    pub section_containers: bool,
    pub section_agents: bool,
    pub section_qa: bool,
    pub claude_daily_limit: u64,
    pub claude_weekly_limit: u64,
    pub agy_daily_limit: u64,
    pub agy_weekly_limit: u64,
    pub cursor_daily_limit: u64,
    pub cursor_weekly_limit: u64,
    pub commandcode_daily_limit: u64,
    pub commandcode_weekly_limit: u64,
    pub usage_claude: bool,
    pub usage_antigravity: bool,
    pub usage_cursor: bool,
    pub usage_commandcode: bool,
    pub theme: NotchTheme,
    pub glass_material: GlassMaterial,
    pub glass_blur_opacity: f32,
    pub glass_tint_opacity: f32,
    pub glass_top_fade: f32,
    pub glass_sheen: f32,
    pub glass_border_opacity: f32,
    pub glass_shadow_opacity: f32,
    pub glass_accent_glow: f32,
    pub glass_card_opacity: f32,
    pub glass_card_border_opacity: f32,
    pub glass_card_blur: bool,
    pub glass_closed: bool,
    pub music_ambient: bool,
    pub music_ambient_intensity: f32,
    pub agent_animation: AgentAnimationStyle,
    pub agent_animation_always_on: bool,
    pub preferred_terminal: TerminalApp,
    pub default_agent_command: String,
    pub container_cli: ContainerCli,
}

impl Default for Prefs {
    fn default() -> Self {
        Self {
            open_on_hover: true,
            live_agents: true,
            live_music: true,
            live_battery: true,
            agenda: true,
            mirror: true,
            replace_hud: false,
            width_adjust: 0.0,
            height_adjust: 0.0,
            idle_width: 48.0,
            tab_home: true,
            tab_shelf: true,
            tab_topbar: true,
            music: true,
            air_drop: true,
            section_git: true,
            section_work: true,
            section_containers: true,
            section_agents: true,
            section_qa: true,
            claude_daily_limit: 12_500_000,
            claude_weekly_limit: 90_000_000,
            agy_daily_limit: 8_000_000,
            agy_weekly_limit: 50_000_000,
            cursor_daily_limit: 150,
            cursor_weekly_limit: 500,
            commandcode_daily_limit: 8_000_000,
            commandcode_weekly_limit: 50_000_000,
            usage_claude: true,
            usage_antigravity: true,
            usage_cursor: true,
            usage_commandcode: true,
            theme: NotchTheme::Glass,
            glass_material: GlassMaterial::UltraThin,
            glass_blur_opacity: 0.90,
            glass_tint_opacity: 0.32,
            glass_top_fade: 0.75,
            glass_sheen: 0.12,
            glass_border_opacity: 0.28,
            glass_shadow_opacity: 0.40,
            glass_accent_glow: 0.18,
            glass_card_opacity: 0.07,
            glass_card_border_opacity: 0.15,
            glass_card_blur: false,
            glass_closed: false,
            music_ambient: true,
            music_ambient_intensity: 0.75,
            agent_animation: AgentAnimationStyle::Fire,
            agent_animation_always_on: false,
            preferred_terminal: TerminalApp::Auto,
            default_agent_command: "claude".into(),
            container_cli: ContainerCli::Auto,
        }
    }
}

impl Prefs {
    pub fn config_path() -> Option<PathBuf> {
        directories::ProjectDirs::from("com", "ansxy", "BullshitNotch")
            .map(|d| d.config_dir().join("settings.json"))
    }

    pub fn load() -> Self {
        let Some(path) = Self::config_path() else {
            return Self::default();
        };
        let Ok(raw) = fs::read_to_string(&path) else {
            return Self::default();
        };
        let mut prefs: Self = serde_json::from_str(&raw).unwrap_or_default();
        prefs.migrate_legacy_limits();
        prefs
    }

    pub fn save(&self) -> io::Result<()> {
        let Some(path) = Self::config_path() else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "no config directory",
            ));
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(self)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        fs::write(path, json)
    }

    pub fn harness_enabled(&self, h: crate::stores::agents::Harness) -> bool {
        use crate::stores::agents::Harness::*;
        match h {
            Claude => self.usage_claude,
            Antigravity => self.usage_antigravity,
            Cursor => self.usage_cursor,
            CommandCode => self.usage_commandcode,
        }
    }

    pub fn limits_for(&self, h: crate::stores::agents::Harness) -> (u64, u64) {
        use crate::stores::agents::Harness::*;
        match h {
            Claude => (self.claude_daily_limit, self.claude_weekly_limit),
            Antigravity => (self.agy_daily_limit, self.agy_weekly_limit),
            Cursor => (self.cursor_daily_limit, self.cursor_weekly_limit),
            CommandCode => (self.commandcode_daily_limit, self.commandcode_weekly_limit),
        }
    }

    pub fn set_limits(&mut self, h: crate::stores::agents::Harness, session: u64, weekly: u64) {
        use crate::stores::agents::Harness::*;
        match h {
            Claude => {
                self.claude_daily_limit = session;
                self.claude_weekly_limit = weekly;
            }
            Antigravity => {
                self.agy_daily_limit = session;
                self.agy_weekly_limit = weekly;
            }
            Cursor => {
                self.cursor_daily_limit = session;
                self.cursor_weekly_limit = weekly;
            }
            CommandCode => {
                self.commandcode_daily_limit = session;
                self.commandcode_weekly_limit = weekly;
            }
        }
    }

    /// Legacy inflated defaults migrate automatically to current tiers.
    pub fn migrate_legacy_limits(&mut self) {
        if self.claude_daily_limit >= 250_000_000 {
            self.claude_daily_limit = 12_500_000;
        }
        if self.claude_weekly_limit >= 1_500_000_000 {
            self.claude_weekly_limit = 90_000_000;
        }
        if self.agy_daily_limit >= 25_000_000 {
            self.agy_daily_limit = 8_000_000;
        }
        if self.agy_weekly_limit >= 100_000_000 {
            self.agy_weekly_limit = 50_000_000;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefs_defaults_and_legacy_limit_migration() {
        let mut p = Prefs::default();
        assert!(p.open_on_hover);
        assert_eq!(p.idle_width, 48.0);
        assert_eq!(p.claude_daily_limit, 12_500_000);
        assert_eq!(p.claude_weekly_limit, 90_000_000);

        p.claude_daily_limit = 250_000_000;
        p.claude_weekly_limit = 1_500_000_000;
        p.agy_daily_limit = 25_000_000;
        p.agy_weekly_limit = 100_000_000;
        p.migrate_legacy_limits();
        assert_eq!(p.claude_daily_limit, 12_500_000);
        assert_eq!(p.agy_daily_limit, 8_000_000);
    }

    #[test]
    fn prefs_roundtrip_json() {
        let mut p = Prefs::default();
        p.agent_animation = AgentAnimationStyle::Matrix;
        let json = serde_json::to_string(&p).unwrap();
        let decoded: Prefs = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.agent_animation, AgentAnimationStyle::Matrix);
    }
}
