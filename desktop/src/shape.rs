use egui::{Pos2, Rect, Vec2};

/// Flared meniscus notch silhouette matching macOS `NotchShape` in Sources/Notch.swift.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NotchShape {
    pub flare: f32,
    pub flare_depth: f32,
    pub bottom: f32,
    pub bulge: f32,
}

impl NotchShape {
    pub fn collapsed() -> Self {
        Self {
            flare: 8.0,
            flare_depth: 8.0,
            bottom: 10.0,
            bulge: 0.0,
        }
    }

    pub fn expanded() -> Self {
        Self {
            flare: 24.0,
            flare_depth: 26.0,
            bottom: 26.0,
            bulge: 0.0,
        }
    }

    pub fn lerp(a: Self, b: Self, t: f32) -> Self {
        let t = t.clamp(0.0, 1.0);
        Self {
            flare: a.flare + (b.flare - a.flare) * t,
            flare_depth: a.flare_depth + (b.flare_depth - a.flare_depth) * t,
            bottom: a.bottom + (b.bottom - a.bottom) * t,
            bulge: a.bulge + (b.bulge - a.bulge) * t,
        }
    }

    /// Sample the cubic-Bezier outline clockwise from top-left bezel to top-right.
    pub fn sample_points(&self, rect: Rect, segments_per_curve: usize) -> Vec<Pos2> {
        let segs = segments_per_curve.max(2);
        let left = rect.min.x + self.flare;
        let right = rect.max.x - self.flare;
        let depth = self.flare_depth.min(rect.height() / 2.0);
        let radius = self
            .bottom
            .min((rect.height() - depth) / 2.0)
            .min((right - left) / 2.0);
        let mid_y = (rect.min.y + depth + rect.max.y - radius) / 2.0;

        let mut pts = Vec::with_capacity(segs * 6 + 8);
        pts.push(pos(rect.min.x, rect.min.y));

        // Left meniscus
        append_cubic(
            &mut pts,
            pos(rect.min.x, rect.min.y),
            pos(left - self.flare * 0.45, rect.min.y),
            pos(left, rect.min.y + depth * 0.45),
            pos(left, rect.min.y + depth),
            segs,
        );

        // Left side
        if self.bulge != 0.0 {
            append_quad(
                &mut pts,
                pos(left, rect.min.y + depth),
                pos(left - self.bulge * 2.0, mid_y),
                pos(left, rect.max.y - radius),
                segs,
            );
        } else {
            append_line(
                &mut pts,
                pos(left, rect.min.y + depth),
                pos(left, rect.max.y - radius),
                segs,
            );
        }

        // Bottom-left squircle
        append_cubic(
            &mut pts,
            pos(left, rect.max.y - radius),
            pos(left, rect.max.y - radius * 0.45),
            pos(left + radius * 0.45, rect.max.y),
            pos(left + radius, rect.max.y),
            segs,
        );

        pts.push(pos(right - radius, rect.max.y));

        // Bottom-right squircle
        append_cubic(
            &mut pts,
            pos(right - radius, rect.max.y),
            pos(right - radius * 0.45, rect.max.y),
            pos(right, rect.max.y - radius * 0.45),
            pos(right, rect.max.y - radius),
            segs,
        );

        // Right side
        if self.bulge != 0.0 {
            append_quad(
                &mut pts,
                pos(right, rect.max.y - radius),
                pos(right + self.bulge * 2.0, mid_y),
                pos(right, rect.min.y + depth),
                segs,
            );
        } else {
            append_line(
                &mut pts,
                pos(right, rect.max.y - radius),
                pos(right, rect.min.y + depth),
                segs,
            );
        }

        // Right meniscus
        append_cubic(
            &mut pts,
            pos(right, rect.min.y + depth),
            pos(right, rect.min.y + depth * 0.45),
            pos(right + self.flare * 0.45, rect.min.y),
            pos(rect.max.x, rect.min.y),
            segs,
        );

        pts
    }
}

fn pos(x: f32, y: f32) -> Pos2 {
    Pos2::new(x, y)
}

fn append_cubic(out: &mut Vec<Pos2>, p0: Pos2, c1: Pos2, c2: Pos2, p3: Pos2, segs: usize) {
    for i in 1..=segs {
        let t = i as f32 / segs as f32;
        out.push(cubic(p0, c1, c2, p3, t));
    }
}

fn append_line(out: &mut Vec<Pos2>, p0: Pos2, p1: Pos2, segs: usize) {
    for i in 1..=segs {
        let t = i as f32 / segs as f32;
        out.push(Pos2::new(
            p0.x + (p1.x - p0.x) * t,
            p0.y + (p1.y - p0.y) * t,
        ));
    }
}

