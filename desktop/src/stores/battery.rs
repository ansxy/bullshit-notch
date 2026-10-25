//! Battery level + charger state (port of `Sources/Battery.swift`).

use std::time::{Duration, Instant};

/// How long the charger live activity stays up after plug/unplug.
pub const JUST_CHANGED: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, PartialEq, Default)]
pub struct BatterySnapshot {
    pub has_battery: bool,
    pub level: u8,
    pub charging: bool,
    pub plugged_in: bool,
    pub changed_at: Option<Instant>,
}

impl BatterySnapshot {
    pub fn just_changed(&self) -> bool {
        self.changed_at.is_some_and(|t| t.elapsed() < JUST_CHANGED)
    }

    pub fn demo() -> Self {
        Self {
            has_battery: true,
            level: 76,
            charging: true,
            plugged_in: true,
            changed_at: None,
        }
    }

    /// Carry `changed_at` forward, stamping it when the plug state flips.
    pub fn announce(mut self, prev: &BatterySnapshot) -> Self {
        self.changed_at = prev.changed_at;
        if prev.has_battery && self.plugged_in != prev.plugged_in {
            self.changed_at = Some(Instant::now());
        }
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plug_flip_announces() {
        let prev = BatterySnapshot { has_battery: true, level: 50, ..Default::default() };
        let next = BatterySnapshot { has_battery: true, level: 50, plugged_in: true, ..Default::default() }
            .announce(&prev);
        assert!(next.just_changed());
        let same = next.clone().announce(&next);
        assert_eq!(same.changed_at, next.changed_at);
    }
}

pub fn spawn(_ctx: egui::Context) -> tokio::sync::watch::Receiver<BatterySnapshot> {
    super::fixed(BatterySnapshot::default())
}
