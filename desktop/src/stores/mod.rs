pub mod agents;
pub mod battery;
pub mod hud;
pub mod now_playing;

use std::time::Duration;
use tokio::sync::watch;

/// Music / battery / HUD feeds. `demo` returns static fixtures.
pub fn spawn_live(
    ctx: &egui::Context,
    demo: bool,
) -> (
    watch::Receiver<now_playing::NowPlayingSnapshot>,
    watch::Receiver<battery::BatterySnapshot>,
    watch::Receiver<hud::HudSnapshot>,
) {
    if demo {
        return (
            fixed(now_playing::NowPlayingSnapshot::demo()),
            fixed(battery::BatterySnapshot::demo()),
            fixed(hud::HudSnapshot::default()),
        );
    }
    (
        now_playing::spawn(ctx.clone()),
        battery::spawn(ctx.clone()),
        hud::spawn(ctx.clone()),
    )
}

/// A receiver whose value never changes (sender leaked so `changed()` never errors).
pub fn fixed<T: Send + Sync + 'static>(v: T) -> watch::Receiver<T> {
    let (tx, rx) = watch::channel(v);
    std::mem::forget(tx);
    rx
}

/// Run `poll` on a worker thread every `every`, publishing changed values and waking egui.
/// Stops when the receiver side is dropped.
pub fn spawn_poller<T, F>(
    ctx: egui::Context,
    name: &str,
    every: Duration,
    init: T,
    mut poll: F,
) -> watch::Receiver<T>
where
    T: PartialEq + Send + Sync + 'static,
    F: FnMut() -> Option<T> + Send + 'static,
{
    let (tx, rx) = watch::channel(init);
    let _ = std::thread::Builder::new()
        .name(name.to_string())
        .spawn(move || loop {
            if let Some(next) = poll() {
                let changed = tx.send_if_modified(|cur| {
                    if *cur != next {
                        *cur = next;
                        true
                    } else {
                        false
                    }
                });
                if changed {
                    ctx.request_repaint();
                }
            }
            if tx.is_closed() {
                break;
            }
            std::thread::sleep(every);
        });
    rx
}
