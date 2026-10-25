//! GitHub PRs via `gh search prs` (port of `Sources/PullRequest.swift`).

use crate::platform::process::run_hidden_sync;
use serde::Deserialize;
use std::sync::{Mutex, OnceLock};
use tokio::sync::watch;

static TX: OnceLock<Mutex<watch::Sender<GithubSnapshot>>> = OnceLock::new();

pub fn refresh_now() {
    if let Some(tx) = TX.get() {
        if let Ok(tx) = tx.lock() {
            let _ = tx.send(refresh());
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequest {
    pub number: i64,
    pub title: String,
    pub url: String,
    pub repository: Repository,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Repository {
    pub name_with_owner: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PrList {
    #[default]
    Mine,
    Review,
}

impl PrList {
    pub const ALL: [PrList; 2] = [PrList::Mine, PrList::Review];

    pub fn label(self) -> &'static str {
        match self {
            Self::Mine => "Mine",
            Self::Review => "To Review",
        }
    }

    pub fn filter(self) -> &'static str {
        match self {
            Self::Mine => "--author=@me",
            Self::Review => "--review-requested=@me",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct GithubSnapshot {
    pub mine: Vec<PullRequest>,
    pub review: Vec<PullRequest>,
    pub error: Option<String>,
}

impl GithubSnapshot {
    pub fn demo() -> Self {
        let pr = |n, title: &str, repo: &str| PullRequest {
            number: n,
            title: title.into(),
            url: format!("https://github.com/{repo}/pull/{n}"),
            repository: Repository { name_with_owner: repo.into() },
            updated_at: "2026-10-25T10:00:00Z".into(),
        };
        Self {
            mine: vec![pr(12, "feat: desktop notch overlay", "ansxy/bullshit-notch")],
            review: vec![pr(7, "fix: hover leave gate", "ansxy/bullshit-notch")],
            error: None,
        }
    }

    pub fn list(&self, which: PrList) -> &[PullRequest] {
        match which {
            PrList::Mine => &self.mine,
            PrList::Review => &self.review,
        }
    }
}

pub fn search_prs(filter: &str) -> Result<Vec<PullRequest>, String> {
    let out = run_hidden_sync(
        "gh",
        &["search", "prs", filter, "--state=open", "--json", "number,title,url,repository,updatedAt", "--limit", "20"],
    )
    .map_err(|e| e.to_string())?;
    if out.status != 0 {
        return Err(if out.stderr.is_empty() { "gh search failed".into() } else { out.stderr.trim().into() });
    }
    serde_json::from_str(&out.stdout).map_err(|e| e.to_string())
}

pub fn refresh() -> GithubSnapshot {
    match (search_prs(PrList::Mine.filter()), search_prs(PrList::Review.filter())) {
        (Ok(mine), Ok(review)) => GithubSnapshot { mine, review, error: None },
        (Err(e), Ok(review)) => GithubSnapshot { mine: vec![], review, error: Some(e) },
        (Ok(mine), Err(e)) => GithubSnapshot { mine, review: vec![], error: Some(e) },
        (Err(e), Err(_)) => GithubSnapshot { error: Some(e), ..Default::default() },
    }
}

pub fn spawn(ctx: egui::Context, demo: bool) -> watch::Receiver<GithubSnapshot> {
    if demo {
        return super::fixed(GithubSnapshot::demo());
    }
    let (tx, rx) = watch::channel(GithubSnapshot::default());
    let _ = TX.set(Mutex::new(tx.clone()));
    let _ = std::thread::Builder::new().name("github".into()).spawn(move || loop {
        let snap = refresh();
        let _ = tx.send(snap);
        ctx.request_repaint();
        if tx.is_closed() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_secs(90));
    });
    rx
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_gh_json() {
        let raw = r#"[{"number":3,"title":"hi","url":"https://github.com/a/b/pull/3","repository":{"nameWithOwner":"a/b"},"updatedAt":"2026-01-01T00:00:00Z"}]"#;
        let prs: Vec<PullRequest> = serde_json::from_str(raw).unwrap();
        assert_eq!(prs[0].repository.name_with_owner, "a/b");
        assert_eq!(prs[0].number, 3);
    }
}
