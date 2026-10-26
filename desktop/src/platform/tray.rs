//! System tray: Settings / Quit.
//! Windows uses `tray-icon`. Linux uses a StatusNotifierItem over zbus so we
//! do not need GTK/glib headers at compile time.

use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::sync::Mutex;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayAction {
    Settings,
    Quit,
}

pub struct TrayHandle {
    rx: Mutex<Receiver<TrayAction>>,
    #[cfg(windows)]
    _icon: Option<tray_icon::TrayIcon>,
}

impl TrayHandle {
    pub fn poll(&self) -> Option<TrayAction> {
        match self.rx.lock().ok()?.try_recv() {
            Ok(a) => Some(a),
            Err(TryRecvError::Empty | TryRecvError::Disconnected) => None,
        }
    }
}

pub fn spawn() -> TrayHandle {
    let (tx, rx) = mpsc::channel();
    #[cfg(windows)]
    {
        let icon = windows::build(tx).ok();
        return TrayHandle { rx: Mutex::new(rx), _icon: icon };
    }
    #[cfg(target_os = "linux")]
    {
        linux::spawn(tx);
        return TrayHandle { rx: Mutex::new(rx) };
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = tx;
        TrayHandle { rx: Mutex::new(rx) }
    }
}

#[cfg(windows)]
mod windows {
    use super::TrayAction;
    use std::sync::mpsc::Sender;
    use std::thread;

    fn notch_icon() -> Option<tray_icon::Icon> {
        const S: u32 = 32;
        let mut rgba = vec![0u8; (S * S * 4) as usize];
        for y in 0..S {
            for x in 0..S {
                let i = ((y * S + x) * 4) as usize;
                let in_pill = (x as i32 - 16).pow(2) / 4 + (y as i32 - 16).pow(2) < 80;
                if in_pill {
                    rgba[i] = 20;
                    rgba[i + 1] = 20;
                    rgba[i + 2] = 22;
                    rgba[i + 3] = 255;
                }
            }
        }
        tray_icon::Icon::from_rgba(rgba, S, S).ok()
    }

    pub fn build(tx: Sender<TrayAction>) -> Result<tray_icon::TrayIcon, String> {
        use tray_icon::menu::{Menu, MenuEvent, MenuItem};
        use tray_icon::TrayIconBuilder;

        let menu = Menu::new();
        let settings = MenuItem::new("Settings", true, None);
        let quit = MenuItem::new("Quit", true, None);
        menu.append(&settings).map_err(|e| e.to_string())?;
        menu.append(&quit).map_err(|e| e.to_string())?;
        let settings_id = settings.id().clone();
        let quit_id = quit.id().clone();
        let icon = notch_icon().ok_or_else(|| "tray icon rgba".to_string())?;
        let tray = TrayIconBuilder::new()
            .with_menu(Box::new(menu))
            .with_tooltip("BullshitNotch")
            .with_icon(icon)
            .build()
            .map_err(|e| e.to_string())?;
        thread::Builder::new()
            .name("tray-menu".into())
            .spawn(move || {
                let recv = MenuEvent::receiver();
                while let Ok(ev) = recv.recv() {
                    if ev.id == settings_id {
                        if tx.send(TrayAction::Settings).is_err() {
                            break;
                        }
                    } else if ev.id == quit_id {
                        let _ = tx.send(TrayAction::Quit);
                        break;
                    }
                }
            })
            .map_err(|e| e.to_string())?;
        Ok(tray)
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use super::TrayAction;
    use std::sync::mpsc::Sender;
    use std::thread;

    struct Item {
        tx: Sender<TrayAction>,
    }

    #[zbus::interface(name = "org.kde.StatusNotifierItem")]
    impl Item {
        fn activate(&self, _x: i32, _y: i32) {
            let _ = self.tx.send(TrayAction::Settings);
        }

        fn secondary_activate(&self, _x: i32, _y: i32) {
            let _ = self.tx.send(TrayAction::Quit);
        }

        fn context_menu(&self, _x: i32, _y: i32) {
            let _ = self.tx.send(TrayAction::Settings);
        }

        #[zbus(property)]
        fn category(&self) -> String {
            "ApplicationStatus".into()
        }

        #[zbus(property)]
        fn id(&self) -> String {
            "bullshit-notch".into()
        }

        #[zbus(property)]
        fn title(&self) -> String {
            "BullshitNotch".into()
        }

        #[zbus(property)]
        fn status(&self) -> String {
            "Active".into()
        }

        #[zbus(property)]
        fn window_id(&self) -> u32 {
            0
        }

        #[zbus(property)]
        fn icon_name(&self) -> String {
            "applications-utilities".into()
        }
    }

    pub fn spawn(tx: Sender<TrayAction>) {
        thread::Builder::new()
            .name("tray-sni".into())
            .spawn(move || {
                let Ok(rt) = tokio::runtime::Builder::new_current_thread().enable_all().build() else {
                    return;
                };
                let _ = rt.block_on(async move {
                    let conn = zbus::ConnectionBuilder::session()?
                        .name("org.kde.StatusNotifierItem.BullshitNotch")?
                        .serve_at("/StatusNotifierItem", Item { tx })?
                        .build()
                        .await?;
                    if conn
                        .call_method(
                            Some("org.kde.StatusNotifierWatcher"),
                            "/StatusNotifierWatcher",
                            Some("org.kde.StatusNotifierWatcher"),
                            "RegisterStatusNotifierItem",
                            &"org.kde.StatusNotifierItem.BullshitNotch",
                        )
                        .await
                        .is_err()
                    {
                        let dest = conn.unique_name().map(|n| n.to_string()).unwrap_or_default();
                        let _ = conn
                            .call_method(
                                Some("org.freedesktop.StatusNotifierWatcher"),
                                "/StatusNotifierWatcher",
                                Some("org.freedesktop.StatusNotifierWatcher"),
                                "RegisterStatusNotifierItem",
                                &dest,
                            )
                            .await;
                    }
                    std::future::pending::<()>().await;
                    Ok::<(), zbus::Error>(())
                });
            })
            .ok();
    }
}
