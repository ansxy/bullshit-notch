//! X11 / XWayland click-through overlay.
//!
//! // ponytail: Wayland cannot position globally or report global cursor.
//! Force winit X11 backend and set XShape **input** region to the notch hit rect.
//! Native Wayland layer-shell is the upgrade path.
//!
//! While the notch is open we expand the input region to the **full window** so the
//! event loop still receives mouse-leave. Shaping only the pill while open leaves a
//! stale egui hover_pos and the panel sticks forever.

use egui::{Pos2, Rect};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};

/// Physical-pixel cursor via `XQueryPointer`.
pub fn global_cursor_screen_pos() -> Option<Pos2> {
    #[cfg(target_os = "linux")]
    {
        use x11rb::connection::Connection;
        use x11rb::protocol::xproto::ConnectionExt;
        let (conn, screen_num) = connect().ok()?;
        let root = conn.setup().roots[screen_num].root;
        let reply = conn.query_pointer(root).ok()?.reply().ok()?;
        return Some(Pos2::new(reply.root_x as f32, reply.root_y as f32));
    }
    #[cfg(not(target_os = "linux"))]
    {
        None
    }
}

/// Cursor over shape using window-local coords from `query_pointer(window)`.
pub fn is_cursor_over_shape(shape_logical: Rect, scale: f32) -> Option<bool> {
    #[cfg(target_os = "linux")]
    {
        use x11rb::protocol::xproto::ConnectionExt;

        let xid = LAST_XID.with(|c| c.get())?;
        if !shape_logical.is_finite()
            || shape_logical.width() <= 0.0
            || shape_logical.height() <= 0.0
        {
            return Some(false);
        }

        let (conn, _) = connect().ok()?;
        let reply = conn.query_pointer(xid).ok()?.reply().ok()?;
        if !reply.same_screen {
            return Some(false);
        }
        let local_x = reply.win_x as f32;
        let local_y = reply.win_y as f32;

        let hit = shape_logical.expand(4.0);
        let x0 = hit.min.x * scale;
        let y0 = hit.min.y * scale;
        let x1 = hit.max.x * scale;
        let y1 = hit.max.y * scale;
        return Some(local_x >= x0 && local_x < x1 && local_y >= y0 && local_y < y1);
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (shape_logical, scale);
        None
    }
}

#[derive(Default)]
pub struct OverlayWindowController {
    configured: bool,
    last_hit: Option<(i16, i16, u16, u16)>,
}

impl OverlayWindowController {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configure(&mut self, frame: &eframe::Frame) {
        #[cfg(target_os = "linux")]
        {
            if let Some(xid) = xwindow_from_frame(frame) {
                if let Err(e) = apply_dock_hints(xid) {
                    eprintln!("x11 dock hints: {e}");
                }
                self.configured = true;
            } else {
                eprintln!("x11: no Xlib/Xcb window handle — is WINIT_UNIX_BACKEND=x11 set?");
            }
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = frame;
            self.configured = true;
        }
    }

    /// `capture_full_window`: while open, take input on the whole client area so leave works.
    pub fn set_hit_rect(
        &mut self,
        shape_rect_logical: Rect,
        scale_factor: f32,
        capture_full_window: bool,
        window_size_logical: egui::Vec2,
    ) {
        #[cfg(target_os = "linux")]
        {
            let (x, y, w, h) = if capture_full_window {
                (
                    0_i16,
                    0_i16,
                    (window_size_logical.x * scale_factor).round().max(1.0) as u16,
                    (window_size_logical.y * scale_factor).round().max(1.0) as u16,
                )
            } else {
                let hit = shape_rect_logical.expand(4.0);
                (
                    (hit.min.x * scale_factor).round() as i16,
                    (hit.min.y * scale_factor).round() as i16,
                    (hit.width() * scale_factor).round().max(1.0) as u16,
                    (hit.height() * scale_factor).round().max(1.0) as u16,
                )
            };
            let key = (x, y, w, h);
            if self.last_hit == Some(key) {
                return;
            }
            if let Some(xid) = LAST_XID.with(|c| c.get()) {
                if let Err(e) = set_input_shape(xid, x, y, w, h) {
                    eprintln!("x11 shape: {e}");
                } else {
                    self.last_hit = Some(key);
                }
            }
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = (
                shape_rect_logical,
                scale_factor,
                capture_full_window,
                window_size_logical,
            );
        }
    }

