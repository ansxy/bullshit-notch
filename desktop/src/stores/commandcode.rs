//! Command Code sessions + jsonl usage (`~/.commandcode/projects/<slug>/<id>.jsonl`).

use super::agents::{Agent, Harness};
use super::usage::UsageEntry;
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const RECENT_MS: f64 = 45.0 * 60_000.0;

fn now_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as f64).unwrap_or(0.0)
}

pub fn roots(home: &Path) -> PathBuf {
    home.join(".commandcode")
}

/// Live Command Code CLIs whose cwd we can see (Linux `/proc`). Windows: empty.
pub fn running_cwds() -> Vec<(i32, PathBuf)> {
    #[cfg(target_os = "linux")]
    {
        let mut out = Vec::new();
        let Ok(rd) = fs::read_dir("/proc") else { return out };
        for e in rd.flatten() {
            let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) else { continue };
            let cmd = fs::read_to_string(e.path().join("cmdline")).unwrap_or_default();
            let hit = cmd.split('\0').any(|p| {
                let b = Path::new(p).file_name().and_then(|s| s.to_str()).unwrap_or(p);
                b == "commandcode" || b == "command-code" || p.contains("command-code")
            });
            if !hit {
                continue;
            }
            if let Ok(cwd) = fs::read_link(e.path().join("cwd")) {
                out.push((pid, cwd));
            }
        }
        out
    }
    #[cfg(not(target_os = "linux"))]
    {
        Vec::new()
    }
}

