//! Three-tone vibrant palette from album artwork (port of `NowPlaying.extractPalette`
//! / `seedPalette` in `Sources/NowPlaying.swift`).

use egui::Color32;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Palette {
    pub primary: Color32,
    pub secondary: Color32,
    pub tertiary: Color32,
}

impl Palette {
    pub fn fallback() -> Self {
        Self {
            primary: hsb(0.76, 0.78, 0.92),
            secondary: hsb(0.90, 0.75, 0.88),
            tertiary: hsb(0.58, 0.72, 0.80),
        }
    }
}

/// HSB (all 0..1) → sRGB.
pub fn hsb(h: f32, s: f32, b: f32) -> Color32 {
    let h = h.rem_euclid(1.0) * 6.0;
    let i = h.floor() as i32;
    let f = h - i as f32;
    let p = b * (1.0 - s);
    let q = b * (1.0 - s * f);
    let t = b * (1.0 - s * (1.0 - f));
    let (r, g, bl) = match i.rem_euclid(6) {
        0 => (b, t, p),
        1 => (q, b, p),
        2 => (p, b, t),
        3 => (p, q, b),
        4 => (t, p, b),
        _ => (b, p, q),
    };
    Color32::from_rgb((r * 255.0) as u8, (g * 255.0) as u8, (bl * 255.0) as u8)
}

/// sRGB (0..255) → HSB (0..1).
pub fn to_hsb(r: u8, g: u8, b: u8) -> (f32, f32, f32) {
    let (r, g, b) = (r as f32 / 255.0, g as f32 / 255.0, b as f32 / 255.0);
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let d = max - min;
    let s = if max > 0.0 { d / max } else { 0.0 };
    let h = if d == 0.0 {
        0.0
    } else if max == r {
        ((g - b) / d).rem_euclid(6.0) / 6.0
    } else if max == g {
        ((b - r) / d + 2.0) / 6.0
    } else {
        ((r - g) / d + 4.0) / 6.0
    };
    (h, s, max)
}

/// djb2 (5381) hash → deterministic vibrant palette for tracks without artwork.
pub fn seed_for_key(key: &str) -> Palette {
    let mut hash: u64 = 5381;
    for byte in key.bytes() {
        hash = (hash << 5).wrapping_add(hash).wrapping_add(byte as u64);
    }
    let h1 = (hash % 360) as f32 / 360.0;
    let h2 = (h1 + 0.14).rem_euclid(1.0);
    let h3 = (h1 + 0.82).rem_euclid(1.0);
    Palette {
        primary: hsb(h1, 0.78, 0.92),
        secondary: hsb(h2, 0.74, 0.88),
        tertiary: hsb(h3, 0.70, 0.78),
    }
}

#[derive(Default, Clone, Copy)]
struct Bucket {
    weight: f32,
    h: f32,
    s: f32,
    b: f32,
}

impl Bucket {
    fn hue(&self) -> f32 {
        self.h / self.weight
    }
}

fn hue_distance(a: f32, b: f32) -> f32 {
    let d = (a - b).abs();
    d.min(1.0 - d)
}

fn make_vivid(bk: &Bucket, sat_floor: f32, bright_floor: f32, bright_ceil: f32) -> (f32, f32, f32) {
    let h = bk.hue().rem_euclid(1.0);
    let raw_s = bk.s / bk.weight;
    let raw_b = bk.b / bk.weight;
    let s = if raw_s < 0.08 { 0.35 } else { (raw_s * 1.25).max(sat_floor).min(0.96) };
    let b = (raw_b * 1.15).max(bright_floor).min(bright_ceil);
    (h, s, b)
}

