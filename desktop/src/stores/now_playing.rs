//! Now playing (port of `Sources/NowPlaying.swift`).

use crate::palette::{self, Palette};
use std::sync::Arc;
use std::time::Instant;

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
        let live = if self.playing { self.position_at.elapsed().as_secs_f64() } else { 0.0 };
        let e = self.position + live;
        if self.duration > 0.0 { e.min(self.duration) } else { e }
    }

    /// Artwork palette, or seeded from title|artist while art is missing.
    pub fn active_palette(&self) -> Option<Palette> {
        if !self.has_track() {
            return None;
        }
        Some(self.palette.unwrap_or_else(|| palette::seed_for_key(&format!("{}|{}", self.title, self.artist))))
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
                let (a, b, f) = if t < 1.0 { (stops[0], stops[1], t) } else { (stops[1], stops[2], t - 1.0) };
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

pub fn spawn(_ctx: egui::Context) -> tokio::sync::watch::Receiver<NowPlayingSnapshot> {
    super::fixed(NowPlayingSnapshot::default())
}

pub fn send(_cmd: MediaCommand) {}
