pub mod agents;
pub mod agenda;
pub mod antigravity;
pub mod battery;
pub mod commandcode;
pub mod containers;
pub mod cursor;
pub mod github;
pub mod hud;
pub mod now_playing;
pub mod shelf;
pub mod usage;
pub mod work;

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

/// Build a poll fn on a worker thread (`make` runs there, so COM/D-Bus handles need not be
/// `Send`), then run it every `every`, publishing changed values and waking egui.
/// Stops when the receiver side is dropped.
pub fn spawn_poller<T, M, F>(
    ctx: egui::Context,
    name: &str,
    every: Duration,
    init: T,
    make: M,
) -> watch::Receiver<T>
where
    T: PartialEq + Send + Sync + 'static,
    M: FnOnce() -> F + Send + 'static,
    F: FnMut() -> Option<T>,
{
    let (tx, rx) = watch::channel(init);
    let _ = std::thread::Builder::new()
        .name(name.to_string())
        .spawn(move || {
            let mut poll = make();
            loop {
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
            }
        });
    rx
}
