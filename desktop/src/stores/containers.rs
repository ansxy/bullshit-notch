//! Docker / Podman listing (port of `Sources/Containers.swift`). WSL2 probe is Windows-only.

use crate::config::ContainerCli;
use crate::platform::process::run_hidden_sync;
use serde_json::Value;
use std::sync::{Mutex, OnceLock};
use tokio::sync::watch;

static TX: OnceLock<Mutex<watch::Sender<ContainerSnapshot>>> = OnceLock::new();
static PREF: OnceLock<Mutex<ContainerCli>> = OnceLock::new();

pub fn refresh_now() {
    let pref = PREF.get().and_then(|p| p.lock().ok()).map(|g| *g).unwrap_or_default();
    if let Some(tx) = TX.get() {
        if let Ok(tx) = tx.lock() {
            let _ = tx.send(refresh(pref));
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerItem {
    pub id: String,
    pub name: String,
    pub image: String,
    pub state: String,
    pub status: String,
    pub ports: Vec<i32>,
    pub raw_ports: String,
    pub compose_project: Option<String>,
    pub cli: String,
}

impl ContainerItem {
    pub fn is_running(&self) -> bool {
        self.state.eq_ignore_ascii_case("running")
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct ContainerSnapshot {
    pub engine_running: bool,
    pub cli: String,
    pub containers: Vec<ContainerItem>,
    pub error: Option<String>,
    pub wsl2: bool,
}

impl ContainerSnapshot {
    pub fn demo() -> Self {
        Self {
            engine_running: true,
            cli: "docker".into(),
            wsl2: false,
            error: None,
            containers: vec![
                ContainerItem {
                    id: "a1b2c3d4e5f6".into(),
                    name: "api".into(),
                    image: "node:20".into(),
                    state: "running".into(),
                    status: "Up 2 hours".into(),
                    ports: vec![3000],
                    raw_ports: "0.0.0.0:3000->3000/tcp".into(),
                    compose_project: Some("web".into()),
                    cli: "docker".into(),
                },
                ContainerItem {
                    id: "f6e5d4c3b2a1".into(),
                    name: "db".into(),
                    image: "postgres:16".into(),
                    state: "exited".into(),
                    status: "Exited (0)".into(),
                    ports: vec![],
                    raw_ports: String::new(),
                    compose_project: Some("web".into()),
                    cli: "docker".into(),
                },
            ],
        }
    }
}

/// Host ports from `0.0.0.0:3000->3000/tcp` / `:::8080->80/tcp`.
pub fn extract_host_ports(text: &str) -> Vec<i32> {
    let mut result = Vec::new();
    let parts: Vec<&str> = text.split("->").collect();
    for chunk in parts.iter().take(parts.len().saturating_sub(1)) {
        if let Some(colon) = chunk.rfind(':') {
            if let Ok(port) = chunk[colon + 1..].trim().parse::<i32>() {
                if port > 0 && !result.contains(&port) {
                    result.push(port);
                }
            }
        }
    }
    result.sort();
    result
}

pub fn extract_compose_project(labels: &str) -> Option<String> {
    for pair in labels.split(',') {
        let mut kv = pair.splitn(2, '=');
        let k = kv.next()?.trim();
        let v = kv.next()?.trim();
        if k == "com.docker.compose.project" || k == "io.podman.compose.project" {
            return Some(v.to_string());
        }
    }
    None
}

pub fn parse_docker_ndjson(text: &str, cli: &str) -> Vec<ContainerItem> {
    let mut items = Vec::new();
    for line in text.lines() {
        let Ok(obj) = serde_json::from_str::<Value>(line) else { continue };
        let id = obj.get("ID").or_else(|| obj.get("Id")).and_then(|v| v.as_str()).unwrap_or("");
        let name = obj.get("Names").and_then(|v| v.as_str()).unwrap_or(id);
        let image = obj.get("Image").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let state = obj.get("State").and_then(|v| v.as_str()).unwrap_or("unknown").to_string();
        let status = obj.get("Status").and_then(|v| v.as_str()).unwrap_or(state.as_str()).to_string();
        let ports_str = obj.get("Ports").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let labels = obj.get("Labels").and_then(|v| v.as_str()).unwrap_or("");
        items.push(ContainerItem {
            id: id.chars().take(12).collect(),
            name: name.trim_start_matches('/').to_string(),
            image,
            state,
            status,
            ports: extract_host_ports(&ports_str),
            raw_ports: ports_str,
            compose_project: extract_compose_project(labels),
            cli: cli.to_string(),
        });
    }
    sort_containers(items)
}

fn sort_containers(mut items: Vec<ContainerItem>) -> Vec<ContainerItem> {
    items.sort_by(|a, b| match (a.is_running(), b.is_running()) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
    });
    items
}

fn probe_wsl2() -> bool {
    #[cfg(windows)]
    {
        run_hidden_sync("wsl", &["-l", "-v"]).map(|o| o.status == 0 && o.stdout.to_lowercase().contains("version")).unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        false
    }
}

fn pick_cli(pref: ContainerCli) -> Option<&'static str> {
    let try_bin = |b: &'static str| run_hidden_sync(b, &["version"]).map(|o| o.status == 0).unwrap_or(false);
    match pref {
        ContainerCli::Docker => try_bin("docker").then_some("docker"),
        ContainerCli::Podman => try_bin("podman").then_some("podman"),
        ContainerCli::Auto => {
            if try_bin("docker") {
                Some("docker")
            } else if try_bin("podman") {
                Some("podman")
            } else {
                None
            }
        }
    }
}

pub fn refresh(pref: ContainerCli) -> ContainerSnapshot {
    let wsl2 = probe_wsl2();
    let Some(cli) = pick_cli(pref) else {
        return ContainerSnapshot {
            error: Some("Neither docker nor podman CLI was found.".into()),
            wsl2,
            ..Default::default()
        };
    };
    let out = match cli {
        "podman" => run_hidden_sync("podman", &["ps", "-a", "--format", "json"]),
        _ => run_hidden_sync("docker", &["ps", "-a", "--format", "{{json .}}"]),
    };
    match out {
        Ok(o) if o.status == 0 => ContainerSnapshot {
            engine_running: true,
            cli: cli.into(),
            containers: parse_docker_ndjson(&o.stdout, cli),
            error: None,
            wsl2,
        },
        Ok(o) => ContainerSnapshot {
            cli: cli.into(),
            error: Some(o.stderr.trim().to_string()),
            wsl2,
            ..Default::default()
        },
        Err(e) => ContainerSnapshot { cli: cli.into(), error: Some(e.to_string()), wsl2, ..Default::default() },
    }
}

pub fn container_action(cli: &str, id: &str, verb: &str) {
    let _ = run_hidden_sync(cli, &[verb, id]);
}

pub fn spawn(ctx: egui::Context, demo: bool, pref: ContainerCli) -> watch::Receiver<ContainerSnapshot> {
    if demo {
        return super::fixed(ContainerSnapshot::demo());
    }
    let _ = PREF.set(Mutex::new(pref));
    let (tx, rx) = watch::channel(ContainerSnapshot::default());
    let _ = TX.set(Mutex::new(tx.clone()));
    let _ = std::thread::Builder::new().name("containers".into()).spawn(move || loop {
        let pref = PREF.get().and_then(|p| p.lock().ok()).map(|g| *g).unwrap_or(pref);
        let snap = refresh(pref);
        let _ = tx.send(snap);
        ctx.request_repaint();
        if tx.is_closed() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_secs(8));
    });
    rx
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ports_and_compose_from_ndjson() {
        let line = r#"{"ID":"abcdef1234567890","Names":"/api","Image":"node:20","State":"running","Status":"Up","Ports":"0.0.0.0:3000->3000/tcp, :::8080->80/tcp","Labels":"com.docker.compose.project=web,foo=bar"}"#;
        let items = parse_docker_ndjson(line, "docker");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "abcdef123456");
        assert_eq!(items[0].name, "api");
        assert_eq!(items[0].ports, vec![3000, 8080]);
        assert_eq!(items[0].compose_project.as_deref(), Some("web"));
        assert!(items[0].is_running());
    }
}
