//! Cursor agent sessions (`~/.cursor/projects/<slug>/agent-transcripts`) plus
//! request-count usage from `~/.cursor/ai-tracking/ai-code-tracking.db`.

use super::agents::{Agent, Harness};
use super::usage::UsageEntry;
use chrono::{TimeZone, Utc};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const RECENT_MS: f64 = 45.0 * 60_000.0;

fn now_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as f64).unwrap_or(0.0)
}

fn file_ms(path: &Path) -> f64 {
    fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0)
}

fn cursor_running() -> bool {
    #[cfg(target_os = "linux")]
    {
        let Ok(rd) = fs::read_dir("/proc") else { return false };
        rd.flatten().any(|e| {
            let cmd = fs::read_to_string(e.path().join("comm")).unwrap_or_default();
            let c = cmd.trim();
            c.eq_ignore_ascii_case("cursor") || c.starts_with("Cursor") || c.contains("cursor.appimage")
        })
    }
    #[cfg(windows)]
    {
        crate::platform::process::run_hidden_sync("tasklist", &["/FI", "IMAGENAME eq Cursor.exe"])
            .map(|o| o.stdout.to_lowercase().contains("cursor.exe"))
            .unwrap_or(false)
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        true
    }
}

/// Rebuild a path from Cursor's hyphen slug. Greedy existing-dir match keeps
/// names like `bullshit-notch` intact instead of turning them into `bullshit/notch`.
pub fn decode_project_slug(slug: &str) -> String {
    let parts: Vec<&str> = slug.split('-').filter(|s| !s.is_empty()).collect();
    if parts.is_empty() || parts.iter().all(|p| p.chars().all(|c| c.is_ascii_digit())) {
        return slug.to_string();
    }
    let mut path = PathBuf::from("/");
    let mut i = 0;
    while i < parts.len() {
        let mut hit = None;
        for j in (i + 1..=parts.len()).rev() {
            let cand = path.join(parts[i..j].join("-"));
            if cand.exists() {
                hit = Some((j, cand));
                break;
            }
        }
        if let Some((j, cand)) = hit {
            path = cand;
            i = j;
        } else {
            path = path.join(parts[i..].join("-"));
            break;
        }
    }
    path.display().to_string()
}

fn scan_jsonl(path: &Path) -> (String, (u64, u64), Option<String>) {
    let Ok(raw) = fs::read_to_string(path) else {
        return ("idle".into(), (0, 0), None);
    };
    let mut status = "idle".to_string();
    let mut assistants = 0u64;
    let mut title = None;
    for line in raw.lines() {
        let Ok(obj) = serde_json::from_slice::<Value>(line.as_bytes()) else { continue };
        if obj.get("type").and_then(|v| v.as_str()) == Some("turn_ended") {
            status = "idle".into();
            continue;
        }
        let role = obj.get("role").and_then(|v| v.as_str()).unwrap_or("");
        match role {
            "user" => {
                status = "waiting".into();
                if title.is_none() {
                    title = first_text(&obj).and_then(|s| short_title(&s));
                }
            }
            "assistant" => {
                status = "busy".into();
                assistants += 1;
            }
            _ => {}
        }
    }
    (status, (assistants, 0), title)
}

fn first_text(obj: &Value) -> Option<String> {
    let msg = obj.get("message")?;
    let content = msg.get("content")?;
    if let Some(s) = content.as_str() {
        return Some(s.into());
    }
    let arr = content.as_array()?;
    for block in arr {
        if let Some(t) = block.get("text").and_then(|v| v.as_str()) {
            return Some(t.into());
        }
    }
    None
}

fn short_title(s: &str) -> Option<String> {
    let stripped = s
        .lines()
        .find(|l| {
            let t = l.trim();
            !t.is_empty() && !t.starts_with('<') && !t.starts_with('#')
        })
        .unwrap_or(s)
        .trim();
    if stripped.is_empty() {
        return None;
    }
    let mut t = stripped.chars().take(72).collect::<String>();
    if stripped.chars().count() > 72 {
        t.push('…');
    }
    Some(t)
}

