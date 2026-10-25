//! Next-meeting + local tasks. Meeting-URL detector ports `Sources/Agenda.swift`.
//! ponytail: no Outlook/EventKit on Win/Linux — `.ics` files + a tasks list.

use chrono::{DateTime, Duration as CDuration, NaiveDate, NaiveDateTime, NaiveTime, Utc};
use std::fs;
use std::path::{Path, PathBuf};
use tokio::sync::watch;

const MEETING_HOSTS: &[&str] = &[
    "zoom.us",
    "meet.google.com",
    "teams.microsoft.com",
    "teams.live.com",
    "webex.com",
    "whereby.com",
    "around.co",
    "facetime.apple.com",
    "chime.aws",
    "gotomeeting.com",
    "meet.jit.si",
    "slack.com/huddle",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgendaEvent {
    pub title: String,
    pub start: DateTime<Utc>,
    pub end: Option<DateTime<Utc>>,
    pub location: Option<String>,
    pub notes: Option<String>,
    pub url: Option<String>,
}

impl AgendaEvent {
    pub fn meeting_link(&self) -> Option<String> {
        meeting_link(
            [
                self.url.as_deref(),
                self.location.as_deref(),
                self.notes.as_deref(),
            ]
            .into_iter()
            .flatten(),
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskItem {
    pub title: String,
    pub done: bool,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct AgendaSnapshot {
    pub events: Vec<AgendaEvent>,
    pub tasks: Vec<TaskItem>,
}

impl AgendaSnapshot {
    pub fn next_meeting(&self, now: DateTime<Utc>) -> Option<&AgendaEvent> {
        let upcoming: Vec<&AgendaEvent> = self.events.iter().filter(|e| e.end.unwrap_or(e.start) >= now).collect();
        upcoming
            .iter()
            .copied()
            .find(|e| e.meeting_link().is_some())
            .or_else(|| upcoming.first().copied())
    }

    pub fn demo() -> Self {
        let now = Utc::now();
        Self {
            events: vec![AgendaEvent {
                title: "Yolo prod Friday".into(),
                start: now + CDuration::minutes(42),
                end: Some(now + CDuration::minutes(72)),
                location: Some("https://meet.google.com/yolo-prod-friday".into()),
                notes: None,
                url: None,
            }],
            tasks: vec![
                TaskItem { title: "Ship desktop port".into(), done: false },
                TaskItem { title: "Review agents fire".into(), done: true },
            ],
        }
    }
}

/// First known call-host URL in the candidate texts.
pub fn meeting_link<'a>(texts: impl IntoIterator<Item = &'a str>) -> Option<String> {
    for text in texts {
        for token in text.split_whitespace() {
            let url = token.trim_matches(|c: char| "<>()[],.;\"'".contains(c));
            if !url.starts_with("http://") && !url.starts_with("https://") {
                continue;
            }
            if MEETING_HOSTS.iter().any(|h| url.contains(h)) {
                return Some(url.to_string());
            }
        }
    }
    None
}

/// Best-effort VEVENT scrape. Unfolds RFC 5545 line continuations.
pub fn parse_ics(raw: &str) -> Vec<AgendaEvent> {
    let unfolded = unfold_ics(raw);
    let mut out = Vec::new();
    let mut cur: Option<AgendaEvent> = None;
    for line in unfolded.lines() {
        if line == "BEGIN:VEVENT" {
            cur = Some(AgendaEvent {
                title: "Event".into(),
                start: Utc::now(),
                end: None,
                location: None,
                notes: None,
                url: None,
            });
            continue;
        }
        let Some(ev) = cur.as_mut() else { continue };
        if line == "END:VEVENT" {
            if let Some(done) = cur.take() {
                out.push(done);
            }
            continue;
        }
        if let Some(v) = ics_value(line, "SUMMARY") {
            ev.title = unescape_ics(&v);
        } else if let Some(v) = ics_dt(line, "DTSTART") {
            ev.start = v;
        } else if let Some(v) = ics_dt(line, "DTEND") {
            ev.end = Some(v);
        } else if let Some(v) = ics_value(line, "LOCATION") {
            ev.location = Some(unescape_ics(&v));
        } else if let Some(v) = ics_value(line, "DESCRIPTION") {
            ev.notes = Some(unescape_ics(&v));
        } else if let Some(v) = ics_value(line, "URL") {
            ev.url = Some(v);
        }
    }
    out
}

fn unfold_ics(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for line in raw.lines() {
        if line.starts_with(' ') || line.starts_with('\t') {
            out.push_str(line.trim_start());
        } else {
            if !out.is_empty() {
                out.push('\n');
            }
            out.push_str(line);
        }
    }
    out
}

fn ics_value(line: &str, key: &str) -> Option<String> {
    let (head, rest) = line.split_once(':')?;
    if head == key || head.starts_with(&format!("{key};")) {
        Some(rest.to_string())
    } else {
        None
    }
}

fn ics_dt(line: &str, key: &str) -> Option<DateTime<Utc>> {
    let v = ics_value(line, key)?;
    parse_ics_dt(&v)
}

pub fn parse_ics_dt(v: &str) -> Option<DateTime<Utc>> {
    let v = v.trim();
    if let Ok(d) = DateTime::parse_from_rfc3339(v) {
        return Some(d.with_timezone(&Utc));
    }
    if v.ends_with('Z') {
        if let Ok(d) = NaiveDateTime::parse_from_str(v, "%Y%m%dT%H%M%SZ") {
            return Some(d.and_utc());
        }
    }
    if let Ok(d) = NaiveDateTime::parse_from_str(v, "%Y%m%dT%H%M%S") {
        return Some(d.and_utc());
    }
    if let Ok(d) = NaiveDate::parse_from_str(v, "%Y%m%d") {
        return Some(d.and_time(NaiveTime::MIN).and_utc());
    }
    None
}

fn unescape_ics(s: &str) -> String {
    s.replace("\\n", "\n").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")
}

fn calendar_roots() -> Vec<PathBuf> {
    let home = directories::UserDirs::new().map(|u| u.home_dir().to_path_buf()).unwrap_or_else(|| PathBuf::from("."));
    vec![
        home.join("Calendar"),
        home.join(".calendars"),
        home.join(".local/share/evolution/calendar"),
        home.join(".local/share/thunderbird"),
        home.join("Documents"),
    ]
}

fn collect_ics(dir: &Path, out: &mut Vec<PathBuf>, depth: u8) {
    if depth == 0 {
        return;
    }
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            collect_ics(&p, out, depth - 1);
        } else if p.extension().and_then(|e| e.to_str()) == Some("ics") {
            out.push(p);
        }
    }
}

fn load_tasks() -> Vec<TaskItem> {
    let Some(dir) = directories::ProjectDirs::from("com", "ansxy", "BullshitNotch") else {
        return Vec::new();
    };
    let path = dir.data_dir().join("tasks.json");
    let Ok(raw) = fs::read_to_string(path) else {
        return Vec::new();
    };
    serde_json::from_str::<Vec<(String, bool)>>(&raw)
        .unwrap_or_default()
        .into_iter()
        .map(|(title, done)| TaskItem { title, done })
        .collect()
}

pub fn refresh() -> AgendaSnapshot {
    let mut events = Vec::new();
    let mut files = Vec::new();
    for root in calendar_roots() {
        collect_ics(&root, &mut files, 3);
    }
    files.sort();
    files.dedup();
    for f in files.into_iter().take(40) {
        if let Ok(raw) = fs::read_to_string(f) {
            events.extend(parse_ics(&raw));
        }
    }
    events.sort_by_key(|e| e.start);
    AgendaSnapshot { events, tasks: load_tasks() }
}

pub fn spawn(ctx: egui::Context, demo: bool) -> watch::Receiver<AgendaSnapshot> {
    if demo {
        return super::fixed(AgendaSnapshot::demo());
    }
    let init = refresh();
    super::spawn_poller(ctx, "agenda", std::time::Duration::from_secs(60), init, || || Some(refresh()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn meeting_hosts_only() {
        assert_eq!(
            meeting_link(["standup in https://meet.google.com/abc-defg-hij notes"]),
            Some("https://meet.google.com/abc-defg-hij".into())
        );
        assert_eq!(meeting_link(["see https://example.com/not-a-call"]), None);
        assert_eq!(
            meeting_link(["https://teams.microsoft.com/l/meetup-join/x"]),
            Some("https://teams.microsoft.com/l/meetup-join/x".into())
        );
    }

    #[test]
    fn ics_unfold_and_dtstart() {
        let raw = "BEGIN:VEVENT\nSUMMARY:Standup\nDTSTART:20261025T090000Z\nLOCATION:https://zoom.us/j/1\nDESCRIPTION:Bring notes\n  and coffee\nEND:VEVENT\n";
        let evs = parse_ics(raw);
        assert_eq!(evs.len(), 1);
        assert_eq!(evs[0].title, "Standup");
        assert_eq!(evs[0].start.to_rfc3339(), "2026-10-25T09:00:00+00:00");
        assert_eq!(evs[0].meeting_link().as_deref(), Some("https://zoom.us/j/1"));
        assert!(evs[0].notes.as_deref().unwrap().contains("coffee"));
    }

    #[test]
    fn next_meeting_prefers_link() {
        let now = Utc::now();
        let snap = AgendaSnapshot {
            events: vec![
                AgendaEvent {
                    title: "Lunch".into(),
                    start: now + CDuration::minutes(10),
                    end: None,
                    location: None,
                    notes: None,
                    url: None,
                },
                AgendaEvent {
                    title: "Sync".into(),
                    start: now + CDuration::minutes(20),
                    end: None,
                    location: Some("https://meet.google.com/zzz".into()),
                    notes: None,
                    url: None,
                },
            ],
            tasks: vec![],
        };
        assert_eq!(snap.next_meeting(now).map(|e| e.title.as_str()), Some("Sync"));
    }
}
