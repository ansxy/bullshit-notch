//! Now playing (port of `Sources/NowPlaying.swift`).

use crate::palette::{self, Palette};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::watch;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaCommand {
    PlayPause,
    Next,
    Previous,
}

#[derive(Debug, Clone)]
pub struct NowPlayingSnapshot {
    pub player: Option<String>,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub playing: bool,
    pub duration: f64,
    /// Position as of `position_at`; use [`Self::elapsed`] for a live value.
    pub position: f64,
    pub position_at: Instant,
    /// Changes whenever the artwork changes, so the UI can re-upload the texture.
    pub art_key: String,
    pub artwork: Option<Arc<egui::ColorImage>>,
    pub palette: Option<Palette>,
}

impl Default for NowPlayingSnapshot {
    fn default() -> Self {
        Self {
            player: None,
            title: String::new(),
            artist: String::new(),
            album: String::new(),
            playing: false,
            duration: 0.0,
            position: 0.0,
            position_at: Instant::now(),
            art_key: String::new(),
            artwork: None,
            palette: None,
        }
    }
}

impl PartialEq for NowPlayingSnapshot {
    fn eq(&self, o: &Self) -> bool {
        self.player == o.player
            && self.title == o.title
            && self.artist == o.artist
            && self.album == o.album
            && self.playing == o.playing
            && (self.duration - o.duration).abs() < 0.5
            && (self.elapsed() - o.elapsed()).abs() < 1.5
            && self.art_key == o.art_key
    }
}

impl NowPlayingSnapshot {
    pub fn has_track(&self) -> bool {
        self.player.is_some() && !self.title.is_empty()
    }

    pub fn elapsed(&self) -> f64 {
        let live = if self.playing {
            self.position_at.elapsed().as_secs_f64()
        } else {
            0.0
        };
        let e = self.position + live;
        if self.duration > 0.0 {
            e.min(self.duration)
        } else {
            e
        }
    }

    /// Artwork palette, or seeded from title|artist while art is missing.
    pub fn active_palette(&self) -> Option<Palette> {
        if !self.has_track() {
            return None;
        }
        Some(
            self.palette.unwrap_or_else(|| {
                palette::seed_for_key(&format!("{}|{}", self.title, self.artist))
            }),
        )
    }

    /// Attach decoded artwork and derive its palette.
    pub fn with_artwork(mut self, key: String, img: Option<egui::ColorImage>) -> Self {
        self.art_key = key;
        self.palette = img.as_ref().map(|i| {
            let raw: Vec<u8> = i.pixels.iter().flat_map(|c| c.to_array()).collect();
            palette::extract(&raw, i.size[0], i.size[1])
        });
        self.artwork = img.map(Arc::new);
        self
    }

