pub mod http;
pub mod process;
pub mod tray;

#[cfg(windows)]
pub mod win32;

#[cfg(target_os = "linux")]
pub mod x11;

use egui::{Pos2, Rect};

/// Cursor is inside the notch hit area when in `shape_rect.expand(4.0)` in window space.
pub fn is_cursor_inside_shape(
    cursor_logical: Pos2,
    win_origin_logical: Pos2,
    shape_rect_logical: Rect,
) -> bool {
    let local = cursor_logical - win_origin_logical.to_vec2();
    shape_rect_logical.expand(4.0).contains(local)
}

/// Global screen-space cursor in **physical** pixels (OS coords).
pub fn global_cursor_screen_pos() -> Option<Pos2> {
    #[cfg(windows)]
    {
        return win32::global_cursor_screen_pos();
    }
    #[cfg(target_os = "linux")]
    {
        return x11::global_cursor_screen_pos();
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        None
    }
}

/// Best-effort "is cursor over the notch shape?" for open/close.
/// Linux uses X11 window-local geometry (reliable). Elsewhere falls back to egui coords.
pub fn is_hovering_shape(shape_rect_logical: Rect, scale: f32, win_origin_logical: Pos2) -> bool {
    #[cfg(target_os = "linux")]
    {
        if let Some(v) = x11::is_cursor_over_shape(shape_rect_logical, scale) {
            return v;
        }
    }
    if let Some(screen_px) = global_cursor_screen_pos() {
        let logical = Pos2::new(screen_px.x / scale, screen_px.y / scale);
        return is_cursor_inside_shape(logical, win_origin_logical, shape_rect_logical);
    }
    false
}

/// Cross-platform overlay facade used by the app each frame.
pub struct Overlay {
    #[cfg(windows)]
    inner: win32::OverlayWindowController,
    #[cfg(target_os = "linux")]
    inner: x11::OverlayWindowController,
    #[cfg(not(any(windows, target_os = "linux")))]
    _pad: (),
}

impl Overlay {
    pub fn new() -> Self {
        Self {
            #[cfg(windows)]
            inner: win32::OverlayWindowController::new(),
            #[cfg(target_os = "linux")]
            inner: x11::OverlayWindowController::new(),
            #[cfg(not(any(windows, target_os = "linux")))]
            _pad: (),
        }
    }

    pub fn configure(&mut self, frame: &eframe::Frame) {
        #[cfg(any(windows, target_os = "linux"))]
        self.inner.configure(frame);
        #[cfg(not(any(windows, target_os = "linux")))]
        let _ = frame;
    }

    pub fn set_hit_rect(
        &mut self,
        shape_rect: Rect,
        scale_factor: f32,
        capture_full_window: bool,
        window_size: egui::Vec2,
    ) {
        #[cfg(target_os = "linux")]
        self.inner
            .set_hit_rect(shape_rect, scale_factor, capture_full_window, window_size);
        #[cfg(not(target_os = "linux"))]
        let _ = (shape_rect, scale_factor, capture_full_window, window_size);
    }

    pub fn update_mouse_passthrough(
        &mut self,
        shape_rect: Rect,
        scale_factor: f32,
        window_origin: Pos2,
        wants_keyboard: bool,
    ) -> (bool, bool) {
        #[cfg(windows)]
        {
            return self.inner.update_mouse_passthrough(
                shape_rect,
                scale_factor,
                window_origin,
                wants_keyboard,
            );
        }
        #[cfg(not(windows))]
        {
            // X11 input region handles passthrough; egui pointer drives open/close.
            let _ = (shape_rect, scale_factor, window_origin, wants_keyboard);
            (false, false)
        }
    }
}

impl Default for Overlay {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_hit_test_expands_by_4pt_margin() {
        let shape = Rect::from_min_size(Pos2::new(220.0, 0.0), egui::vec2(240.0, 32.0));
        let win_origin = Pos2::new(620.0, 0.0);
        assert!(is_cursor_inside_shape(
            Pos2::new(840.0, 34.0),
            win_origin,
            shape
        ));
        assert!(!is_cursor_inside_shape(
            Pos2::new(840.0, 40.0),
            win_origin,
            shape
        ));
    }
}
