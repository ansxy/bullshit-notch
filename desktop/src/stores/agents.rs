use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Harness {
    #[default]
    Claude,
    Antigravity,
}

impl Harness {
    pub fn tag(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Antigravity => "agy",
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Agent {
    #[serde(default)]
    pub harness: Harness,
    pub pid: i32,
    pub session_id: String,
    pub cwd: String,
    pub name: Option<String>,
    pub status: Option<String>,
    pub started_at: f64,
    pub status_updated_at: Option<f64>,
}

impl Agent {
    pub fn id(&self) -> String {
        format!("{}-{}", self.harness.tag(), self.session_id)
    }

    pub fn face(status: Option<&str>, frame: usize) -> &'static str {
        const BUSY: [&str; 6] = [
            "[o_o]   ", "[o_o].  ", "[o_o].. ", "[o_o]...", "[-_o]...", "[o_o]...",
        ];
        const WAITING: [&str; 2] = ["[O_O] ? ", "[O_O]   "];
        const IDLE: [&str; 3] = ["[-_-] z ", "[-_-] zZ", "[-_-] zZ"];
        match status {
            Some("busy") => BUSY[frame % BUSY.len()],
            Some("waiting") => WAITING[(frame / 3) % WAITING.len()],
            _ => IDLE[(frame / 3) % IDLE.len()],
        }
    }
}

#[derive(Debug, Clone)]
pub struct SubAgent {
    pub id: String,
    pub description: String,
    pub agent_type: String,
    pub finished: bool,
    pub tokens: (u64, u64),
}

#[derive(Debug, Clone, Default)]
pub struct AgentSnapshot {
    pub agents: Vec<Agent>,
    pub tokens: HashMap<String, (u64, u64)>,
    pub subagents: HashMap<String, Vec<SubAgent>>,
}

impl AgentSnapshot {
    pub fn busy_count(&self) -> usize {
        self.agents
            .iter()
            .filter(|a| a.status.as_deref() == Some("busy"))
            .count()
    }

    pub fn demo() -> Self {
        let now_ms = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_millis() as f64)
            .unwrap_or(0.0);
        let mut snap = Self::default();
        snap.agents = vec![
            Agent {
                harness: Harness::Claude,
                pid: 42069,
                session_id: "demo-1".into(),
                cwd: "/home/dev/work/bullshit-notch".into(),
                name: Some("Add Doom fire & 8 notch animations".into()),
                status: Some("busy".into()),
                started_at: now_ms - 220_000.0,
                status_updated_at: Some(now_ms - 12_000.0),
            },
            Agent {
                harness: Harness::Claude,
                pid: 42071,
                session_id: "demo-3".into(),
                cwd: "/home/dev/work/prod-cluster".into(),
                name: Some("Fix Friday afternoon deploy script".into()),
                status: Some("waiting".into()),
                started_at: now_ms - 640_000.0,
                status_updated_at: Some(now_ms - 45_000.0),
            },
        ];
        snap.tokens.insert("demo-1".into(), (142_000, 48_500));
        snap.tokens.insert("demo-3".into(), (210_000, 64_000));
        snap
    }
}

#[derive(Debug, Default, Clone)]
struct Parsed {
    offset: u64,
    usage: HashMap<String, (u64, u64)>,
    finished: HashSet<String>,
}

impl Parsed {
    fn total(&self) -> (u64, u64) {
        self.usage
            .values()
            .fold((0, 0), |acc, v| (acc.0 + v.0, acc.1 + v.1))
    }
}

#[derive(Debug, Default)]
pub struct AgentParseState {
    parsed: HashMap<PathBuf, Parsed>,
}

impl AgentParseState {
    pub fn parse_claude_jsonl(&mut self, path: &Path) -> (u64, u64) {
        let entry = self.parse(path);
        entry.total()
    }