    pub fn demo() -> Self {
        let side = 120usize;
        let stops = [[242, 56, 122], [250, 133, 41], [107, 41, 199]];
        let mut img = egui::ColorImage::new([side, side], egui::Color32::BLACK);
        for y in 0..side {
            for x in 0..side {
                let t = (x + y) as f32 / (2 * side) as f32 * 2.0;
                let (a, b, f) = if t < 1.0 {
                    (stops[0], stops[1], t)
                } else {
                    (stops[1], stops[2], t - 1.0)
                };
                let l = |i: usize| (a[i] as f32 + (b[i] as f32 - a[i] as f32) * f) as u8;
                img.pixels[y * side + x] = egui::Color32::from_rgb(l(0), l(1), l(2));
            }
        }
        Self {
            player: Some("Spotify".into()),
            title: "Lofi Beats to Hallucinate To".into(),
            artist: "DJ Stochastic Parrot".into(),
            album: "Tokens".into(),
            playing: true,
            duration: 260.0,
            position: 134.0,
            position_at: Instant::now(),
            ..Default::default()
        }
        .with_artwork("demo".into(), Some(img))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn demo_has_palette_and_elapsed_advances_only_when_playing() {
        let d = NowPlayingSnapshot::demo();
        assert!(d.has_track() && d.palette.is_some());
        let mut paused = d.clone();
        paused.playing = false;
        assert_eq!(paused.elapsed(), 134.0);
    }
}

/// Raw player state from a platform backend.
#[derive(Debug, Clone, Default)]
pub struct Raw {
    pub player: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub playing: bool,
    pub duration: f64,
    pub position: f64,
}

static COMMANDS: OnceLock<Mutex<mpsc::Sender<MediaCommand>>> = OnceLock::new();

/// Queue a transport command for the active player (no-op until `spawn`).
pub fn send(cmd: MediaCommand) {
    if let Some(tx) = COMMANDS.get() {
        let _ = tx.lock().map(|t| t.send(cmd));
    }
}

pub fn spawn(ctx: egui::Context) -> watch::Receiver<NowPlayingSnapshot> {
    let (tx, rx) = watch::channel(NowPlayingSnapshot::default());
    let (cmd_tx, cmd_rx) = mpsc::channel();
    let _ = COMMANDS.set(Mutex::new(cmd_tx));
    let _ = std::thread::Builder::new()
        .name("now-playing".into())
        .spawn(move || {
            let mut backend = backend::Backend::new();
            let mut art_key = String::new();
            let mut art: Option<egui::ColorImage> = None;
            loop {
                let snap = match backend.poll() {
                    Some(r) => {
                        let key = format!("{}|{}|{}|{}", r.player, r.title, r.artist, r.album);
                        if key != art_key {
                            art_key = key.clone();
                            art = backend
                                .artwork()
                                .and_then(|b| palette::downscale_image_rgba(&b, 240));
                        }
                        NowPlayingSnapshot {
                            player: Some(r.player),
                            title: r.title,
                            artist: r.artist,
                            album: r.album,
                            playing: r.playing,
                            duration: r.duration,
                            position: r.position,
                            position_at: Instant::now(),
                            ..Default::default()
                        }
                        .with_artwork(art_key.clone(), art.clone())
                    }
                    None => {
                        art_key.clear();
                        NowPlayingSnapshot::default()
                    }
                };
                let changed = tx.send_if_modified(|cur| {
                    if *cur != snap {
                        *cur = snap;
                        true
                    } else {
                        false
                    }
                });
                if changed {
                    ctx.request_repaint();
                }
                if tx.is_closed() {
                    break;
                }
                // Doubles as the poll sleep; commands get applied immediately.
                if let Ok(cmd) = cmd_rx.recv_timeout(Duration::from_secs(1)) {
                    backend.command(cmd);
                    std::thread::sleep(Duration::from_millis(150));
                }
            }
        });
    rx
}

#[cfg(target_os = "linux")]
mod backend {
    use super::{MediaCommand, Raw};
    use std::collections::HashMap;
    use zbus::blocking::{Connection, Proxy};
    use zbus::zvariant::{OwnedValue, Value};

    const PLAYER_IFACE: &str = "org.mpris.MediaPlayer2.Player";

    /// MPRIS over the session bus. Prefers a playing player, else the first paused one.
    pub struct Backend {
        conn: Option<Connection>,
        active: Option<String>,
        art_url: String,
    }

    impl Backend {
        pub fn new() -> Self {
            Self {
                conn: Connection::session().ok(),
                active: None,
                art_url: String::new(),
            }
        }

        fn proxy<'a>(&'a self, dest: &'a str, iface: &'a str) -> Option<Proxy<'a>> {
            Proxy::new(
                self.conn.as_ref()?,
                dest.to_string(),
                "/org/mpris/MediaPlayer2",
                iface.to_string(),
            )
            .ok()
        }

