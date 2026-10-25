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

    let mut viewport = egui::ViewportBuilder::default()
        .with_decorations(false)
        .with_transparent(true)
        .with_always_on_top()
        .with_inner_size([680.0, 420.0])
        .with_title("BullshitNotch");

    // Position near top-center; exact monitor math refined by WM.
    viewport = viewport.with_position([100.0, 0.0]);

    let mut native = eframe::NativeOptions {
        viewport,
        centered: true,
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