pub fn refresh(cursor_home: &Path) -> Vec<(Agent, (u64, u64))> {
    if !cursor_running() {
        return Vec::new();
    }
    let projects = cursor_home.join("projects");
    let now = now_ms();
    let mut out = Vec::new();
    let Ok(rd) = fs::read_dir(&projects) else { return out };
    for proj in rd.flatten() {
        let slug = proj.file_name().to_string_lossy().into_owned();
        if slug.starts_with("tmp-") || slug == "empty-window" || slug.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let transcripts = proj.path().join("agent-transcripts");
        let Ok(chats) = fs::read_dir(&transcripts) else { continue };
        let cwd = decode_project_slug(&slug);
        for chat in chats.flatten() {
            let dir = chat.path();
            let id = chat.file_name().to_string_lossy().into_owned();
            let jsonl = dir.join(format!("{id}.jsonl"));
            let path = if jsonl.exists() {
                jsonl
            } else {
                let Ok(inner) = fs::read_dir(&dir) else { continue };
                match inner.flatten().map(|e| e.path()).find(|p| p.extension().and_then(|e| e.to_str()) == Some("jsonl")) {
                    Some(p) => p,
                    None => continue,
                }
            };
            let mtime = file_ms(&path);
            if now - mtime > RECENT_MS {
                continue;
            }
            let (status, tokens, title) = scan_jsonl(&path);
            out.push((
                Agent {
                    harness: Harness::Cursor,
                    pid: 0,
                    session_id: id,
                    cwd: cwd.clone(),
                    name: title,
                    status: Some(status),
                    started_at: mtime,
                    status_updated_at: Some(mtime),
                },
                tokens,
            ));
        }
    }
    out.sort_by(|a, b| b.0.started_at.partial_cmp(&a.0.started_at).unwrap_or(std::cmp::Ordering::Equal));
    out.truncate(24);
    out
}

/// Unique composer/agent `requestId`s from Cursor's tracking DB (1 request = 1 usage unit).
pub fn request_entries(cursor_home: &Path) -> Vec<UsageEntry> {
    let db = cursor_home.join("ai-tracking/ai-code-tracking.db");
    if !db.exists() {
        return Vec::new();
    }
    let sql = "SELECT requestId, MIN(timestamp) FROM ai_code_hashes WHERE requestId IS NOT NULL GROUP BY requestId;";
    let db_s = db.to_str().unwrap_or("");
    let out = crate::platform::process::run_hidden_sync("sqlite3", &["-readonly", "-separator", "|", db_s, sql]);
    let Ok(out) = out else { return Vec::new() };
    if out.status != 0 {
        return Vec::new();
    }
    let mut entries = Vec::new();
    for line in out.stdout.lines() {
        let mut parts = line.splitn(2, '|');
        let Some(id) = parts.next() else { continue };
        let Some(ts) = parts.next() else { continue };
        let Ok(raw) = ts.trim().parse::<i64>() else { continue };
        // Cursor stores ms; older rows might be seconds.
        let ms = if raw > 10_000_000_000 { raw } else { raw.saturating_mul(1000) };
        let secs = ms / 1000;
        let nsecs = ((ms % 1000) * 1_000_000) as u32;
        let Some(date) = Utc.timestamp_opt(secs, nsecs).single() else { continue };
        entries.push(UsageEntry {
            date,
            key: id.trim().to_string(),
            input: 1,
            output: 0,
            cache_write: 0,
            cache_read: 0,
        });
    }
    entries
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_keeps_hyphenated_dir() {
        let decoded = decode_project_slug("home-istaqom-Coding-GitHub-bullshit-notch");
        assert!(decoded.contains("bullshit"), "{decoded}");
        assert!(!decoded.contains("bullshit/notch"), "{decoded}");
    }

    #[test]
    fn jsonl_status_and_title() {
        let dir = std::env::temp_dir().join(format!("bn-cursor-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let p = dir.join("t.jsonl");
        fs::write(
            &p,
            r#"{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>x</timestamp>\nShip the usage pill"}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}
{"type":"turn_ended"}
"#,
        )
        .unwrap();
        let (status, tokens, title) = scan_jsonl(&p);
        assert_eq!(status, "idle");
        assert_eq!(tokens.0, 1);
        assert_eq!(title.as_deref(), Some("Ship the usage pill"));
        let _ = fs::remove_dir_all(&dir);
    }
}
