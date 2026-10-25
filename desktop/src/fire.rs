use crate::config::AgentAnimationStyle;

/// Procedural 140×14 notch animation (Doom fire + 7 other styles).
#[derive(Debug, Clone)]
pub struct Fire {
    heat: Vec<i32>,
    scanner_trail: Vec<f64>,
    scanner_head: f64,
    lightning_main: Vec<i32>,
    lightning_fork: Vec<i32>,
    pub steps: usize,
    palette: [[u8; 3]; 7],
}

impl Fire {
    pub const COLS: usize = 140;
    pub const ROWS: usize = 15;
    pub const DRAW_ROWS: usize = 14;
    pub const MAX_HEAT: i32 = 14;
    const RECOLOR_STEPS: usize = 143;
    const CYCLE_STYLES: [AgentAnimationStyle; 7] = [
        AgentAnimationStyle::Fire,
        AgentAnimationStyle::Scanner,
        AgentAnimationStyle::Lightning,
        AgentAnimationStyle::Plasma,
        AgentAnimationStyle::Matrix,
        AgentAnimationStyle::Rave,
        AgentAnimationStyle::Warp,
    ];

    pub fn new() -> Self {
        Self {
            heat: vec![0; Self::COLS * Self::ROWS],
            scanner_trail: vec![0.0; Self::COLS],
            scanner_head: Self::COLS as f64 / 2.0,
            lightning_main: vec![9; Self::COLS],
            lightning_fork: vec![10; Self::COLS],
            steps: 0,
            palette: Self::random_palette(),
        }
    }

    pub fn random_palette() -> [[u8; 3]; 7] {
        let hue = fastrand_f32();
        let mut out = [[0u8; 3]; 7];
        for i in 0..7 {
            let t = i as f32 / 6.0;
            let h = (hue + 0.12 * t).rem_euclid(1.0);
            let s = 1.0 - 0.75 * t * t * t;
            let b = 0.35 + 0.6 * t;
            out[i] = hsb_to_rgb(h, s, b);
        }
        out
    }

    pub fn resolved(&self, style: AgentAnimationStyle) -> AgentAnimationStyle {
        if style == AgentAnimationStyle::RandomBullshit {
            Self::CYCLE_STYLES[(self.steps / 115) % Self::CYCLE_STYLES.len()]
        } else {
            style
        }
    }

    pub fn accent(&self, style: AgentAnimationStyle) -> [u8; 4] {
        let rgb = match self.resolved(style) {
            AgentAnimationStyle::Fire | AgentAnimationStyle::RandomBullshit => self.palette[4],
            AgentAnimationStyle::Scanner => {
                let hue = ((self.steps as f64) * 0.004).rem_euclid(1.0) as f32;
                hsb_to_rgb(hue, 0.85, 1.0)
            }
            AgentAnimationStyle::Lightning => hsb_to_rgb(0.56, 0.80, 1.0),
            AgentAnimationStyle::Plasma => {
                let hue = (0.75 + (self.steps as f64 * 0.05).sin() * 0.22).rem_euclid(1.0) as f32;
                hsb_to_rgb((hue + 1.0).rem_euclid(1.0), 0.85, 0.98)
            }
            AgentAnimationStyle::Matrix => hsb_to_rgb(0.37, 0.90, 0.95),
            AgentAnimationStyle::Rave => {
                let hue = ((self.steps as f64) * 0.025).rem_euclid(1.0) as f32;
                hsb_to_rgb(hue, 0.90, 1.0)
            }
            AgentAnimationStyle::Warp => hsb_to_rgb(0.60, 0.75, 1.0),
        };
        [rgb[0], rgb[1], rgb[2], 255]
    }