/// Sample RGBA on a 16×16 grid, bucket by hue weighted by vibrancy, pick up to 3 distinct hues.
pub fn extract(rgba: &[u8], width: usize, height: usize) -> Palette {
    if width == 0 || height == 0 || rgba.len() < width * height * 4 {
        return Palette::fallback();
    }
    const SIDE: usize = 16;
    const BINS: usize = 12;
    let mut bins = [Bucket::default(); BINS];
    for gy in 0..SIDE {
        for gx in 0..SIDE {
            let x = (gx * width + width / 2) / SIDE;
            let y = (gy * height + height / 2) / SIDE;
            let i = (y.min(height - 1) * width + x.min(width - 1)) * 4;
            if rgba[i + 3] < 16 {
                continue;
            }
            let (h, s, b) = to_hsb(rgba[i], rgba[i + 1], rgba[i + 2]);
            if b <= 0.10 {
                continue;
            }
            let vib = (s * s).max(0.05) * (1.0 - (b - 0.65).abs() * 0.6);
            let idx = ((h * BINS as f32) as usize).min(BINS - 1);
            let bk = &mut bins[idx];
            bk.weight += vib;
            bk.h += h * vib;
            bk.s += s * vib;
            bk.b += b * vib;
        }
    }
    let mut ranked: Vec<Bucket> = bins.iter().copied().filter(|b| b.weight > 0.0).collect();
    ranked.sort_by(|a, b| b.weight.partial_cmp(&a.weight).unwrap_or(std::cmp::Ordering::Equal));
    let Some(first) = ranked.first().copied() else {
        return Palette::fallback();
    };

    let p1 = make_vivid(&first, 0.68, 0.76, 0.98);
    let second = ranked
        .iter()
        .skip(1)
        .find(|b| hue_distance(b.hue(), p1.0) >= 0.11 && b.weight >= first.weight * 0.14);
    let p2 = match second {
        Some(bk) => make_vivid(bk, 0.64, 0.72, 0.95),
        None => (
            (p1.0 + 0.12).rem_euclid(1.0),
            (p1.1 * 0.95).clamp(0.60, 0.95),
            (p1.2 * 0.92).clamp(0.68, 0.92),
        ),
    };
    let third = ranked.iter().skip(1).find(|b| {
        hue_distance(b.hue(), p1.0) >= 0.14
            && hue_distance(b.hue(), p2.0) >= 0.11
            && b.weight >= first.weight * 0.08
    });
    let c3 = match third {
        Some(bk) => {
            let (h, s, b) = make_vivid(bk, 0.58, 0.62, 0.88);
            hsb(h, s, b)
        }
        None => hsb((p1.0 + 0.86).rem_euclid(1.0), (p1.1 * 0.9).clamp(0.55, 0.90), 0.75),
    };
    Palette {
        primary: hsb(p1.0, p1.1, p1.2),
        secondary: hsb(p2.0, p2.1, p2.2),
        tertiary: c3,
    }
}

/// Decode + shrink artwork to ≤`max` px per side so hi-res covers don't waste RAM.
pub fn downscale_image_rgba(bytes: &[u8], max: u32) -> Option<egui::ColorImage> {
    let img = image::load_from_memory(bytes).ok()?;
    let img = if img.width() > max || img.height() > max {
        img.thumbnail(max, max)
    } else {
        img
    };
    let rgba = img.to_rgba8();
    Some(egui::ColorImage::from_rgba_unmultiplied(
        [rgba.width() as usize, rgba.height() as usize],
        rgba.as_raw(),
    ))
}

/// Linear blend, used for palette cross-fades.
pub fn mix(a: Color32, b: Color32, t: f32) -> Color32 {
    let t = t.clamp(0.0, 1.0);
    let l = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t) as u8;
    Color32::from_rgba_unmultiplied(l(a.r(), b.r()), l(a.g(), b.g()), l(a.b(), b.b()), l(a.a(), b.a()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seed_is_deterministic_and_distinct() {
        assert_eq!(seed_for_key("a|b"), seed_for_key("a|b"));
        assert_ne!(seed_for_key("a|b").primary, seed_for_key("c|d").primary);
    }

    #[test]
    fn extract_picks_dominant_red() {
        let mut px = Vec::new();
        for _ in 0..(32 * 32) {
            px.extend_from_slice(&[230, 30, 40, 255]);
        }
        let p = extract(&px, 32, 32);
        assert!(p.primary.r() > 180 && p.primary.g() < 120, "{:?}", p.primary);
    }

    #[test]
    fn black_image_falls_back() {
        let px = vec![0u8; 8 * 8 * 4];
        assert_eq!(extract(&px, 8, 8), Palette::fallback());
    }

    #[test]
    fn hsb_roundtrip() {
        let c = hsb(0.33, 0.8, 0.9);
        let (h, s, b) = to_hsb(c.r(), c.g(), c.b());
        assert!((h - 0.33).abs() < 0.01 && (s - 0.8).abs() < 0.02 && (b - 0.9).abs() < 0.01);
    }

    #[test]
    fn downscale_caps_size() {
        let img = image::RgbaImage::from_pixel(600, 300, image::Rgba([10, 200, 30, 255]));
        let mut buf = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(img)
            .write_to(&mut buf, image::ImageFormat::Png)
            .unwrap();
        let out = downscale_image_rgba(buf.get_ref(), 240).unwrap();
        assert!(out.size[0] <= 240 && out.size[1] <= 240);
    }
}
