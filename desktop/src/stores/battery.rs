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
        let prev = BatterySnapshot {
            has_battery: true,
            level: 50,
            ..Default::default()
        };
        let next = BatterySnapshot {
            has_battery: true,
            level: 50,
            plugged_in: true,
            ..Default::default()
        }
        .announce(&prev);
        assert!(next.just_changed());
        let same = next.clone().announce(&next);
        assert_eq!(same.changed_at, next.changed_at);
    }
}

pub fn spawn(ctx: egui::Context) -> tokio::sync::watch::Receiver<BatterySnapshot> {
    let mut prev = read().unwrap_or_default();
    let init = prev.clone();
    super::spawn_poller(ctx, "battery", Duration::from_secs(2), init, move || {
        move || {
            let next = read()?.announce(&prev);
            prev = next.clone();
            Some(next)
        }
    })
}

#[cfg(target_os = "linux")]
fn read() -> Option<BatterySnapshot> {
    use std::fs;
    let mut snap = BatterySnapshot::default();
    let mut mains_online = None;
    for entry in fs::read_dir("/sys/class/power_supply").ok()?.flatten() {
        let p = entry.path();
        let attr = |name: &str| {
            fs::read_to_string(p.join(name))
                .map(|s| s.trim().to_string())
                .ok()
        };
        match attr("type").as_deref() {
            Some("Battery") if !snap.has_battery => {
                if attr("scope").as_deref() == Some("Device") {
                    continue; // mouse/keyboard batteries
                }
                snap.has_battery = true;
                snap.level = attr("capacity").and_then(|s| s.parse().ok()).unwrap_or(0);
                let status = attr("status").unwrap_or_default();
                snap.charging = status == "Charging";
                if status == "Charging" || status == "Full" {
                    snap.plugged_in = true;
                }
            }
            Some("Mains") | Some("USB") => {
                if attr("online").as_deref() == Some("1") {
                    mains_online = Some(true);
                } else if mains_online.is_none() {
                    mains_online = Some(false);
                }
            }
            _ => {}
        }
    }
    if let Some(online) = mains_online {
        snap.plugged_in = online;
    }
    Some(snap)
}

#[cfg(windows)]
fn read() -> Option<BatterySnapshot> {
    use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
    let mut s = SYSTEM_POWER_STATUS::default();
    unsafe { GetSystemPowerStatus(&mut s).ok()? };
    let no_battery = s.BatteryFlag & 128 != 0 || s.BatteryFlag == 255;
    Some(BatterySnapshot {
        has_battery: !no_battery,
        level: if s.BatteryLifePercent <= 100 {
            s.BatteryLifePercent
        } else {
            0
        },
        charging: s.BatteryFlag & 8 != 0,
        plugged_in: s.ACLineStatus == 1,
        changed_at: None,
    })
}

#[cfg(not(any(target_os = "linux", windows)))]
fn read() -> Option<BatterySnapshot> {
    None
}