    pub fn step(&mut self) {
        self.steps += 1;
        if self.steps % Self::RECOLOR_STEPS == 0 {
            self.palette = Self::random_palette();
        }
        let cols = Self::COLS;
        let rows = Self::ROWS;

        for c in 0..cols {
            // Match macOS Doom fire edge taper (Sources/Agents.swift).
            let edge_dist = c.min(cols - 1 - c);
            let taper = if edge_dist < 5 {
                (5 - edge_dist) as i32
            } else {
                0
            };
            self.heat[(rows - 1) * cols + c] = (Self::MAX_HEAT - taper).max(0);
        }
        for r in 0..(rows - 1) {
            for c in 0..cols {
                let rand = (fastrand_u32() % 4) as i32;
                let to = ((c as i32 - rand + 1 + cols as i32) as usize) % cols;
                self.heat[r * cols + to] = (self.heat[(r + 1) * cols + c] - rand).max(0);
            }
        }

        let sweep_phase = self.steps as f64 * 0.11;
        self.scanner_head = (sweep_phase.sin() * 0.5 + 0.5) * (cols - 1) as f64;
        for c in 0..cols {
            self.scanner_trail[c] *= 0.82;
            let d = (c as f64 - self.scanner_head).abs();
            if d < 8.0 {
                self.scanner_trail[c] = self.scanner_trail[c].max(1.0 - d / 8.0);
            }
        }

        let d_rows = Self::DRAW_ROWS;
        let mid = d_rows / 2;
        let mut y_main = {
            let lo = 3.max(mid.saturating_sub(2));
            let hi = (d_rows - 2).min(mid + 3).max(lo);
            (lo + (fastrand_u32() as usize % (hi - lo + 1))) as f64
        };
        let mut y_fork = y_main + (fastrand_i32(-2, 2) as f64);
        for c in 0..cols {
            y_main += fastrand_f64(-1.6, 1.6);
            y_main += (d_rows as f64 * 0.62 - y_main) * 0.18;
            y_main = y_main.clamp(2.0, (d_rows - 2) as f64);
            self.lightning_main[c] = y_main.round() as i32;

            if c % 9 == 0 {
                y_fork = y_main + fastrand_i32(-2, 2) as f64;
            } else {
                y_fork += fastrand_f64(-1.8, 1.8);
            }
            y_fork = y_fork.clamp(1.0, (d_rows - 1) as f64);
            self.lightning_fork[c] = y_fork.round() as i32;
        }
    }

