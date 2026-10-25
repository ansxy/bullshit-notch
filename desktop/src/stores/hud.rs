//! Volume / brightness HUD (port of `Sources/HUD.swift`).
//!
//! ponytail: macOS swallows media keys via a CGEvent tap. Here we only observe —
//! poll the system level and pop the HUD when it changes. The OS flyout may still show.

use std::time::{Duration, Instant};

pub const VISIBLE_FOR: Duration = Duration::from_millis(1500);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum HudKind {
    #[default]
    Volume,
    Brightness,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct HudSnapshot {
    pub kind: HudKind,
    pub level: f32,
    pub muted: bool,
    pub shown_at: Option<Instant>,
}

impl HudSnapshot {
    pub fn visible(&self) -> bool {
        self.shown_at.is_some_and(|t| t.elapsed() < VISIBLE_FOR)
    }
}

/// Raw levels read from the system; `None` = unavailable.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Levels {
    pub volume: Option<(f32, bool)>,
    pub brightness: Option<f32>,
}

/// Diff two level reads into a HUD update. First read (prev = None) never shows.
pub fn diff(prev: Option<Levels>, next: Levels, cur: &HudSnapshot) -> HudSnapshot {
    let Some(prev) = prev else {
        return cur.clone();
    };
    if let (Some((pv, pm)), Some((nv, nm))) = (prev.volume, next.volume) {
        if (pv - nv).abs() > 0.004 || pm != nm {
            return HudSnapshot {
                kind: HudKind::Volume,
                level: nv,
                muted: nm,
                shown_at: Some(Instant::now()),
            };
        }
    }
    if let (Some(pb), Some(nb)) = (prev.brightness, next.brightness) {
        if (pb - nb).abs() > 0.004 {
            return HudSnapshot {
                kind: HudKind::Brightness,
                level: nb,
                muted: false,
                shown_at: Some(Instant::now()),
            };
        }
    }
    cur.clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn volume_change_shows_hud() {
        let a = Levels { volume: Some((0.5, false)), brightness: Some(0.3) };
        let b = Levels { volume: Some((0.56, false)), brightness: Some(0.3) };
        let cur = HudSnapshot::default();
        assert!(!diff(None, a, &cur).visible());
        let s = diff(Some(a), b, &cur);
        assert!(s.visible() && s.kind == HudKind::Volume);
        let c = Levels { volume: Some((0.56, false)), brightness: Some(0.6) };
        assert_eq!(diff(Some(b), c, &cur).kind, HudKind::Brightness);
    }
}

pub fn spawn(_ctx: egui::Context) -> tokio::sync::watch::Receiver<HudSnapshot> {
    super::fixed(HudSnapshot::default())
}