    pub fn configured(&self) -> bool {
        self.configured
    }
}

#[cfg(target_os = "linux")]
thread_local! {
    static LAST_XID: std::cell::Cell<Option<u32>> = const { std::cell::Cell::new(None) };
}

#[cfg(target_os = "linux")]
fn xwindow_from_frame(frame: &eframe::Frame) -> Option<u32> {
    let handle = frame.window_handle().ok()?;
    match handle.as_raw() {
        RawWindowHandle::Xlib(h) => {
            let xid = h.window as u32;
            LAST_XID.with(|c| c.set(Some(xid)));
            Some(xid)
        }
        RawWindowHandle::Xcb(h) => {
            let xid = h.window.get();
            LAST_XID.with(|c| c.set(Some(xid)));
            Some(xid)
        }
        other => {
            eprintln!("x11: unexpected window handle {other:?}");
            None
        }
    }
}

#[cfg(target_os = "linux")]
fn connect() -> Result<(x11rb::rust_connection::RustConnection, usize), String> {
    x11rb::connect(None).map_err(|e| e.to_string())
}

#[cfg(target_os = "linux")]
fn apply_dock_hints(xid: u32) -> Result<(), String> {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{AtomEnum, PropMode};
    use x11rb::wrapper::ConnectionExt;

    let (conn, screen_num) = connect()?;
    let _screen = &conn.setup().roots[screen_num];
    let win = xid;

    let type_atom = intern(&conn, "_NET_WM_WINDOW_TYPE")?;
    let dock_atom = intern(&conn, "_NET_WM_WINDOW_TYPE_DOCK")?;
    conn.change_property32(
        PropMode::REPLACE,
        win,
        type_atom,
        AtomEnum::ATOM,
        &[dock_atom],
    )
    .map_err(|e| e.to_string())?;

    let state_atom = intern(&conn, "_NET_WM_STATE")?;
    let above = intern(&conn, "_NET_WM_STATE_ABOVE")?;
    let skip = intern(&conn, "_NET_WM_STATE_SKIP_TASKBAR")?;
    conn.change_property32(
        PropMode::REPLACE,
        win,
        state_atom,
        AtomEnum::ATOM,
        &[above, skip],
    )
    .map_err(|e| e.to_string())?;

    conn.flush().map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(target_os = "linux")]
fn set_input_shape(xid: u32, x: i16, y: i16, w: u16, h: u16) -> Result<(), String> {
    use x11rb::connection::Connection;
    use x11rb::protocol::shape::{self, ConnectionExt as _, SK};
    use x11rb::protocol::xproto::{ClipOrdering, Rectangle};

    let (conn, _) = connect()?;
    let rect = Rectangle {
        x,
        y,
        width: w,
        height: h,
    };
    conn.shape_rectangles(
        shape::SO::SET,
        SK::INPUT,
        ClipOrdering::UNSORTED,
        xid,
        0,
        0,
        &[rect],
    )
    .map_err(|e| e.to_string())?;
    conn.flush().map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(target_os = "linux")]
fn intern(conn: &x11rb::rust_connection::RustConnection, name: &str) -> Result<u32, String> {
    use x11rb::protocol::xproto::ConnectionExt;
    let cookie = conn
        .intern_atom(false, name.as_bytes())
        .map_err(|e| e.to_string())?;
    Ok(cookie.reply().map_err(|e| e.to_string())?.atom)
}