/// Command Code kebab: drop leading `/`, split camelCase (`GitHub` → `git-hub`).
pub fn slugify(path: &Path) -> String {
    let chars: Vec<char> = path.to_string_lossy().chars().collect();
    let mut out = String::new();
    for (i, &c) in chars.iter().enumerate() {
        if c.is_ascii_alphanumeric() {
            let prev = if i > 0 { chars[i - 1] } else { '/' };
            let next = chars.get(i + 1).copied();
            let camel = c.is_ascii_uppercase()
                && (prev.is_ascii_lowercase()
                    || prev.is_ascii_digit()
                    || (prev.is_ascii_uppercase() && next.is_some_and(|n| n.is_ascii_lowercase())));
            if camel && !out.is_empty() && !out.ends_with('-') {
                out.push('-');
            }
            out.push(c.to_ascii_lowercase());
        } else if !out.is_empty() && !out.ends_with('-') {
            out.push('-');
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    out
}

fn meta_title(path: &Path) -> Option<String> {
    let raw = fs::read_to_string(path).ok()?;
    let v: Value = serde_json::from_str(&raw).ok()?;
    v.get("title").and_then(|t| t.as_str()).map(|s| s.to_string())
}

fn file_ms(path: &Path) -> f64 {
    fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0)
}

/// Status + token totals from a Command Code transcript.
pub fn scan_transcript(path: &Path) -> (String, (u64, u64), Option<f64>) {
    let Ok(raw) = fs::read_to_string(path) else {
        return ("idle".into(), (0, 0), None);
    };
    let mut status = "idle".to_string();
    let mut inp = 0u64;
    let mut out = 0u64;
    let mut last_ms = None;
    for line in raw.lines() {
        let Ok(obj) = serde_json::from_slice::<Value>(line.as_bytes()) else { continue };
        let kind = obj.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if kind == "file-history-snapshot" || kind.contains("checkpoint") {
            continue;
        }
        if let Some(ms) = obj.get("timestamp").and_then(|v| v.as_str()).and_then(super::antigravity::parse_ts_ms) {
            last_ms = Some(ms);
        }
        status = match kind {
            "tool" => "busy",
            "user" => "waiting",
            "assistant" | "message" | "session" => "idle",
            _ => status.as_str(),
        }
        .into();
        if let Some(e) = parse_usage_line(line.as_bytes()) {
            inp += e.input + e.cache_write + e.cache_read / 10;
            out += e.output;
        }
    }
    (status, (inp, out), last_ms)
}

pub fn parse_usage_line(line: &[u8]) -> Option<UsageEntry> {
    let obj: Value = serde_json::from_slice(line).ok()?;
    let kind = obj.get("type").and_then(|v| v.as_str()).unwrap_or("");
    if kind == "file-history-snapshot" {
        return None;
    }
    let usage = obj.get("usage").or_else(|| obj.get("message").and_then(|m| m.get("usage")))?;
    let date = obj
        .get("timestamp")
        .or_else(|| obj.get("created_at"))
        .and_then(|v| v.as_str())
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.with_timezone(&Utc))?;
    let key = obj
        .get("id")
        .or_else(|| obj.get("messageId"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let int = |k: &str, alt: &str| {
        usage.get(k).or_else(|| usage.get(alt)).and_then(|v| v.as_u64()).unwrap_or(0)
    };
    Some(UsageEntry {
        date,
        key,
        input: int("inputTokens", "input_tokens"),
        output: int("outputTokens", "output_tokens"),
        cache_write: int("cacheWriteTokens", "cache_write_tokens") + int("cacheCreationTokens", "cache_creation_tokens"),
        cache_read: int("cacheReadTokens", "cache_read_tokens"),
    })
}

pub fn refresh(commandcode_dir: &Path) -> Vec<(Agent, (u64, u64))> {
    let projects = commandcode_dir.join("projects");
    let running = running_cwds();
    let now = now_ms();
    let mut out = Vec::new();
    let Ok(slugs) = fs::read_dir(&projects) else { return out };
    for slug_ent in slugs.flatten() {
        let slug_path = slug_ent.path();
        if !slug_path.is_dir() {
            continue;
        }
        let slug = slug_ent.file_name().to_string_lossy().into_owned();
        let matched: Vec<(i32, PathBuf)> = running.iter().filter(|(_, cwd)| slugify(cwd) == slug).cloned().collect();
        let Ok(files) = fs::read_dir(&slug_path) else { continue };
        let mut jsonls: Vec<PathBuf> = files
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("jsonl"))
            .filter(|p| !p.file_name().and_then(|s| s.to_str()).unwrap_or("").contains("checkpoint"))
            .collect();
        jsonls.sort_by_key(|p| std::cmp::Reverse(file_ms(p) as u64));
        let Some(transcript) = jsonls.into_iter().next() else { continue };
        let mtime = file_ms(&transcript);
        if matched.is_empty() && now - mtime > RECENT_MS {
            continue;
        }
        let id = transcript.file_stem().and_then(|s| s.to_str()).unwrap_or("session").to_string();
        let (status, tokens, last_ms) = scan_transcript(&transcript);
        let title = meta_title(&transcript.with_extension("meta.json"));
        let (pid, cwd) = match matched.first() {
            Some((pid, cwd)) => (*pid, cwd.display().to_string()),
            None => (0, slug),
        };
        out.push((
            Agent {
                harness: Harness::CommandCode,
                pid,
                session_id: id,
                cwd,
                name: title,
                status: Some(status),
                started_at: mtime,
                status_updated_at: last_ms.or(Some(mtime)),
            },
            tokens,
        ));
    }
    out.sort_by(|a, b| b.0.started_at.partial_cmp(&a.0.started_at).unwrap_or(std::cmp::Ordering::Equal));
    out.truncate(24);
    out
}

pub fn read_api_key(commandcode_dir: &Path) -> Option<String> {
    let raw = fs::read_to_string(commandcode_dir.join("auth.json")).ok()?;
    let v: Value = serde_json::from_str(&raw).ok()?;
    let t = v.get("apiKey").and_then(|x| x.as_str())?;
    (!t.is_empty()).then(|| t.to_string())
}

/// Live 5h / 7d windows from Command Code `/alpha` billing (best-effort).
pub fn parse_live_windows(obj: &Value) -> (Option<f64>, Option<DateTime<Utc>>, Option<f64>, Option<DateTime<Utc>>) {
    let windows = obj.get("windowLimits").or_else(|| obj.get("data").and_then(|d| d.get("windowLimits")));
    let one = |name: &str| {
        let w = match windows.and_then(|w| w.get(name)) {
            Some(w) => w,
            None => return (None, None),
        };
        let used = w.get("used").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let cap = w.get("cap").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let pct = if cap > 0.0 {
            Some((used / cap) * 100.0)
        } else {
            w.get("percent").or_else(|| w.get("usagePercent")).and_then(|v| v.as_f64())
        };
        let at = w
            .get("resetAt")
            .or_else(|| w.get("resets_at"))
            .and_then(|v| v.as_str())
            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
            .map(|d| d.with_timezone(&Utc));
        (pct, at)
    };
    let (fh, fha) = one("fiveHour");
    let (sd, sda) = one("weekly");
    let credits_pct = obj
        .get("credits")
        .and_then(|c| c.get("usagePercent"))
        .and_then(|v| v.as_f64());
    (fh, fha, sd.or(credits_pct), sda)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugify_splits_camel_and_strips_slash() {
        assert_eq!(
            slugify(Path::new("/var/home/istaqom/Coding/GitHub/AutoExtremeCooling")),
            "var-home-istaqom-coding-git-hub-auto-extreme-cooling"
        );
        assert_eq!(
            slugify(Path::new("/home/istaqom/Coding/GitHub/bullshit-notch")),
            "home-istaqom-coding-git-hub-bullshit-notch"
        );
    }

    #[test]
    fn parses_camelcase_usage() {
        let e = parse_usage_line(
            br#"{"type":"message","id":"85efba83","timestamp":"2026-07-28T06:10:38.824Z","usage":{"inputTokens":100,"outputTokens":20,"cacheReadTokens":50,"cacheWriteTokens":10}}"#,
        )
        .unwrap();
        assert_eq!((e.key.as_str(), e.input, e.output, e.cache_write, e.cache_read), ("85efba83", 100, 20, 10, 50));
    }

    #[test]
    fn live_windows_from_summary() {
        let v: Value = serde_json::from_str(
            r#"{"windowLimits":{"fiveHour":{"used":20,"cap":100,"resetAt":"2026-10-25T12:00:00Z"},"weekly":{"used":40,"cap":200}},"credits":{"usagePercent":33.0}}"#,
        )
        .unwrap();
        let (fh, fha, sd, _) = parse_live_windows(&v);
        assert_eq!(fh, Some(20.0));
        assert!(fha.is_some());
        assert_eq!(sd, Some(20.0));
    }
}
