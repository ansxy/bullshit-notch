#![allow(dead_code)]

mod app;
mod config;
mod fire;
mod platform;
mod shape;
mod stores;
mod ui;

use app::BullshitNotchApp;
use eframe::egui;

fn main() -> eframe::Result<()> {
    let demo = std::env::args().any(|a| a == "--demo");

    // Must be X11/XWayland for XShape click-through + leave detection.
    // ponytail: set before any winit init; Wayland cannot do this overlay properly yet.
    #[cfg(target_os = "linux")]
    {
        if std::env::var_os("WINIT_UNIX_BACKEND").is_none() {
            std::env::set_var("WINIT_UNIX_BACKEND", "x11");
        }
    }

    // Top-of-screen overlay. Exact x recentered once monitor size known (see app).
    let viewport = egui::ViewportBuilder::default()
        .with_decorations(false)
        .with_transparent(true)
        .with_always_on_top()
        .with_inner_size([680.0, 420.0])
        .with_position([0.0, 0.0])
        .with_title("BullshitNotch");

    #[cfg_attr(not(target_os = "linux"), allow(unused_mut))]
    let mut native = eframe::NativeOptions {
        viewport,
        // Must stay false — `centered: true` parks the notch mid-screen.
        centered: false,
        ..Default::default()
    };

    // Force X11 backend on Linux so XShape click-through works under XWayland.
    // ponytail: native Wayland layer-shell is the upgrade path.
    #[cfg(target_os = "linux")]
    {
        use winit::platform::x11::EventLoopBuilderExtX11;
        native.event_loop_builder = Some(Box::new(|b| {
            b.with_x11();
        }));
    }

    eframe::run_native(
        "BullshitNotch",
        native,
        Box::new(move |cc| Ok(Box::new(BullshitNotchApp::new(cc, demo)))),
    )
}