    fn color(&self, row: usize, col: usize, style: AgentAnimationStyle) -> Option<[u8; 4]> {
        let d_rows = Self::DRAW_ROWS;
        let edge_dist = col.min(Self::COLS - 1 - col);
        let corner_mask = if edge_dist < 4 {
            (edge_dist + 1) as f64 / 5.0
        } else {
            1.0
        };

        match self.resolved(style) {
            AgentAnimationStyle::Fire => {
                let h = self.heat[row * Self::COLS + col];
                if h == 0 {
                    return None;
                }
                let idx = ((h - 1) * self.palette.len() as i32 / Self::MAX_HEAT)
                    .clamp(0, self.palette.len() as i32 - 1) as usize;
                let rgb = self.palette[idx];
                Some([rgb[0], rgb[1], rgb[2], 255])
            }
            AgentAnimationStyle::Scanner => {
                let trail = self.scanner_trail[col] * corner_mask;
                if trail <= 0.04 {
                    return None;
                }
                let v_norm = (row + 1) as f64 / d_rows as f64;
                let vertical_profile = v_norm.powf(1.35);
                let head_dist = (col as f64 - self.scanner_head).abs();
                let is_core = head_dist < 3.2 && row >= d_rows - 5;
                let intensity = (trail * (0.35 + 0.75 * vertical_profile)
                    + if head_dist < 4.5 {
                        (1.0 - head_dist / 4.5) * 0.5
                    } else {
                        0.0
                    })
                .min(1.0);
                if intensity <= 0.08 {
                    return None;
                }
                let base_hue =
                    (self.steps as f64 * 0.004 + (1.0 - trail) * 0.08).rem_euclid(1.0) as f32;
                let sat = if is_core {
                    0.18
                } else {
                    (1.0 - intensity * 0.45).max(0.25) as f32
                };
                let bri = (0.25 + intensity * 0.85).min(1.0) as f32;
                let rgb = hsb_to_rgb(base_hue, sat, bri);
                let a = ((intensity * 1.15).min(1.0) * 255.0) as u8;
                Some([rgb[0], rgb[1], rgb[2], a])
            }
            AgentAnimationStyle::Lightning => {
                if corner_mask <= 0.2 {
                    return None;
                }
                let main_y = self.lightning_main[col];
                let fork_y = self.lightning_fork[col];
                let d_main = (row as i32 - main_y).unsigned_abs() as i32;
                let d_fork = (row as i32 - fork_y).unsigned_abs() as i32;
                let surge = if self.steps % 14 <= 1 { 1.25 } else { 1.0 };
                if d_main == 0 {
                    let rgb = hsb_to_rgb(0.54, 0.18, 1.0);
                    return Some([rgb[0], rgb[1], rgb[2], 255]);
                } else if d_main == 1 {
                    let rgb = hsb_to_rgb(0.57, 0.82, (0.92 * surge as f32).min(1.0));
                    return Some([rgb[0], rgb[1], rgb[2], 235]);
                } else if d_fork == 0 && col % 2 == 0 {
                    let rgb = hsb_to_rgb(0.77, 0.75, 0.95);
                    return Some([rgb[0], rgb[1], rgb[2], 217]);
                } else if d_main == 2 || (d_fork == 1 && col % 3 == 0) {
                    let rgb = hsb_to_rgb(0.62, 0.92, 0.65);
                    return Some([rgb[0], rgb[1], rgb[2], 140]);
                }
                let spark_hash = (col * 37 + row * 101 + self.steps * 29) % 197;
                if spark_hash == 0 && row >= 3 {
                    let rgb = hsb_to_rgb(0.55, 0.3, 1.0);
                    return Some([rgb[0], rgb[1], rgb[2], 230]);
                }
                None
            }
            AgentAnimationStyle::Plasma => {
                let t = self.steps as f64 * 0.13;
                let nx = col as f64 / Self::COLS as f64 * 6.5;
                let ny = row as f64 / d_rows as f64 * 3.2;
                let w1 = (nx + t).sin();
                let w2 = (ny * 1.6 - t * 0.85 + (nx * 0.75 + t * 0.55).sin()).sin();
                let w3 = ((nx + ny) * 0.85 + t * 1.15).sin();
                let v = (w1 + w2 + w3) / 3.0;
                let norm = v * 0.5 + 0.5;
                let v_env =
                    ((row + 1) as f64 / d_rows as f64).powf(0.45) * corner_mask;
                if v_env <= 0.1 {
                    return None;
                }
                let hue =
                    (0.52 + norm * 0.42 + self.steps as f64 * 0.003).rem_euclid(1.0) as f32;
                let sat = (0.75 + 0.22 * (norm * std::f64::consts::PI).sin()) as f32;
                let bri = ((0.38 + 0.62 * norm) * v_env) as f32;
                let rgb = hsb_to_rgb(hue, sat, bri.clamp(0.0, 1.0));
                let a = ((v_env * 1.1).min(1.0) * 255.0) as u8;
                Some([rgb[0], rgb[1], rgb[2], a])
            }
            AgentAnimationStyle::Matrix => {
                let glitch_active = self.steps % 9 < 2;
                let glitch_col_start = (self.steps * 43) % (Self::COLS - 24);
                let glitch_row = (self.steps * 7) % (d_rows.saturating_sub(3).max(1)) + 2;
                if glitch_active
                    && (row == glitch_row || row == glitch_row + 1)
                    && col >= glitch_col_start
                    && col < glitch_col_start + 24
                {
                    let is_cyan = (self.steps + col) % 2 == 0;
                    let rgb = hsb_to_rgb(if is_cyan { 0.52 } else { 0.86 }, 0.85, 1.0);
                    return Some([rgb[0], rgb[1], rgb[2], 242]);
                }
                let speed = 0.48 + ((col * 73 + 19) % 9) as f64 * 0.075;
                let phase = ((col * 131 + 11) % 89) as f64;
                let cycle = (d_rows + 7) as f64;
                let head = (self.steps as f64 * speed + phase).rem_euclid(cycle) - 1.0;
                let dist = head - row as f64;
                if !(0.0..7.5).contains(&dist) {
                    return None;
                }
                if dist < 1.15 {
                    let rgb = hsb_to_rgb(0.36, 0.22, 1.0);
                    return Some([rgb[0], rgb[1], rgb[2], (corner_mask * 255.0) as u8]);
                }
                if (row + col + self.steps / 2) % 5 == 0 {
                    return None;
                }
                let fade = (1.0 - dist / 7.5).max(0.0) * corner_mask;
                let hue = 0.36 + if col % 4 == 0 { 0.08 } else { 0.0 };
                let rgb = hsb_to_rgb(hue as f32, 0.92, (0.28 + 0.68 * fade) as f32);
                Some([rgb[0], rgb[1], rgb[2], (fade * 255.0) as u8])
            }
            AgentAnimationStyle::Rave => {
                let t = self.steps as f64 * 0.18;
                let wave1 = (col as f64 * 0.16 - t * 1.8).sin();
                let wave2 = (col as f64 * 0.09 + t * 1.3).cos();
                let wave3 = (col as f64 * 0.31 + t * 2.4).sin();
                let height_frac =
                    0.38 + 0.56 * ((wave1 * 0.45 + wave2 * 0.35 + wave3 * 0.20) * 0.5 + 0.5);
                let top_row = (d_rows as f64 * (1.0 - height_frac)) as usize;
                if row < top_row {
                    let sparkle = (col * 53 + row * 97 + self.steps * 41) % 173;
                    if sparkle == 0 {
                        let s_hue = (col as f64 / Self::COLS as f64 + t * 0.1).rem_euclid(1.0) as f32;
                        let rgb = hsb_to_rgb(s_hue, 0.35, 1.0);
                        return Some([rgb[0], rgb[1], rgb[2], 242]);
                    }
                    return None;
                }
                let hue = ((col as f64 / Self::COLS as f64) * 1.35
                    - self.steps as f64 * 0.032
                    + row as f64 * 0.02
                    + 10.0)
                    .rem_euclid(1.0) as f32;
                let is_tip = row == top_row;
                let v_bri = 0.55
                    + 0.45 * ((row - top_row + 1) as f64 / (d_rows - top_row).max(1) as f64);
                let rgb = hsb_to_rgb(
                    hue,
                    if is_tip { 0.30 } else { 0.92 },
                    if is_tip { 1.0 } else { v_bri as f32 },
                );
                Some([rgb[0], rgb[1], rgb[2], (corner_mask * 255.0) as u8])
            }
            AgentAnimationStyle::Warp => {
                let center = Self::COLS as f64 / 2.0;
                let dist_from_center = (col as f64 - center).abs();
                if dist_from_center < 3.5 && row >= d_rows / 3 {
                    let core = (1.0 - dist_from_center / 3.5) * 0.75;
                    let rgb = hsb_to_rgb(0.58, 0.45, 1.0);
                    return Some([rgb[0], rgb[1], rgb[2], (core * 255.0) as u8]);
                }
                let dir = if col < Self::COLS / 2 { -1 } else { 1 };
                for lane in 0..3 {
                    let seed = row * 31 + lane * 67 + if dir > 0 { 13 } else { 29 };
                    let period = 22.0 + (seed % 11) as f64;
                    let age = (self.steps as f64 + (seed % 29) as f64 * 1.7).rem_euclid(period)
                        / period;
                    let star_dist = age.powi(2) * (center - 1.0);
                    let tail_len = (age * 14.0).max(1.5);
                    if dist_from_center <= star_dist && dist_from_center >= star_dist - tail_len {
                        let pos_in_streak = 1.0 - (star_dist - dist_from_center) / tail_len;
                        let hue = (0.54 + (seed % 7) as f64 * 0.045
                            - (1.0 - pos_in_streak) * 0.08)
                            .rem_euclid(1.0);
                        let is_head = pos_in_streak > 0.82;
                        let rgb = hsb_to_rgb(
                            (hue as f32 + 1.0).rem_euclid(1.0),
                            if is_head { 0.20 } else { 0.82 },
                            (0.35 + 0.65 * pos_in_streak) as f32,
                        );
                        return Some([
                            rgb[0],
                            rgb[1],
                            rgb[2],
                            (pos_in_streak * corner_mask * 255.0) as u8,
                        ]);
                    }
                }
                None
            }
            AgentAnimationStyle::RandomBullshit => None,
        }
    }

