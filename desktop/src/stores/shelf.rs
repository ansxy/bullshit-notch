//! Dropped-file shelf (port of `Sources/Shelf.swift`). Paths persist; files are not copied.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use tokio::sync::watch;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShelfItem {
    pub path: PathBuf,
    pub name: String,
}

impl ShelfItem {
    pub fn from_path(path: PathBuf) -> Self {
        let name = path.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| path.display().to_string());
        Self { path, name }
    }

    pub fn exists(&self) -> bool {
        self.path.exists()
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct ShelfSnapshot {
    pub items: Vec<ShelfItem>,
}

impl ShelfSnapshot {
    pub fn demo() -> Self {
        Self {
            items: vec![
                ShelfItem { path: PathBuf::from("/tmp/demo-notes.md"), name: "demo-notes.md".into() },
                ShelfItem { path: PathBuf::from("/tmp/sprint.pdf"), name: "sprint.pdf".into() },
            ],
        }
    }
}

fn persist_path() -> Option<PathBuf> {
    directories::ProjectDirs::from("com", "ansxy", "BullshitNotch").map(|d| d.data_dir().join("shelf.json"))
}

pub fn load() -> ShelfSnapshot {
    let Some(path) = persist_path() else {
        return ShelfSnapshot::default();
    };
    let Ok(raw) = fs::read_to_string(path) else {
        return ShelfSnapshot::default();
    };
    let paths: Vec<PathBuf> = serde_json::from_str(&raw).unwrap_or_default();
    ShelfSnapshot {
        items: paths.into_iter().map(ShelfItem::from_path).filter(|i| i.exists()).collect(),
    }
}

fn save(items: &[ShelfItem]) {
    let Some(path) = persist_path() else { return };
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let paths: Vec<&Path> = items.iter().map(|i| i.path.as_path()).collect();
    if let Ok(json) = serde_json::to_string_pretty(&paths) {
        let _ = fs::write(path, json);
    }
}

static TX: OnceLock<Mutex<watch::Sender<ShelfSnapshot>>> = OnceLock::new();

pub fn spawn(demo: bool) -> watch::Receiver<ShelfSnapshot> {
    let snap = if demo { ShelfSnapshot::demo() } else { load() };
    let (tx, rx) = watch::channel(snap);
    let _ = TX.set(Mutex::new(tx));
    rx
}

fn publish(f: impl FnOnce(&mut Vec<ShelfItem>)) {
    let Some(tx) = TX.get() else { return };
    let Ok(tx) = tx.lock() else { return };
    let _ = tx.send_if_modified(|snap| {
        f(&mut snap.items);
        save(&snap.items);
        true
    });
}

pub fn add(paths: impl IntoIterator<Item = PathBuf>) {
    let incoming: Vec<PathBuf> = paths.into_iter().collect();
    publish(|items| {
        for p in incoming {
            if !items.iter().any(|i| i.path == p) {
                items.push(ShelfItem::from_path(p));
            }
        }
    });
}

pub fn remove(path: &Path) {
    publish(|items| items.retain(|i| i.path != path));
}

pub fn clear() {
    publish(|items| items.clear());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn item_name_from_path() {
        let i = ShelfItem::from_path(PathBuf::from("/tmp/foo/bar.txt"));
        assert_eq!(i.name, "bar.txt");
    }
}
