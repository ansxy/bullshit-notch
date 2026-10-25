//! Live Antigravity conversations (port of `Sources/Antigravity.swift`).
//!
//! A running conversation holds an exclusive lock on `<root>/presence/<id>.lock`;
//! its transcript is `<root>/brain/<id>/.system_generated/logs/transcript.jsonl`.
//! ponytail: undocumented Antigravity layout; if it changes upstream these rows just disappear.

use super::agents::{Agent, Harness};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Default, Clone)]
struct Parsed {
    offset: u64,
    usage: HashMap<i64, (u64, u64)>,
    status: String,
    last_step_ms: Option<f64>,
}

impl Parsed {
    fn total(&self) -> (u64, u64) {
        self.usage.values().fold((0, 0), |a, v| (a.0 + v.0, a.1 + v.1))
    }
}

#[derive(Default)]
pub struct AntigravitySessions {
    owners: HashMap<String, (i32, String)>,
    parsed: HashMap<PathBuf, Parsed>,
}

pub fn roots(gemini_dir: &Path) -> [PathBuf; 2] {
    [gemini_dir.join("antigravity-cli"), gemini_dir.join("antigravity")]
}

impl AntigravitySessions {
    pub fn refresh(&mut self, gemini_dir: &Path) -> Vec<(Agent, (u64, u64))> {
        let mut out = Vec::new();
        let mut live = HashSet::new();
        let mut live_urls = HashSet::new();
        for root in roots(gemini_dir) {
            let Ok(locks) = fs::read_dir(root.join("presence")) else { continue };
            for lock in locks.flatten().map(|e| e.path()) {
                if lock.extension().and_then(|e| e.to_str()) != Some("lock") || !is_held(&lock) {
                    continue;
                }
                let Some(id) = lock.file_stem().and_then(|s| s.to_str()).map(str::to_string) else { continue };
                let (pid, cwd) = self.owner(&lock, &id);
                live.insert(id.clone());
                let transcript = root.join("brain").join(&id).join(".system_generated/logs/transcript.jsonl");
                live_urls.insert(transcript.clone());
                let mut p = self.parse(&transcript);
                let now_ms = now_ms();
                // ponytail: silent for 10 min while "busy" → assume we misread a final step.
                if p.status == "busy" && p.last_step_ms.is_some_and(|t| now_ms - t > 600_000.0) {
                    p.status = "idle".into();
                }
                let created = fs::metadata(&lock)
                    .and_then(|m| m.created().or_else(|_| m.modified()))
                    .ok()
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                    .map(|d| d.as_millis() as f64)
                    .unwrap_or(now_ms);
                let agent = Agent {
                    harness: Harness::Antigravity,
                    pid,
                    session_id: id,
                    cwd,
                    name: None,
                    status: Some(if p.status.is_empty() { "idle".into() } else { p.status.clone() }),
                    started_at: created,
                    status_updated_at: p.last_step_ms,
                };
                out.push((agent, p.total()));
            }
        }
        self.owners.retain(|k, _| live.contains(k));
        self.parsed.retain(|k, _| live_urls.contains(k));
        out
    }

    /// Which process holds the lock, and its cwd. Cached per conversation.
    fn owner(&mut self, lock: &Path, id: &str) -> (i32, String) {
        if let Some(o) = self.owners.get(id) {
            return o.clone();
        }
        let home = directories::UserDirs::new()
            .map(|u| u.home_dir().display().to_string())
            .unwrap_or_default();
        let o = find_lock_owner(lock).unwrap_or((0, home));
        self.owners.insert(id.to_string(), o.clone());
        o
    }

    fn parse(&mut self, url: &Path) -> Parsed {
        let mut entry = self.parsed.remove(url).unwrap_or_default();
        if let Ok(mut f) = File::open(url) {
            let mut data = Vec::new();
            if f.seek(SeekFrom::Start(entry.offset)).is_ok() && f.read_to_end(&mut data).is_ok() {
                if let Some(end) = data.iter().rposition(|&b| b == b'\n') {
                    for line in data[..end].split(|&b| b == b'\n') {
                        read_line(line, &mut entry);
                    }
                    entry.offset += end as u64 + 1;
                }
            }
        }
        self.parsed.insert(url.to_path_buf(), entry.clone());
        entry
    }
}