    /// Premultiplied RGBA (matches macOS `Fire.image` bitmap) for softer edges.
    pub fn render_rgba(&self, style: AgentAnimationStyle, buf: &mut [u8; Self::COLS * Self::DRAW_ROWS * 4]) {
        for row in 0..Self::DRAW_ROWS {
            for col in 0..Self::COLS {
                let i = (row * Self::COLS + col) * 4;
                if let Some([r, g, b, a]) = self.color(row, col, style) {
                    let af = a as u16;
                    buf[i] = ((r as u16 * af) / 255) as u8;
                    buf[i + 1] = ((g as u16 * af) / 255) as u8;
                    buf[i + 2] = ((b as u16 * af) / 255) as u8;
                    buf[i + 3] = a;
                } else {
                    buf[i..i + 4].copy_from_slice(&[0, 0, 0, 0]);
                }
            }
        }
    }
}

impl Default for Fire {
    fn default() -> Self {
        Self::new()
    }
}

fn hsb_to_rgb(h: f32, s: f32, b: f32) -> [u8; 3] {
    let h = h.rem_euclid(1.0);
    let s = s.clamp(0.0, 1.0);
    let v = b.clamp(0.0, 1.0);
    let i = (h * 6.0).floor();
    let f = h * 6.0 - i;
    let p = v * (1.0 - s);
    let q = v * (1.0 - f * s);
    let t = v * (1.0 - (1.0 - f) * s);
    let (r, g, bl) = match (i as i32) % 6 {
        0 => (v, t, p),
        1 => (q, v, p),
        2 => (p, v, t),
        3 => (p, q, v),
        4 => (t, p, v),
        _ => (v, p, q),
    };
    [(r * 255.0) as u8, (g * 255.0) as u8, (bl * 255.0) as u8]
}

