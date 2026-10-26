//! 5h / daily / 7d token usage for Claude / Antigravity / Command Code,
//! plus Cursor request counts and optional live `/usage` percentages.

use super::antigravity;
use super::agents::Harness;
use super::commandcode;
use super::cursor;
use chrono::{DateTime, Duration as CDuration, Local, TimeZone, Utc};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Mutex, OnceLock};
use std::time::{Duration, SystemTime};
use tokio::sync::watch;

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Bucket {
    pub input: u64,
    pub output: u64,
    pub cache_write: u64,
    pub cache_read: u64,
}

impl Bucket {
    /// Cache reads weighted at 0.1x so prompt-cache hits don't inflate usage 20-50x.
    pub fn effective(&self) -> u64 {
        self.input + self.cache_write + self.cache_read / 10 + self.output
    }

    fn add(&mut self, e: &UsageEntry) {
        self.input += e.input;
        self.output += e.output;
        self.cache_write += e.cache_write;
        self.cache_read += e.cache_read;
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct UsageStats {
    pub session: Bucket,
    pub daily: Bucket,
    pub weekly: Bucket,
    pub session_oldest: Option<DateTime<Utc>>,
    pub weekly_oldest: Option<DateTime<Utc>>,
    pub live_five_hour_percent: Option<f64>,
    pub live_five_hour_resets_at: Option<DateTime<Utc>>,
    pub live_seven_day_percent: Option<f64>,
    pub live_seven_day_resets_at: Option<DateTime<Utc>>,
}

impl UsageStats {
    pub fn session_resets_at(&self) -> Option<DateTime<Utc>> {
        self.live_five_hour_resets_at.or(self.session_oldest.map(|d| d + CDuration::hours(5)))
    }

    pub fn weekly_resets_at(&self) -> Option<DateTime<Utc>> {
        self.live_seven_day_resets_at.or(self.weekly_oldest.map(|d| d + CDuration::days(7)))
    }

    fn accumulate(&mut self, e: &UsageEntry, five_h_ago: DateTime<Utc>, start_of_day: DateTime<Utc>) {
        self.weekly.add(e);
        if self.weekly_oldest.is_none_or(|o| e.date < o) {
            self.weekly_oldest = Some(e.date);
        }
        if e.date >= start_of_day {
            self.daily.add(e);
        }
        if e.date >= five_h_ago {
            self.session.add(e);
            if self.session_oldest.is_none_or(|o| e.date < o) {
                self.session_oldest = Some(e.date);
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct UsageSnapshot {
    pub claude: UsageStats,
    pub agy: UsageStats,
    pub cursor: UsageStats,
    pub commandcode: UsageStats,
    pub oauth_connected: bool,
    pub cc_live: bool,
}

impl UsageSnapshot {
    pub fn stats(&self, h: Harness) -> &UsageStats {
        match h {
            Harness::Claude => &self.claude,
            Harness::Antigravity => &self.agy,
            Harness::Cursor => &self.cursor,
            Harness::CommandCode => &self.commandcode,
        }
    }
}

impl UsageSnapshot {
    pub fn demo() -> Self {
        let now = Utc::now();
        let b = |i, o, w, r| Bucket { input: i, output: o, cache_write: w, cache_read: r };
        Self {
            claude: UsageStats {
                session: b(418_000, 142_000, 1_240_000, 3_800_000),
                daily: b(1_120_000, 390_000, 2_900_000, 8_400_000),
                weekly: b(3_400_000, 1_180_000, 9_800_000, 26_500_000),
                session_oldest: Some(now - CDuration::minutes(192)),
                weekly_oldest: Some(now - CDuration::hours(108)),
                live_five_hour_percent: Some(62.0),
                live_five_hour_resets_at: Some(now + CDuration::minutes(108)),
                live_seven_day_percent: Some(48.0),
                live_seven_day_resets_at: Some(now + CDuration::hours(101)),
            },
            agy: UsageStats {
                session: b(290_000, 110_000, 2_500_000, 2_100_000),
                daily: b(640_000, 245_000, 4_100_000, 4_800_000),
                weekly: b(2_100_000, 780_000, 12_400_000, 14_200_000),
                session_oldest: Some(now - CDuration::minutes(162)),
                weekly_oldest: Some(now - CDuration::days(5)),
                ..Default::default()
            },
            cursor: UsageStats {
                session: b(42, 0, 0, 0),
                daily: b(96, 0, 0, 0),
                weekly: b(310, 0, 0, 0),
                session_oldest: Some(now - CDuration::minutes(80)),
                weekly_oldest: Some(now - CDuration::days(4)),
                ..Default::default()
            },
            commandcode: UsageStats {
                session: b(180_000, 64_000, 900_000, 1_200_000),
                daily: b(410_000, 150_000, 2_100_000, 3_400_000),
                weekly: b(1_600_000, 540_000, 7_200_000, 11_000_000),
                session_oldest: Some(now - CDuration::minutes(140)),
                weekly_oldest: Some(now - CDuration::days(3)),
                live_five_hour_percent: Some(28.0),
                live_five_hour_resets_at: Some(now + CDuration::minutes(190)),
                ..Default::default()
            },
            oauth_connected: true,
            cc_live: true,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UsageEntry {
    pub date: DateTime<Utc>,
    /// requestId (Claude) or `conv:step` (Antigravity); dedupes across files.
    pub key: String,
    pub input: u64,
    pub output: u64,
    pub cache_write: u64,
    pub cache_read: u64,
}

/// Parsed entries per transcript, reused while `(mtime, size)` is unchanged.
#[derive(Default)]
pub struct UsageFileCache {
    files: HashMap<PathBuf, (SystemTime, u64, Vec<UsageEntry>)>,
}

impl UsageFileCache {
    pub fn entries(&mut self, path: &Path, parse: impl Fn(&[u8]) -> Option<UsageEntry>) -> Option<&[UsageEntry]> {
        let meta = fs::metadata(path).ok()?;
        let (mtime, size) = (meta.modified().ok()?, meta.len());
        let fresh = self.files.get(path).is_some_and(|(m, s, _)| *m == mtime && *s == size);
        if !fresh {
            let data = fs::read(path).ok()?;
            let entries = data.split(|&b| b == b'\n').filter(|l| l.len() > 20).filter_map(&parse).collect();
            self.files.insert(path.to_path_buf(), (mtime, size, entries));
        }
        self.files.get(path).map(|(_, _, e)| e.as_slice())
    }

    pub fn prune(&mut self, active: &HashSet<PathBuf>) {
        self.files.retain(|k, _| active.contains(k));
    }

    pub fn len(&self) -> usize {
        self.files.len()
    }
}

fn ts(obj: &serde_json::Value, keys: &[&str]) -> Option<DateTime<Utc>> {
    keys.iter()
        .find_map(|k| obj.get(*k).and_then(|v| v.as_str()))
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.with_timezone(&Utc))
}

pub fn parse_claude_line(line: &[u8]) -> Option<UsageEntry> {
    let obj: serde_json::Value = serde_json::from_slice(line).ok()?;
    let msg = obj.get("message")?;
    let u = msg.get("usage")?;
    let date = ts(&obj, &["timestamp", "created_at"])?;
    let key = obj
        .get("requestId")
        .or_else(|| msg.get("id"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let int = |k: &str| u.get(k).and_then(|v| v.as_u64()).unwrap_or(0);
    Some(UsageEntry {
        date,
        key,
        input: int("input_tokens"),
        output: int("output_tokens"),
        cache_write: int("cache_creation_input_tokens"),
        cache_read: int("cache_read_input_tokens"),
    })
}

pub fn parse_agy_line(conv: &str, line: &[u8]) -> Option<UsageEntry> {
    let obj: serde_json::Value = serde_json::from_slice(line).ok()?;
    if obj.get("type").and_then(|v| v.as_str()) != Some("PLANNER_RESPONSE") {
        return None;
    }
    let date = ts(&obj, &["created_at"])?;
    let key = obj.get("step_index").and_then(|v| v.as_i64()).map(|i| format!("{conv}:{i}")).unwrap_or_default();
    let int = |k: &str| obj.get(k).and_then(|v| v.as_u64()).unwrap_or(0);
    Some(UsageEntry {
        date,
        key,
        input: int("input_tokens"),
        output: int("output_tokens"),
        cache_write: int("cache_creation_tokens") + int("cache_write_tokens"),
        cache_read: int("cache_read_tokens"),
    })
}

struct Windows {
    now: DateTime<Utc>,
    five_h_ago: DateTime<Utc>,
    start_of_day: DateTime<Utc>,
    seven_d_ago: DateTime<Utc>,
}

impl Windows {
    fn at(now: DateTime<Utc>) -> Self {
        let local = now.with_timezone(&Local);
        let midnight = local.date_naive().and_hms_opt(0, 0, 0).unwrap();
        let start_of_day = Local
            .from_local_datetime(&midnight)
            .earliest()
            .map(|d| d.with_timezone(&Utc))
            .unwrap_or(now - CDuration::hours(24));
        Self { now, five_h_ago: now - CDuration::hours(5), start_of_day, seven_d_ago: now - CDuration::days(7) }
    }

    fn recent(&self, path: &Path) -> bool {
        fs::metadata(path)
            .and_then(|m| m.modified())
            .map(|t| DateTime::<Utc>::from(t) >= self.seven_d_ago)
            .unwrap_or(false)
    }
}

fn fold(entries: &[UsageEntry], w: &Windows, seen: &mut HashSet<String>, stats: &mut UsageStats) {
    for e in entries {
        if e.date < w.seven_d_ago || e.date > w.now + CDuration::minutes(5) {
            continue;
        }
        if !e.key.is_empty() && !seen.insert(e.key.clone()) {
            continue;
        }
        stats.accumulate(e, w.five_h_ago, w.start_of_day);
    }
}

fn jsonl_in(dir: &Path) -> impl Iterator<Item = PathBuf> {
    fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("jsonl"))
}

pub fn compute_claude(claude_dir: &Path, cache: &mut UsageFileCache, active: &mut HashSet<PathBuf>, now: DateTime<Utc>) -> UsageStats {
    let w = Windows::at(now);
    let mut stats = UsageStats::default();
    let mut seen = HashSet::new();
    let Ok(slugs) = fs::read_dir(claude_dir.join("projects")) else { return stats };
    for slug in slugs.flatten().map(|e| e.path()) {
        let mut files: Vec<PathBuf> = jsonl_in(&slug).collect();
        for sub in fs::read_dir(&slug).into_iter().flatten().flatten().map(|e| e.path()).filter(|p| p.is_dir()) {
            files.extend(jsonl_in(&sub.join("subagents")));
        }
        for f in files.into_iter().filter(|f| w.recent(f)) {
            if let Some(entries) = cache.entries(&f, parse_claude_line) {
                fold(entries, &w, &mut seen, &mut stats);
            }
            active.insert(f);
        }
    }
    stats
}

pub fn compute_commandcode(commandcode_dir: &Path, cache: &mut UsageFileCache, active: &mut HashSet<PathBuf>, now: DateTime<Utc>) -> UsageStats {
    let w = Windows::at(now);
    let mut stats = UsageStats::default();
    let mut seen = HashSet::new();
    let Ok(slugs) = fs::read_dir(commandcode_dir.join("projects")) else { return stats };
    for slug in slugs.flatten().map(|e| e.path()) {
        for f in jsonl_in(&slug).filter(|p| {
            !p.file_name().and_then(|s| s.to_str()).unwrap_or("").contains("checkpoint") && w.recent(p)
        }) {
            if let Some(entries) = cache.entries(&f, commandcode::parse_usage_line) {
                fold(entries, &w, &mut seen, &mut stats);
            }
            active.insert(f);
        }
    }
    stats
}

pub fn compute_cursor(cursor_home: &Path, now: DateTime<Utc>) -> UsageStats {
    let w = Windows::at(now);
    let mut stats = UsageStats::default();
    let mut seen = HashSet::new();
    fold(&cursor::request_entries(cursor_home), &w, &mut seen, &mut stats);
    stats
}

pub fn compute_agy(gemini_dir: &Path, cache: &mut UsageFileCache, active: &mut HashSet<PathBuf>, now: DateTime<Utc>) -> UsageStats {
    let w = Windows::at(now);
    let mut stats = UsageStats::default();
    let mut seen = HashSet::new();
    for root in antigravity::roots(gemini_dir) {
        let Ok(convs) = fs::read_dir(root.join("brain")) else { continue };
        for conv in convs.flatten().map(|e| e.path()) {
            let id = conv.file_name().and_then(|s| s.to_str()).unwrap_or_default().to_string();
            let f = conv.join(".system_generated/logs/transcript.jsonl");
            if !w.recent(&f) {
                continue;
            }
            if let Some(entries) = cache.entries(&f, |l| parse_agy_line(&id, l)) {
                fold(entries, &w, &mut seen, &mut stats);
            }
            active.insert(f);
        }
    }
    stats
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct OAuthUsage {
    pub five_hour_percent: Option<f64>,
    pub five_hour_resets_at: Option<DateTime<Utc>>,
    pub seven_day_percent: Option<f64>,
    pub seven_day_resets_at: Option<DateTime<Utc>>,
}

pub fn read_credentials_token(claude_dir: &Path) -> Option<String> {
    let raw = fs::read_to_string(claude_dir.join(".credentials.json")).ok()?;
    let v: serde_json::Value = serde_json::from_str(&raw).ok()?;
    let t = v.get("claudeAiOauth")?.get("accessToken")?.as_str()?;
    (!t.is_empty()).then(|| t.to_string())
}

pub fn parse_oauth(obj: &serde_json::Value) -> OAuthUsage {
    let window = |k: &str| {
        let w = obj.get(k);
        let pct = w.and_then(|w| w.get("utilization")).and_then(|v| v.as_f64());
        let at = w.and_then(|w| ts(w, &["resets_at"]));
        (pct, at)
    };
    let (fh, fha) = window("five_hour");
    let (sd, sda) = window("seven_day");
    OAuthUsage { five_hour_percent: fh, five_hour_resets_at: fha, seven_day_percent: sd, seven_day_resets_at: sda }
}

fn fetch_commandcode_live(token: &str) -> Option<(Option<f64>, Option<DateTime<Utc>>, Option<f64>, Option<DateTime<Utc>>)> {
    let resp = crate::platform::http::agent()
        .get("https://api.commandcode.ai/alpha/usage/summary")
        .timeout(Duration::from_secs(5))
        .set("Authorization", &format!("Bearer {token}"))
        .set("Accept", "application/json")
        .call()
        .ok()?;
    let obj: serde_json::Value = resp.into_json().ok()?;
    Some(commandcode::parse_live_windows(&obj))
}

fn fetch_oauth(token: &str) -> Option<OAuthUsage> {
    let resp = crate::platform::http::agent()
        .get("https://api.anthropic.com/api/oauth/usage")
        .timeout(Duration::from_secs(5))
        .set("Authorization", &format!("Bearer {token}"))
        .set("anthropic-beta", "oauth-2025-04-20")
        .call()
        .ok()?;
    let obj: serde_json::Value = resp.into_json().ok()?;
    Some(parse_oauth(&obj))
}

static REFRESH: OnceLock<Mutex<mpsc::Sender<()>>> = OnceLock::new();

/// Ask the usage worker to recompute now (instead of waiting for the 45s tick).
pub fn refresh_now() {
    if let Some(tx) = REFRESH.get() {
        let _ = tx.lock().map(|t| t.send(()));
    }
}

pub fn spawn(
    ctx: egui::Context,
    claude_dir: PathBuf,
    gemini_dir: PathBuf,
    cursor_home: PathBuf,
    commandcode_dir: PathBuf,
) -> watch::Receiver<UsageSnapshot> {
    let (tx, rx) = watch::channel(UsageSnapshot::default());
    let (rtx, rrx) = mpsc::channel();
    let _ = REFRESH.set(Mutex::new(rtx));
    let _ = std::thread::Builder::new().name("usage".into()).spawn(move || {
        let mut cache = UsageFileCache::default();
        loop {
            let now = Utc::now();
            let mut active = HashSet::new();
            let mut claude = compute_claude(&claude_dir, &mut cache, &mut active, now);
            let agy = compute_agy(&gemini_dir, &mut cache, &mut active, now);
            let cursor = compute_cursor(&cursor_home, now);
            let mut commandcode = compute_commandcode(&commandcode_dir, &mut cache, &mut active, now);
            cache.prune(&active);
            if let Some(o) = read_credentials_token(&claude_dir).and_then(|t| fetch_oauth(&t)) {
                claude.live_five_hour_percent = o.five_hour_percent;
                claude.live_five_hour_resets_at = o.five_hour_resets_at;
                claude.live_seven_day_percent = o.seven_day_percent;
                claude.live_seven_day_resets_at = o.seven_day_resets_at;
            }
            let mut cc_live = false;
            if let Some((fh, fha, sd, sda)) = commandcode::read_api_key(&commandcode_dir).and_then(|t| fetch_commandcode_live(&t)) {
                commandcode.live_five_hour_percent = fh;
                commandcode.live_five_hour_resets_at = fha;
                commandcode.live_seven_day_percent = sd;
                commandcode.live_seven_day_resets_at = sda;
                cc_live = fh.is_some() || sd.is_some();
            }
            let oauth_connected = claude.live_five_hour_percent.is_some() || claude.live_seven_day_percent.is_some();
            let _ = tx.send(UsageSnapshot { claude, agy, cursor, commandcode, oauth_connected, cc_live });
            ctx.request_repaint();
            if tx.is_closed() {
                break;
            }
            let _ = rrx.recv_timeout(Duration::from_secs(45));
        }
    });
    rx
}

/// "resets 2h 14m" style label.
pub fn reset_text(at: Option<DateTime<Utc>>) -> Option<String> {
    let secs = (at? - Utc::now()).num_seconds();
    if secs <= 0 {
        return None;
    }
    let (h, m) = (secs / 3600, (secs % 3600) / 60);
    Some(if h >= 24 {
        format!("resets {}d {}h", h / 24, h % 24)
    } else if h > 0 {
        format!("resets {h}h {m}m")
    } else {
        format!("resets {}m", m.max(1))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("bn-usage-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn effective_weights_cache_reads_at_tenth() {
        let b = Bucket { input: 100, output: 50, cache_write: 200, cache_read: 1000 };
        assert_eq!(b.effective(), 100 + 200 + 100 + 50);
    }

    #[test]
    fn claude_windows_dedupe_and_cache_reuse() {
        let root = tmpdir("claude");
        let proj = root.join("projects/-home-x");
        fs::create_dir_all(proj.join("s1/subagents")).unwrap();
        let now = Utc::now();
        let line = |id: &str, ago: CDuration, inp: u64| {
            format!(
                r#"{{"requestId":"{id}","timestamp":"{}","message":{{"usage":{{"input_tokens":{inp},"output_tokens":10,"cache_read_input_tokens":100}}}}}}"#,
                (now - ago).to_rfc3339()
            )
        };
        let mut f = fs::File::create(proj.join("s1.jsonl")).unwrap();
        writeln!(f, "{}", line("a", CDuration::minutes(10), 100)).unwrap();
        writeln!(f, "{}", line("b", CDuration::hours(30), 1000)).unwrap();
        writeln!(f, "{}", line("old", CDuration::days(9), 5000)).unwrap();
        // Same request mirrored into a subagent transcript must not double count.
        let mut s = fs::File::create(proj.join("s1/subagents/agent-1.jsonl")).unwrap();
        writeln!(s, "{}", line("a", CDuration::minutes(10), 100)).unwrap();

        let mut cache = UsageFileCache::default();
        let mut active = HashSet::new();
        let st = compute_claude(&root, &mut cache, &mut active, now);
        assert_eq!(st.session.input, 100);
        assert_eq!(st.weekly.input, 1100);
        assert_eq!(st.session.effective(), 100 + 10 + 10);
        assert_eq!(cache.len(), 2);
        let again = compute_claude(&root, &mut cache, &mut active, now);
        assert_eq!(again, st);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn agy_entries_parse() {
        let e = parse_agy_line(
            "c1",
            br#"{"type":"PLANNER_RESPONSE","step_index":3,"created_at":"2026-10-25T10:00:00Z","input_tokens":5,"output_tokens":6,"cache_write_tokens":7,"cache_read_tokens":80}"#,
        )
        .unwrap();
        assert_eq!((e.key.as_str(), e.input, e.output, e.cache_write, e.cache_read), ("c1:3", 5, 6, 7, 80));
    }

    #[test]
    fn oauth_payload_parses() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"five_hour":{"utilization":62.5,"resets_at":"2026-10-25T12:00:00.123Z"},"seven_day":{"utilization":10}}"#,
        )
        .unwrap();
        let o = parse_oauth(&v);
        assert_eq!(o.five_hour_percent, Some(62.5));
        assert!(o.five_hour_resets_at.is_some());
        assert_eq!(o.seven_day_percent, Some(10.0));
        assert!(o.seven_day_resets_at.is_none());
    }

    #[test]
    fn commandcode_windows_from_jsonl() {
        let root = tmpdir("cc");
        let proj = root.join("projects/demo");
        fs::create_dir_all(&proj).unwrap();
        let now = Utc::now();
        let line = format!(
            r#"{{"type":"message","id":"x1","timestamp":"{}","usage":{{"inputTokens":40,"outputTokens":5,"cacheReadTokens":20,"cacheWriteTokens":0}}}}"#,
            (now - CDuration::minutes(3)).to_rfc3339()
        );
        fs::write(proj.join("s.jsonl"), format!("{line}\n")).unwrap();
        let mut cache = UsageFileCache::default();
        let mut active = HashSet::new();
        let st = compute_commandcode(&root, &mut cache, &mut active, now);
        assert_eq!(st.session.input, 40);
        assert_eq!(st.session.output, 5);
        let _ = fs::remove_dir_all(&root);
    }
}