fn now_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as f64).unwrap_or(0.0)
}

pub fn parse_ts_ms(s: &str) -> Option<f64> {
    chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp_millis() as f64)
}

fn read_line(line: &[u8], entry: &mut Parsed) {
    let Ok(obj) = serde_json::from_slice::<serde_json::Value>(line) else { return };
    let kind = obj.get("type").and_then(|v| v.as_str()).unwrap_or("");
    let step = obj.get("status").and_then(|v| v.as_str()).unwrap_or("").to_uppercase();
    if let Some(ms) = obj.get("created_at").and_then(|v| v.as_str()).and_then(parse_ts_ms) {
        entry.last_step_ms = Some(ms);
    }
    // Latest step decides: a model reply with no tool calls hands control back to you.
    entry.status = if step.contains("WAIT") {
        "waiting"
    } else if step.contains("ERROR") || step.contains("CANCEL") {
        "idle"
    } else if kind == "PLANNER_RESPONSE" {
        let calls = obj.get("tool_calls").and_then(|v| v.as_array()).map_or(0, |a| a.len());
        if calls == 0 { "idle" } else { "busy" }
    } else {
        "busy"
    }
    .into();
    if kind != "PLANNER_RESPONSE" {
        return;
    }
    let int = |k: &str| obj.get(k).and_then(|v| v.as_u64()).unwrap_or(0);
    let key = obj.get("step_index").and_then(|v| v.as_i64()).unwrap_or(entry.usage.len() as i64);
    entry.usage.insert(
        key,
        (
            int("input_tokens") + int("cache_creation_tokens") + int("cache_write_tokens") + int("cache_read_tokens") / 10,
            int("output_tokens"),
        ),
    );
}

/// True if some process holds the lock (the conversation is open).
fn is_held(path: &Path) -> bool {
    let Ok(f) = File::open(path) else { return false };
    match f.try_lock_shared() {
        Ok(()) => {
            let _ = f.unlock();
            false
        }
        Err(_) => true,
    }
}

/// Linux: scan `/proc/*/fd` for the lock path. ponytail: Windows has no cheap equivalent
/// (would need the Restart Manager API), so pid 0 + home dir.
fn find_lock_owner(lock: &Path) -> Option<(i32, String)> {
    #[cfg(target_os = "linux")]
    {
        let target = fs::canonicalize(lock).ok()?;
        for proc in fs::read_dir("/proc").ok()?.flatten() {
            let Some(pid) = proc.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) else { continue };
            let Ok(fds) = fs::read_dir(proc.path().join("fd")) else { continue };
            if fds.flatten().any(|fd| fs::read_link(fd.path()).ok().as_deref() == Some(target.as_path())) {
                let cwd = fs::read_link(proc.path().join("cwd")).ok()?.display().to_string();
                return Some((pid, cwd));
            }
        }
        None
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = lock;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_and_usage_from_transcript_lines() {
        let mut p = Parsed::default();
        read_line(br#"{"type":"USER_INPUT","created_at":"2026-10-25T10:00:00Z"}"#, &mut p);
        assert_eq!(p.status, "busy");
        read_line(
            br#"{"type":"PLANNER_RESPONSE","step_index":1,"tool_calls":[{}],"input_tokens":100,"cache_read_tokens":1000,"output_tokens":20,"created_at":"2026-10-25T10:00:05Z"}"#,
            &mut p,
        );
        assert_eq!(p.status, "busy");
        read_line(br#"{"type":"PLANNER_RESPONSE","step_index":1,"input_tokens":100,"cache_read_tokens":1000,"output_tokens":20}"#, &mut p);
        assert_eq!(p.status, "idle");
        assert_eq!(p.total(), (200, 20)); // step 1 deduped
        read_line(br#"{"type":"X","status":"WAITING_FOR_USER"}"#, &mut p);
        assert_eq!(p.status, "waiting");
    }
}