        fn players(&self) -> Vec<String> {
            let Some(conn) = &self.conn else {
                return vec![];
            };
            let Ok(dbus) = zbus::blocking::fdo::DBusProxy::new(conn) else {
                return vec![];
            };
            dbus.list_names()
                .unwrap_or_default()
                .into_iter()
                .map(|n| n.to_string())
                .filter(|n| n.starts_with("org.mpris.MediaPlayer2."))
                .collect()
        }

        fn read(&self, dest: &str) -> Option<(Raw, String)> {
            let p = self.proxy(dest, PLAYER_IFACE)?;
            let status: String = p.get_property("PlaybackStatus").ok()?;
            if status == "Stopped" {
                return None;
            }
            let md: HashMap<String, OwnedValue> = p.get_property("Metadata").ok()?;
            let s = |k: &str| md.get(k).map(|v| text(v)).unwrap_or_default();
            let artist = md.get("xesam:artist").map(|v| text(v)).unwrap_or_default();
            let length = md.get("mpris:length").map(|v| int_us(v)).unwrap_or(0) as f64 / 1e6;
            let position = p.get_property::<i64>("Position").unwrap_or(0) as f64 / 1e6;
            let title = s("xesam:title");
            if title.is_empty() {
                return None;
            }
            let identity: String = self
                .proxy(dest, "org.mpris.MediaPlayer2")
                .and_then(|r| r.get_property("Identity").ok())
                .unwrap_or_else(|| {
                    dest.trim_start_matches("org.mpris.MediaPlayer2.")
                        .to_string()
                });
            Some((
                Raw {
                    player: identity,
                    title,
                    artist,
                    album: s("xesam:album"),
                    playing: status == "Playing",
                    duration: length,
                    position,
                },
                s("mpris:artUrl"),
            ))
        }

        pub fn poll(&mut self) -> Option<Raw> {
            if self.conn.is_none() {
                self.conn = Connection::session().ok();
            }
            let mut best: Option<(String, Raw, String)> = None;
            for name in self.players() {
                let Some((raw, art)) = self.read(&name) else {
                    continue;
                };
                let playing = raw.playing;
                if best.is_none() || playing {
                    best = Some((name, raw, art));
                }
                if playing {
                    break;
                }
            }
            let (name, raw, art) = best?;
            self.active = Some(name);
            self.art_url = art;
            Some(raw)
        }

        pub fn artwork(&mut self) -> Option<Vec<u8>> {
            let url = self.art_url.clone();
            if let Some(path) = url.strip_prefix("file://") {
                return std::fs::read(percent_decode(path)).ok();
            }
            if url.starts_with("http://") || url.starts_with("https://") {
                return crate::platform::http::get_bytes(&url, 8 << 20);
            }
            None
        }

        pub fn command(&mut self, cmd: MediaCommand) {
            let Some(dest) = self.active.clone() else {
                return;
            };
            let Some(p) = self.proxy(&dest, PLAYER_IFACE) else {
                return;
            };
            let method = match cmd {
                MediaCommand::PlayPause => "PlayPause",
                MediaCommand::Next => "Next",
                MediaCommand::Previous => "Previous",
            };
            let _ = p.call_method(method, &());
        }
    }

    /// mpris:length is `x` (i64) per spec but some players send `t` (u64).
    fn int_us(v: &OwnedValue) -> i64 {
        match &**v {
            Value::I64(n) => *n,
            Value::U64(n) => *n as i64,
            Value::I32(n) => *n as i64,
            Value::U32(n) => *n as i64,
            Value::F64(n) => *n as i64,
            _ => 0,
        }
    }

    /// String, object path, or string array (joined) → text.
    fn text(v: &Value) -> String {
        match v {
            Value::Str(s) => s.to_string(),
            Value::ObjectPath(p) => p.to_string(),
            Value::Value(inner) => text(inner),
            Value::Array(a) => a
                .iter()
                .map(text)
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(", "),
            _ => String::new(),
        }
    }

    fn percent_decode(s: &str) -> String {
        let b = s.as_bytes();
        let mut out = Vec::with_capacity(b.len());
        let mut i = 0;
        while i < b.len() {
            if b[i] == b'%' && i + 2 < b.len() {
                if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                    out.push(v);
                    i += 3;
                    continue;
                }
            }
            out.push(b[i]);
            i += 1;
        }
        String::from_utf8_lossy(&out).into_owned()
    }
}

