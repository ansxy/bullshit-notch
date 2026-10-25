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
        let a = Levels {
            volume: Some((0.5, false)),
            brightness: Some(0.3),
        };
        let b = Levels {
            volume: Some((0.56, false)),
            brightness: Some(0.3),
        };
        let cur = HudSnapshot::default();
        assert!(!diff(None, a, &cur).visible());
        let s = diff(Some(a), b, &cur);
        assert!(s.visible() && s.kind == HudKind::Volume);
        let c = Levels {
            volume: Some((0.56, false)),
            brightness: Some(0.6),
        };
        assert_eq!(diff(Some(b), c, &cur).kind, HudKind::Brightness);
    }
}

pub fn spawn(ctx: egui::Context) -> tokio::sync::watch::Receiver<HudSnapshot> {
    super::spawn_poller(
        ctx,
        "hud",
        Duration::from_millis(150),
        HudSnapshot::default(),
        || {
            let mut reader = backend::Reader::new();
            let mut prev: Option<Levels> = None;
            let mut cur = HudSnapshot::default();
            move || {
                let next = reader.read();
                cur = diff(prev, next, &cur);
                prev = Some(next);
                Some(cur.clone())
            }
        },
    )
}

#[cfg(target_os = "linux")]
mod backend {
    use super::Levels;
    use std::io::{BufRead, BufReader};
    use std::path::PathBuf;
    use std::process::{Command, Stdio};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    /// Backlight via sysfs (cheap file read); volume re-queried only when
    /// `pactl subscribe` reports a sink change, so we don't fork every tick.
    pub struct Reader {
        backlight: Option<(PathBuf, f32)>,
        dirty: Arc<AtomicBool>,
        volume: Option<(f32, bool)>,
        subscribed: bool,
    }

    impl Reader {
        pub fn new() -> Self {
            let backlight = std::fs::read_dir("/sys/class/backlight")
                .ok()
                .and_then(|mut d| {
                    let p = d.next()?.ok()?.path();
                    let max: f32 = std::fs::read_to_string(p.join("max_brightness"))
                        .ok()?
                        .trim()
                        .parse()
                        .ok()?;
                    (max > 0.0).then_some((p, max))
                });
            let dirty = Arc::new(AtomicBool::new(true));
            let subscribed = subscribe(Arc::clone(&dirty));
            Self {
                backlight,
                dirty,
                volume: None,
                subscribed,
            }
        }

        pub fn read(&mut self) -> Levels {
            // Without pactl subscribe, poll volume every tick (wpctl is fast).
            if !self.subscribed || self.dirty.swap(false, Ordering::Relaxed) {
                self.volume = query_volume();
            }
            let brightness = self.backlight.as_ref().and_then(|(p, max)| {
                let cur: f32 = std::fs::read_to_string(p.join("brightness"))
                    .ok()?
                    .trim()
                    .parse()
                    .ok()?;
                Some((cur / max).clamp(0.0, 1.0))
            });
            Levels {
                volume: self.volume,
                brightness,
            }
        }
    }

    fn subscribe(dirty: Arc<AtomicBool>) -> bool {
        let Ok(mut child) = Command::new("pactl")
            .arg("subscribe")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        else {
            return false;
        };
        let Some(out) = child.stdout.take() else {
            return false;
        };
        std::thread::spawn(move || {
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                if line.contains("on sink") || line.contains("on server") {
                    dirty.store(true, Ordering::Relaxed);
                }
            }
            let _ = child.wait();
        });
        true
    }

    fn query_volume() -> Option<(f32, bool)> {
        let out = crate::platform::process::run_hidden_sync(
            "wpctl",
            &["get-volume", "@DEFAULT_AUDIO_SINK@"],
        )
        .ok();
        if let Some(o) = out.filter(|o| o.status == 0) {
            // "Volume: 0.45 [MUTED]"
            let v = o.stdout.split_whitespace().nth(1)?.parse::<f32>().ok()?;
            return Some((v.clamp(0.0, 1.0), o.stdout.contains("MUTED")));
        }
        let vol = crate::platform::process::run_hidden_sync(
            "pactl",
            &["get-sink-volume", "@DEFAULT_SINK@"],
        )
        .ok()?;
        let pct = vol
            .stdout
            .split('/')
            .nth(1)?
            .trim()
            .trim_end_matches('%')
            .trim()
            .parse::<f32>()
            .ok()?;
        let mute = crate::platform::process::run_hidden_sync(
            "pactl",
            &["get-sink-mute", "@DEFAULT_SINK@"],
        )
        .ok()?;
        Some(((pct / 100.0).clamp(0.0, 1.0), mute.stdout.contains("yes")))
    }
}

#[cfg(windows)]
mod backend {
    use super::Levels;
    use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
    use windows::Win32::Media::Audio::{
        eConsole, eRender, IMMDeviceEnumerator, MMDeviceEnumerator,
    };
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED,
    };

    /// WASAPI master volume. ponytail: brightness (WMI) not read; Windows shows its own flyout.
    pub struct Reader {
        endpoint: Option<IAudioEndpointVolume>,
    }

    impl Reader {
        pub fn new() -> Self {
            unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            }
            Self { endpoint: None }
        }

        fn endpoint() -> windows::core::Result<IAudioEndpointVolume> {
            unsafe {
                let en: IMMDeviceEnumerator =
                    CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
                let dev = en.GetDefaultAudioEndpoint(eRender, eConsole)?;
                dev.Activate(CLSCTX_ALL, None)
            }
        }

        pub fn read(&mut self) -> Levels {
            if self.endpoint.is_none() {
                self.endpoint = Self::endpoint().ok();
            }
            let volume = self.endpoint.as_ref().and_then(|e| unsafe {
                Some((
                    e.GetMasterVolumeLevelScalar().ok()?,
                    e.GetMute().ok()?.as_bool(),
                ))
            });
            if volume.is_none() {
                self.endpoint = None; // default device changed/unplugged; re-acquire next tick
            }
            Levels {
                volume,
                brightness: None,
            }
        }
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod backend {
    pub struct Reader;
    impl Reader {
        pub fn new() -> Self {
            Self
        }
        pub fn read(&mut self) -> super::Levels {
            super::Levels::default()
        }
    }
}
