//! Win32 click-through overlay controller.
//!
//! Sets `WS_EX_LAYERED | TOOLWINDOW | TOPMOST | NOACTIVATE` and toggles
//! `WS_EX_TRANSPARENT` when the cursor leaves `shape_rect.expand(4.0)`.

use egui::{Pos2, Rect};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};

use super::is_cursor_inside_shape;

#[derive(Default)]
pub struct OverlayWindowController {
    configured: bool,
    transparent: bool,
    no_activate: bool,
}

impl OverlayWindowController {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configure(&mut self, frame: &eframe::Frame) {
        #[cfg(windows)]
        {
            if let Some(hwnd) = hwnd_from_frame(frame) {
                unsafe {
                    apply_base_styles(hwnd);
                }
                self.configured = true;
                self.transparent = true;
                self.no_activate = true;
            }
        }
        #[cfg(not(windows))]
        {
            let _ = frame;
            self.configured = true;
        }
    }

    /// Returns `(cursor_inside_shape, left_mouse_dragging)`.
    pub fn update_mouse_passthrough(
        &mut self,
        shape_rect_logical: Rect,
        _scale_factor: f32,
        window_origin_screen: Pos2,
        wants_keyboard: bool,
    ) -> (bool, bool) {
        #[cfg(windows)]
        {
            let (cursor, dragging) = unsafe { cursor_and_drag() };
            let inside = is_cursor_inside_shape(cursor, window_origin_screen, shape_rect_logical);

            if let Some(hwnd) = self.current_hwnd() {
                unsafe {
                    if inside != !self.transparent {
                        // inside => not transparent
                        set_transparent(hwnd, !inside);
                        self.transparent = !inside;
                    }
                    if wants_keyboard == self.no_activate {
                        set_no_activate(hwnd, !wants_keyboard);
                        self.no_activate = !wants_keyboard;
                    }
                }
            }
            return (inside, dragging);
        }

        #[cfg(not(windows))]
        {
            let _ = (shape_rect_logical, window_origin_screen, wants_keyboard);
            (false, false)
        }
    }

    #[cfg(windows)]
    fn current_hwnd(&self) -> Option<windows::Win32::Foundation::HWND> {
        // HWND is held by the window; callers pass frame only to configure.
        // For updates we re-query via a stored pointer would be ideal; for MVP
        // we keep last HWND in thread-local set during configure.
        LAST_HWND.with(|c| c.get())
    }
}

#[cfg(windows)]
thread_local! {
    static LAST_HWND: std::cell::Cell<Option<windows::Win32::Foundation::HWND>> =
        const { std::cell::Cell::new(None) };
}

#[cfg(windows)]
fn hwnd_from_frame(frame: &eframe::Frame) -> Option<windows::Win32::Foundation::HWND> {
    let handle = frame.window_handle().ok()?;
    match handle.as_raw() {
        RawWindowHandle::Win32(h) => {
            let hwnd = windows::Win32::Foundation::HWND(h.hwnd.get() as *mut _);
            LAST_HWND.with(|c| c.set(Some(hwnd)));
            Some(hwnd)
        }
        _ => None,
    }
}

#[cfg(windows)]
unsafe fn apply_base_styles(hwnd: windows::Win32::Foundation::HWND) {
    use windows::Win32::UI::WindowsAndMessaging::*;
    let mut style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    style |= (WS_EX_LAYERED.0
        | WS_EX_TOOLWINDOW.0
        | WS_EX_TOPMOST.0
        | WS_EX_NOACTIVATE.0
        | WS_EX_TRANSPARENT.0) as isize;
    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style);
    let _ = SetWindowPos(
        hwnd,
        HWND_TOPMOST,
        0,
        0,
        0,
        0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED,
    );
}

#[cfg(windows)]
unsafe fn set_transparent(hwnd: windows::Win32::Foundation::HWND, transparent: bool) {
    use windows::Win32::UI::WindowsAndMessaging::*;
    let mut style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if transparent {
        style |= WS_EX_TRANSPARENT.0 as isize;
    } else {
        style &= !(WS_EX_TRANSPARENT.0 as isize);
    }
    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style);
}

#[cfg(windows)]
unsafe fn set_no_activate(hwnd: windows::Win32::Foundation::HWND, no_activate: bool) {
    use windows::Win32::UI::WindowsAndMessaging::*;
    let mut style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if no_activate {
        style |= WS_EX_NOACTIVATE.0 as isize;
    } else {
        style &= !(WS_EX_NOACTIVATE.0 as isize);
    }
    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style);
}

#[cfg(windows)]
unsafe fn cursor_and_drag() -> (Pos2, bool) {
    use windows::Win32::Foundation::POINT;
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
    use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;
    let mut pt = POINT::default();
    let _ = GetCursorPos(&mut pt);
    let dragging = GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16 & 0x8000 != 0;
    (Pos2::new(pt.x as f32, pt.y as f32), dragging)
}

/// Physical-pixel cursor via `GetCursorPos`.
pub fn global_cursor_screen_pos() -> Option<Pos2> {
    #[cfg(windows)]
    {
        use windows::Win32::Foundation::POINT;
        use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;
        unsafe {
            let mut pt = POINT::default();
            GetCursorPos(&mut pt).ok()?;
            return Some(Pos2::new(pt.x as f32, pt.y as f32));
        }
    }
    #[cfg(not(windows))]
    {
        None
    }
}