#[cfg(windows)]
mod backend {
    use super::{MediaCommand, Raw};
    use windows::Media::Control::{
        GlobalSystemMediaTransportControlsSession as Session,
        GlobalSystemMediaTransportControlsSessionManager as Manager,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
    };
    use windows::Storage::Streams::DataReader;

    /// Global System Media Transport Controls (whatever app owns the media session).
    pub struct Backend {
        manager: Option<Manager>,
        session: Option<Session>,
    }

    impl Backend {
        pub fn new() -> Self {
            unsafe {
                let _ = windows::Win32::System::WinRT::RoInitialize(
                    windows::Win32::System::WinRT::RO_INIT_MULTITHREADED,
                );
            }
            Self {
                manager: None,
                session: None,
            }
        }

        fn read(s: &Session) -> windows::core::Result<Raw> {
            let props = s.TryGetMediaPropertiesAsync()?.get()?;
            let info = s.GetPlaybackInfo()?;
            let tl = s.GetTimelineProperties()?;
            let ticks = |d: windows::Foundation::TimeSpan| d.Duration as f64 / 10_000_000.0;
            let app = s.SourceAppUserModelId()?.to_string();
            let player = app
                .rsplit(['!', '\\', '.'])
                .next()
                .unwrap_or(&app)
                .to_string();
            Ok(Raw {
                player,
                title: props.Title()?.to_string(),
                artist: props.Artist()?.to_string(),
                album: props.AlbumTitle()?.to_string(),
                playing: info.PlaybackStatus()? == Status::Playing,
                duration: ticks(tl.EndTime()?) - ticks(tl.StartTime()?),
                position: ticks(tl.Position()?),
            })
        }

        pub fn poll(&mut self) -> Option<Raw> {
            if self.manager.is_none() {
                self.manager = Manager::RequestAsync().ok()?.get().ok();
            }
            self.session = self.manager.as_ref()?.GetCurrentSession().ok();
            let raw = Self::read(self.session.as_ref()?).ok()?;
            (!raw.title.is_empty()).then_some(raw)
        }

        pub fn artwork(&mut self) -> Option<Vec<u8>> {
            let s = self.session.as_ref()?;
            let thumb = s
                .TryGetMediaPropertiesAsync()
                .ok()?
                .get()
                .ok()?
                .Thumbnail()
                .ok()?;
            let stream = thumb.OpenReadAsync().ok()?.get().ok()?;
            let size = stream.Size().ok()? as u32;
            if size == 0 || size > 8 << 20 {
                return None;
            }
            let reader = DataReader::CreateDataReader(&stream).ok()?;
            reader.LoadAsync(size).ok()?.get().ok()?;
            let mut buf = vec![0u8; size as usize];
            reader.ReadBytes(&mut buf).ok()?;
            Some(buf)
        }

        pub fn command(&mut self, cmd: MediaCommand) {
            let Some(s) = &self.session else { return };
            let op = match cmd {
                MediaCommand::PlayPause => s.TryTogglePlayPauseAsync(),
                MediaCommand::Next => s.TrySkipNextAsync(),
                MediaCommand::Previous => s.TrySkipPreviousAsync(),
            };
            if let Ok(op) = op {
                let _ = op.get();
            }
        }
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod backend {
    use super::{MediaCommand, Raw};
    pub struct Backend;
    impl Backend {
        pub fn new() -> Self {
            Self
        }
        pub fn poll(&mut self) -> Option<Raw> {
            None
        }
        pub fn artwork(&mut self) -> Option<Vec<u8>> {
            None
        }
        pub fn command(&mut self, _cmd: MediaCommand) {}
    }
}