// Tiny LCG so we don't need an extra crate for fire randomness.
fn fastrand_u32() -> u32 {
    use std::cell::Cell;
    thread_local! {
        static STATE: Cell<u64> = Cell::new(0x4d595df4d0f33173);
    }
    STATE.with(|s| {
        let mut x = s.get();
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        s.set(x);
        x as u32
    })
}

fn fastrand_f32() -> f32 {
    (fastrand_u32() as f32) / (u32::MAX as f32)
}

fn fastrand_f64(lo: f64, hi: f64) -> f64 {
    lo + (hi - lo) * (fastrand_u32() as f64 / u32::MAX as f64)
}

fn fastrand_i32(lo: i32, hi: i32) -> i32 {
    if hi <= lo {
        return lo;
    }
    lo + (fastrand_u32() as i32).rem_euclid(hi - lo + 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fire_renders_non_transparent_pixels_for_all_styles() {
        let mut fire = Fire::new();
        for _ in 0..25 {
            fire.step();
        }
        let mut buf = [0u8; Fire::COLS * Fire::DRAW_ROWS * 4];
        for style in AgentAnimationStyle::ALL {
            if style == AgentAnimationStyle::RandomBullshit {
                // resolved to another style; still should paint
            }
            fire.render_rgba(style, &mut buf);
            let non_zero_alpha = buf.chunks_exact(4).filter(|px| px[3] > 0).count();
            assert!(
                non_zero_alpha > 20,
                "style {:?} produced blank buffer ({non_zero_alpha} px)",
                style
            );
        }
    }
}