fn append_quad(out: &mut Vec<Pos2>, p0: Pos2, c: Pos2, p2: Pos2, segs: usize) {
    for i in 1..=segs {
        let t = i as f32 / segs as f32;
        let u = 1.0 - t;
        out.push(Pos2::new(
            u * u * p0.x + 2.0 * u * t * c.x + t * t * p2.x,
            u * u * p0.y + 2.0 * u * t * c.y + t * t * p2.y,
        ));
    }
}

fn cubic(p0: Pos2, c1: Pos2, c2: Pos2, p3: Pos2, t: f32) -> Pos2 {
    let u = 1.0 - t;
    let uu = u * u;
    let tt = t * t;
    let uuu = uu * u;
    let ttt = tt * t;
    Pos2::new(
        uuu * p0.x + 3.0 * uu * t * c1.x + 3.0 * u * tt * c2.x + ttt * p3.x,
        uuu * p0.y + 3.0 * uu * t * c1.y + 3.0 * u * tt * c2.y + ttt * p3.y,
    )
}

/// Second-order spring (underdamped harmonic oscillator).
#[derive(Debug, Clone, Copy)]
pub struct Spring {
    pub pos: f32,
    pub vel: f32,
    pub target: f32,
}

impl Spring {
    pub fn new(target: f32) -> Self {
        Self {
            pos: target,
            vel: 0.0,
            target,
        }
    }

    /// Returns `true` while still moving.
    pub fn step(&mut self, dt: f32, response: f32, damping_fraction: f32) -> bool {
        let response = response.max(0.001);
        let omega = std::f32::consts::TAU / response;
        let zeta = damping_fraction;
        // Semi-implicit Euler for ÿ + 2ζωẏ + ω²(y − target) = 0
        let accel = -2.0 * zeta * omega * self.vel - omega * omega * (self.pos - self.target);
        self.vel += accel * dt;
        self.pos += self.vel * dt;
        // Snap early — residual underdamped energy was rare large↔small flicker.
        if (self.pos - self.target).abs() < 0.04 && self.vel.abs() < 0.55 {
            self.pos = self.target;
            self.vel = 0.0;
        }
        self.pos = self.pos.clamp(0.0, 1.0);
        if self.pos == 0.0 || self.pos == 1.0 {
            if (self.pos == 0.0 && self.vel < 0.0) || (self.pos == 1.0 && self.vel > 0.0) {
                self.vel = 0.0;
            }
        }
        self.vel.abs() >= 0.04 || (self.target - self.pos).abs() >= 0.015
    }
}

#[allow(dead_code)]
fn _vec2(x: f32, y: f32) -> Vec2 {
    Vec2::new(x, y)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notch_shape_starts_and_ends_on_top_bezel() {
        let shape = NotchShape::expanded();
        let rect = Rect::from_min_size(Pos2::new(30.0, 0.0), Vec2::new(620.0, 340.0));
        let pts = shape.sample_points(rect, 12);
        assert!((pts.first().unwrap().y - 0.0).abs() < 1e-4);
        assert!((pts.last().unwrap().y - 0.0).abs() < 1e-4);
        assert!(pts.iter().all(|p| p.y >= 0.0 && p.y <= 340.001));
        let mid_left = pts
            .iter()
            .find(|p| (p.y - 170.0).abs() < 20.0 && p.x < 340.0)
            .unwrap();
        assert!((mid_left.x - (rect.min.x + 24.0)).abs() < 1.0);
    }

    #[test]
    fn spring_opens_and_settles_without_chatter() {
        let mut s = Spring {
            pos: 0.0,
            vel: 0.0,
            target: 1.0,
        };
        for _ in 0..120 {
            s.step(1.0 / 60.0, 0.45, 0.78);
        }
        assert!((s.pos - 1.0).abs() < 0.01);
        assert!(s.vel.abs() < 0.05);
    }

    #[test]
    fn spring_closes_and_stays_shut() {
        let mut s = Spring {
            pos: 1.0,
            vel: 0.0,
            target: 0.0,
        };
        let mut reopened = false;
        for i in 0..180 {
            s.step(1.0 / 60.0, 0.45, 0.78);
            if i > 60 && s.pos > 0.08 {
                reopened = true;
            }
        }
        assert!(!reopened, "close must not bounce back open, pos={}", s.pos);
        assert!(s.pos < 0.02);
        assert!(s.vel.abs() < 0.05);
    }
}
