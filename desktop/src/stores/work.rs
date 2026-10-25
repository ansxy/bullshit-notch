//! Saved projects, service log ring, terminal + agent launch (port of `Sources/Work.swift`).

use crate::config::TerminalApp;
use crate::platform::process::{self, run_hidden_sync};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::watch;

const LOG_RING: usize = 80;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectItem {
    pub id: String,
    pub name: String,
    pub path: String,
    pub service_command: String,
    pub agent_command: String,
}

impl ProjectItem {
    pub fn expanded_path(&self) -> PathBuf {
        expand_tilde(&self.path)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ItemKind {
    Folder,
    Ssh,
    Url,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CustomItem {
    pub id: String,
    pub name: String,
    pub kind: ItemKind,
    pub value: String,
}

impl CustomItem {
    pub fn open_target(&self) -> String {
        match self.kind {
            ItemKind::Folder => expand_tilde(&self.value).display().to_string(),
            ItemKind::Ssh => {
                if self.value.starts_with("ssh://") {
                    self.value.clone()
                } else {
                    format!("ssh://{}", self.value)
                }
            }
            ItemKind::Url => {
                if self.value.contains("://") {
                    self.value.clone()
                } else {
                    format!("https://{}", self.value)
                }
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CustomSection {
    pub id: String,
    pub name: String,
    pub items: Vec<CustomItem>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct WorkSnapshot {
    pub projects: Vec<ProjectItem>,
    pub running: HashMap<String, u32>,
    pub logs: HashMap<String, String>,
    pub last_exit: HashMap<String, i32>,
    pub presets: Vec<String>,
    pub sections: Vec<CustomSection>,
}

impl WorkSnapshot {
    pub fn demo() -> Self {
        Self {
            projects: vec![ProjectItem {
                id: "demo-1".into(),
                name: "bullshit-notch".into(),
                path: "~/Coding/GitHub/bullshit-notch".into(),
                service_command: "cargo run --manifest-path desktop/Cargo.toml -- --demo".into(),
                agent_command: "claude".into(),
            }],
            running: HashMap::new(),
            logs: HashMap::new(),
            last_exit: HashMap::new(),
            presets: default_presets(),
            sections: vec![CustomSection {
                id: "s1".into(),
                name: "Shortcuts".into(),
                items: vec![CustomItem {
                    id: "c1".into(),
                    name: "Repo".into(),
                    kind: ItemKind::Url,
                    value: "https://github.com/ansxy/bullshit-notch".into(),
                }],
            }],
        }
    }
}

fn default_presets() -> Vec<String> {
    vec!["claude".into(), "agy".into(), "codex".into(), "opencode".into(), "aider".into()]
}

fn new_id() -> String {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| format!("{:x}", d.as_nanos())).unwrap_or_else(|_| "id".into())
}

fn expand_tilde(path: &str) -> PathBuf {
    if let Some(rest) = path.strip_prefix("~/") {
        if let Some(home) = directories::UserDirs::new() {
            return home.home_dir().join(rest);
        }
    }
    PathBuf::from(path)
}

fn data_file(name: &str) -> Option<PathBuf> {
    directories::ProjectDirs::from("com", "ansxy", "BullshitNotch").map(|d| d.data_dir().join(name))
}

fn load_json<T: for<'de> Deserialize<'de> + Default>(name: &str) -> T {
    let Some(p) = data_file(name) else { return T::default() };
    fs::read_to_string(p).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
}

fn save_json<T: Serialize>(name: &str, v: &T) {
    let Some(p) = data_file(name) else { return };
    if let Some(dir) = p.parent() {
        let _ = fs::create_dir_all(dir);
    }
    if let Ok(s) = serde_json::to_string_pretty(v) {
        let _ = fs::write(p, s);
    }
}

/// Port of `ProjectStore.detectDefaultServiceCommand`.
pub fn detect_default_service_command(folder: &Path) -> String {
    let pkg = folder.join("package.json");
    if pkg.exists() {
        let runner = if folder.join("pnpm-lock.yaml").exists() {
            "pnpm"
        } else if folder.join("bun.lockb").exists() || folder.join("bun.lock").exists() {
            "bun run"
        } else if folder.join("yarn.lock").exists() {
            "yarn"
        } else {
            "npm run"
        };
        if let Ok(raw) = fs::read_to_string(&pkg) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) {
                let scripts = v.get("scripts");
                if scripts.and_then(|s| s.get("dev")).is_some() {
                    return format!("{runner} dev");
                }
                if scripts.and_then(|s| s.get("start")).is_some() {
                    return if runner == "npm run" { "npm start".into() } else { format!("{runner} start") };
                }
                if scripts.and_then(|s| s.get("serve")).is_some() {
                    return format!("{runner} serve");
                }
            }
        }
        return format!("{runner} dev");
    }
    if folder.join("build.sh").exists() {
        return "./build.sh".into();
    }
    if folder.join("Package.swift").exists() {
        return "swift run".into();
    }
    if folder.join("Cargo.toml").exists() {
        return "cargo run".into();
    }
    if folder.join("go.mod").exists() {
        return "go run .".into();
    }
    if folder.join("docker-compose.yml").exists() || folder.join("compose.yml").exists() {
        return "docker compose up".into();
    }
    if folder.join("manage.py").exists() {
        return "python3 manage.py runserver".into();
    }
    if folder.join("Makefile").exists() {
        return "make".into();
    }
    "npm run dev".into()
}

fn seed_from_work_dir() -> Vec<ProjectItem> {
    let Some(home) = directories::UserDirs::new() else { return vec![] };
    let dir = home.home_dir().join("work");
    let Ok(rd) = fs::read_dir(&dir) else { return vec![] };
    let mut out = Vec::new();
    for e in rd.flatten() {
        let p = e.path();
        if !p.is_dir() {
            continue;
        }
        let name = p.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        out.push(ProjectItem {
            id: new_id(),
            name,
            path: p.display().to_string(),
            service_command: detect_default_service_command(&p),
            agent_command: "claude".into(),
        });
    }
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    out
}

struct Inner {
    snap: WorkSnapshot,
}

static TX: OnceLock<Mutex<watch::Sender<WorkSnapshot>>> = OnceLock::new();
static INNER: OnceLock<Mutex<Inner>> = OnceLock::new();

fn publish() {
    if let (Some(tx), Some(inner)) = (TX.get(), INNER.get()) {
        if let (Ok(tx), Ok(inner)) = (tx.lock(), inner.lock()) {
            let _ = tx.send(inner.snap.clone());
        }
    }
}

fn persist(snap: &WorkSnapshot) {
    save_json("projects.json", &snap.projects);
    save_json("presets.json", &snap.presets);
    save_json("custom_sections.json", &snap.sections);
}

pub fn spawn(demo: bool) -> watch::Receiver<WorkSnapshot> {
    let snap = if demo {
        WorkSnapshot::demo()
    } else {
        let mut projects: Vec<ProjectItem> = load_json("projects.json");
        if projects.is_empty() {
            projects = seed_from_work_dir();
        }
        let presets: Vec<String> = {
            let p: Vec<String> = load_json("presets.json");
            if p.is_empty() { default_presets() } else { p }
        };
        WorkSnapshot { projects, presets, sections: load_json("custom_sections.json"), ..Default::default() }
    };
    let (tx, rx) = watch::channel(snap.clone());
    let _ = TX.set(Mutex::new(tx));
    let _ = INNER.set(Mutex::new(Inner { snap }));
    rx
}

pub fn add_project(name: String, path: String, agent: String) {
    let Some(inner) = INNER.get() else { return };
    let Ok(mut inner) = inner.lock() else { return };
    let folder = expand_tilde(&path);
    let cmd = detect_default_service_command(&folder);
    inner.snap.projects.push(ProjectItem {
        id: new_id(),
        name: if name.is_empty() {
            folder.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| path.clone())
        } else {
            name
        },
        path,
        service_command: cmd,
        agent_command: if agent.is_empty() { "claude".into() } else { agent },
    });
    persist(&inner.snap);
    drop(inner);
    publish();
}

pub fn remove_project(id: &str) {
    let Some(inner) = INNER.get() else { return };
    let Ok(mut inner) = inner.lock() else { return };
    inner.snap.projects.retain(|p| p.id != id);
    persist(&inner.snap);
    drop(inner);
    publish();
}

pub fn add_section(name: String) {
    let Some(inner) = INNER.get() else { return };
    let Ok(mut inner) = inner.lock() else { return };
    inner.snap.sections.push(CustomSection { id: new_id(), name, items: vec![] });
    persist(&inner.snap);
    drop(inner);
    publish();
}

pub fn add_item(section_id: &str, name: String, kind: ItemKind, value: String) {
    let Some(inner) = INNER.get() else { return };
    let Ok(mut inner) = inner.lock() else { return };
    if let Some(s) = inner.snap.sections.iter_mut().find(|s| s.id == section_id) {
        s.items.push(CustomItem { id: new_id(), name, kind, value });
    }
    persist(&inner.snap);
    drop(inner);
    publish();
}

pub fn remove_item(section_id: &str, item_id: &str) {
    let Some(inner) = INNER.get() else { return };
    let Ok(mut inner) = inner.lock() else { return };
    if let Some(s) = inner.snap.sections.iter_mut().find(|s| s.id == section_id) {
        s.items.retain(|i| i.id != item_id);
    }
    persist(&inner.snap);
    drop(inner);
    publish();
}

pub fn start_service(id: &str) {
    let Some(inner) = INNER.get() else { return };
    let Ok(inner) = inner.lock() else { return };
    if inner.snap.running.contains_key(id) {
        return;
    }
    let Some(proj) = inner.snap.projects.iter().find(|p| p.id == id).cloned() else { return };
    let cwd = proj.expanded_path();
    let cmd = proj.service_command.clone();
    let id_owned = id.to_string();
    drop(inner);

    let spawned = {
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            Command::new("cmd")
                .args(["/C", &cmd])
                .current_dir(&cwd)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .creation_flags(CREATE_NO_WINDOW)
                .spawn()
        }
        #[cfg(not(windows))]
        {
            Command::new("sh")
                .args(["-c", &cmd])
                .current_dir(&cwd)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
        }
    };

    let Ok(mut child) = spawned else { return };
    let pid = child.id();
    if let Some(inner) = INNER.get() {
        if let Ok(mut inner) = inner.lock() {
            inner.snap.running.insert(id_owned.clone(), pid);
            inner.snap.logs.insert(id_owned.clone(), String::new());
        }
    }
    publish();

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    thread::spawn(move || {
        let mut lines = Vec::new();
        if let Some(out) = stdout {
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                append_log(&id_owned, &mut lines, &line);
            }
        }
        if let Some(err) = stderr {
            for line in BufReader::new(err).lines().map_while(Result::ok) {
                append_log(&id_owned, &mut lines, &line);
            }
        }
        let code = child.wait().ok().and_then(|s| s.code()).unwrap_or(-1);
        if let Some(inner) = INNER.get() {
            if let Ok(mut inner) = inner.lock() {
                inner.snap.running.remove(&id_owned);
                inner.snap.last_exit.insert(id_owned, code);
            }
        }
        publish();
    });
}

fn append_log(id: &str, ring: &mut Vec<String>, line: &str) {
    ring.push(line.to_string());
    if ring.len() > LOG_RING {
        let drop_n = ring.len() - LOG_RING;
        ring.drain(0..drop_n);
    }
    if let Some(inner) = INNER.get() {
        if let Ok(mut inner) = inner.lock() {
            inner.snap.logs.insert(id.to_string(), ring.join("\n"));
        }
    }
}

pub fn stop_service(id: &str) {
    let pid = INNER.get().and_then(|i| i.lock().ok()).and_then(|i| i.snap.running.get(id).copied());
    if let Some(pid) = pid {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build();
        if let Ok(rt) = rt {
            let _ = rt.block_on(process::kill_process_tree(pid));
        }
    }
}

pub fn launch_terminal(app: TerminalApp, cwd: &Path, command: Option<&str>) {
    let cwd_s = cwd.display().to_string();
    match preferred(app) {
        TermKind::WindowsTerminal => {
            let mut args = vec!["-d".into(), cwd_s];
            if let Some(c) = command {
                args.extend(["powershell".into(), "-NoExit".into(), "-Command".into(), c.into()]);
            }
            let arg_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
            let _ = run_hidden_sync("wt", &arg_refs);
        }
        TermKind::Powershell => {
            let cmd = match command {
                Some(c) => format!("Set-Location '{}'; {c}", cwd.display()),
                None => format!("Set-Location '{}'", cwd.display()),
            };
            let _ = run_hidden_sync("powershell", &["-NoExit", "-Command", &cmd]);
        }
        TermKind::Wezterm => {
            if let Some(c) = command {
                let _ = run_hidden_sync("wezterm", &["start", "--cwd", &cwd_s, "--", "sh", "-c", c]);
            } else {
                let _ = run_hidden_sync("wezterm", &["start", "--cwd", &cwd_s]);
            }
        }
        TermKind::Gnome => {
            if let Some(c) = command {
                let _ = run_hidden_sync("gnome-terminal", &["--working-directory", &cwd_s, "--", "bash", "-lc", c]);
            } else {
                let _ = run_hidden_sync("gnome-terminal", &["--working-directory", &cwd_s]);
            }
        }
        TermKind::Kitty => {
            if let Some(c) = command {
                let _ = run_hidden_sync("kitty", &["--directory", &cwd_s, "bash", "-lc", c]);
            } else {
                let _ = run_hidden_sync("kitty", &["--directory", &cwd_s]);
            }
        }
        TermKind::Xdg => {
            process::open_path(cwd);
        }
    }
}

enum TermKind {
    WindowsTerminal,
    Powershell,
    Wezterm,
    Gnome,
    Kitty,
    Xdg,
}

fn which(bin: &str) -> bool {
    run_hidden_sync("which", &[bin]).map(|o| o.status == 0).unwrap_or(false)
        || run_hidden_sync("where", &[bin]).map(|o| o.status == 0).unwrap_or(false)
}

fn preferred(app: TerminalApp) -> TermKind {
    match app {
        TerminalApp::WindowsTerminal => TermKind::WindowsTerminal,
        TerminalApp::Powershell => TermKind::Powershell,
        TerminalApp::Wezterm => TermKind::Wezterm,
        TerminalApp::Auto => {
            #[cfg(windows)]
            {
                if which("wt") {
                    return TermKind::WindowsTerminal;
                }
                if which("wezterm") {
                    return TermKind::Wezterm;
                }
                return TermKind::Powershell;
            }
            #[cfg(not(windows))]
            {
                if which("wezterm") {
                    return TermKind::Wezterm;
                }
                if which("kitty") {
                    return TermKind::Kitty;
                }
                if which("gnome-terminal") {
                    return TermKind::Gnome;
                }
                TermKind::Xdg
            }
        }
        _ => {
            #[cfg(windows)]
            {
                TermKind::Powershell
            }
            #[cfg(not(windows))]
            {
                if which("wezterm") {
                    TermKind::Wezterm
                } else {
                    TermKind::Xdg
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_prefers_cargo_then_npm_dev() {
        let root = std::env::temp_dir().join(format!("bn-work-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("Cargo.toml"), "[package]\nname=\"x\"\nversion=\"0.1.0\"\n").unwrap();
        assert_eq!(detect_default_service_command(&root), "cargo run");
        fs::write(root.join("package.json"), r#"{"scripts":{"dev":"vite"}}"#).unwrap();
        assert_eq!(detect_default_service_command(&root), "npm run dev");
        fs::write(root.join("pnpm-lock.yaml"), "").unwrap();
        assert_eq!(detect_default_service_command(&root), "pnpm dev");
        let _ = fs::remove_dir_all(&root);
    }
}