    fn parse(&mut self, path: &Path) -> Parsed {
        let mut entry = self.parsed.remove(path).unwrap_or_default();
        let Ok(mut file) = File::open(path) else {
            self.parsed.insert(path.to_path_buf(), entry.clone());
            return entry;
        };
        if file.seek(SeekFrom::Start(entry.offset)).is_err() {
            self.parsed.insert(path.to_path_buf(), entry.clone());
            return entry;
        }
        let mut data = Vec::new();
        if file.read_to_end(&mut data).is_err() {
            self.parsed.insert(path.to_path_buf(), entry.clone());
            return entry;
        }
        // Only consume complete lines; half-written last line waits for next poll.
        if let Some(end) = data.iter().rposition(|&b| b == b'\n') {
            for line in data[..=end].split(|&b| b == b'\n') {
                if !line.is_empty() {
                    read_line(line, &mut entry);
                }
            }
            entry.offset += (end as u64) + 1;
        }
        let total = entry.clone();
        self.parsed.insert(path.to_path_buf(), entry);
        total
    }
}

fn read_line(line: &[u8], entry: &mut Parsed) {
    let text = String::from_utf8_lossy(line);
    for chunk in text.split("<task-id>").skip(1) {
        if let Some(id) = chunk.split('<').next() {
            entry.finished.insert(id.to_string());
        }
    }
    let Ok(obj) = serde_json::from_slice::<serde_json::Value>(line) else {
        return;
    };
    let Some(message) = obj.get("message") else {
        return;
    };
    if let Some(content) = message.get("content").and_then(|c| c.as_array()) {
        for item in content {
            if item.get("type").and_then(|t| t.as_str()) == Some("tool_result") {
                if let Some(id) = item.get("tool_use_id").and_then(|v| v.as_str()) {
                    let content_str = item
                        .get("content")
                        .map(|c| c.to_string())
                        .unwrap_or_default();
                    if !content_str.contains("Async agent launched") {
                        entry.finished.insert(id.to_string());
                    }
                }
            }
        }
    }
    let Some(u) = message.get("usage") else {
        return;
    };
    let key = obj
        .get("requestId")
        .and_then(|v| v.as_str())
        .or_else(|| message.get("id").and_then(|v| v.as_str()))
        .unwrap_or("anon")
        .to_string();
    let int = |k: &str| u.get(k).and_then(|v| v.as_u64()).unwrap_or(0);
    let input = int("input_tokens")
        + int("cache_creation_input_tokens")
        + int("cache_read_input_tokens") / 10;
    let output = int("output_tokens");
    entry.usage.insert(key, (input, output));
}

fn pid_alive(pid: i32) -> bool {
    if pid <= 0 {
        return false;
    }
    #[cfg(unix)]
    {
        libc_kill(pid, 0) == 0
    }
    #[cfg(windows)]
    {
        windows_pid_alive(pid as u32)
    }
    #[cfg(not(any(unix, windows)))]
    {
        true
    }
}

#[cfg(unix)]
fn libc_kill(pid: i32, sig: i32) -> i32 {
    extern "C" {
        fn kill(pid: i32, sig: i32) -> i32;
    }
    unsafe { kill(pid, sig) }
}

#[cfg(windows)]
fn windows_pid_alive(pid: u32) -> bool {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    const STILL_ACTIVE: u32 = 259;
    unsafe {
        let Ok(handle) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return false;
        };
        let mut code = 0u32;
        let ok = GetExitCodeProcess(handle, &mut code).is_ok();
        let _ = CloseHandle(handle);
        ok && code == STILL_ACTIVE
    }
}

fn slugify_cwd(cwd: &str) -> String {
    cwd.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// Refresh Claude sessions from `~/.claude` (or provided root for tests).
pub fn refresh_from_dirs(claude_dir: &Path, state: &mut AgentParseState) -> AgentSnapshot {
    let sessions_dir = claude_dir.join("sessions");
    let mut snap = AgentSnapshot::default();
    let Ok(entries) = fs::read_dir(&sessions_dir) else {
        return snap;
    };

    let mut active_session_ids: HashSet<String> = HashSet::new();
    let mut active_urls: HashSet<PathBuf> = HashSet::new();
    let mut agents = Vec::new();

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(raw) = fs::read_to_string(&path) else {
            continue;
        };
        let Ok(mut agent) = serde_json::from_str::<Agent>(&raw) else {
            continue;
        };
        agent.harness = Harness::Claude;
        if !pid_alive(agent.pid) {
            continue;
        }
        active_session_ids.insert(agent.session_id.clone());
        let slug = slugify_cwd(&agent.cwd);
        let project = claude_dir.join("projects").join(&slug);
        let main_url = project.join(format!("{}.jsonl", agent.session_id));
        active_urls.insert(main_url.clone());
        let main = state.parse(&main_url);
        let mut finished = main.finished.clone();
        let subs = load_subagents(
            &project.join(&agent.session_id),
            &mut finished,
            state,
            &mut active_urls,
        );
        let mut total = main.total();
        for s in &subs {
            total.0 += s.tokens.0;
            total.1 += s.tokens.1;
        }
        snap.tokens.insert(agent.session_id.clone(), total);
        snap.subagents.insert(agent.session_id.clone(), subs);
        agents.push(agent);
    }

    state.parsed.retain(|k, _| active_urls.contains(k));
    agents.sort_by(|a, b| {
        b.started_at
            .partial_cmp(&a.started_at)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    snap.agents = agents;
    let _ = active_session_ids;
    snap
}

fn load_subagents(
    session_dir: &Path,
    finished: &mut HashSet<String>,
    state: &mut AgentParseState,
    active_urls: &mut HashSet<PathBuf>,
) -> Vec<SubAgent> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Meta {
        agent_type: Option<String>,
        description: Option<String>,
        tool_use_id: Option<String>,
        stopped_by_user: Option<bool>,
    }

    let dir = session_dir.join("subagents");
    let Ok(entries) = fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
            continue;
        }
        active_urls.insert(path.clone());
        let name = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("agent-unknown");
        let id = name.strip_prefix("agent-").unwrap_or(name).to_string();
        let meta: Option<Meta> = fs::read_to_string(dir.join(format!("{name}.meta.json")))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok());
        let parsed = state.parse(&path);
        let tool_id = meta
            .as_ref()
            .and_then(|m| m.tool_use_id.clone())
            .unwrap_or_else(|| "-".into());
        let done = finished.contains(&id)
            || finished.contains(&tool_id)
            || meta.as_ref().and_then(|m| m.stopped_by_user) == Some(true);
        out.push(SubAgent {
            id,
            description: meta
                .as_ref()
                .and_then(|m| m.description.clone())
                .unwrap_or_else(|| name.to_string()),
            agent_type: meta
                .as_ref()
                .and_then(|m| m.agent_type.clone())
                .unwrap_or_else(|| "agent".into()),
            finished: done,
            tokens: parsed.total(),
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn incremental_claude_transcript_handles_partial_lines_and_dedupes_request_id() {
        let tmp = std::env::temp_dir().join(format!(
            "bn-test-{}",
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();
        let file = tmp.join("session-1.jsonl");

        let line1 = r#"{"requestId":"req_1","timestamp":"2026-10-20T08:00:00Z","message":{"usage":{"input_tokens":100,"cache_creation_input_tokens":50,"cache_read_input_tokens":1000,"output_tokens":40},"content":[]}}"#;
        let partial = r#"{"requestId":"req_2","message":{"usage":{"input_tokens":500"#;
        {
            let mut f = File::create(&file).unwrap();
            write!(f, "{}\n{}", line1, partial).unwrap();
        }

        let mut state = AgentParseState::default();
        let parsed1 = state.parse_claude_jsonl(&file);
        // 100 + 50 + 1000/10 = 250 input, 40 output; partial ignored
        assert_eq!(parsed1, (250, 40));

        let rest = r#","output_tokens":60}}}"#;
        {
            let mut f = File::create(&file).unwrap();
            write!(f, "{}\n{}{}\n{}\n", line1, partial, rest, line1).unwrap();
        }
        // File was rewritten from scratch; reset offset for this test path.
        // Real Claude appends; rewrite simulates corrupt reset — clear cache.
        state.parsed.clear();
        let parsed2 = state.parse_claude_jsonl(&file);
        // req_1 once (dedupe) = 250/40; req_2 = 500/60 → 750/100
        assert_eq!(parsed2, (750, 100));
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn agent_face_cycles_busy() {
        assert_eq!(Agent::face(Some("busy"), 0), "[o_o]   ");
        assert_eq!(Agent::face(Some("busy"), 1), "[o_o].  ");
    }
}
