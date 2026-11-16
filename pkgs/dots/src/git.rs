//! Thin git queries. The repo and the private wrapper are both git repos, and
//! their state relative to the recorded baseline is the first thing a deploy
//! must show.

use crate::cmd;
use std::path::{Path, PathBuf};

pub fn is_repo(repo: &Path) -> bool {
    repo.join(".git").exists()
}

fn git(repo: &Path, args: &[&str]) -> Option<String> {
    let mut full: Vec<String> = vec!["-C".to_string(), repo.display().to_string()];
    full.extend(args.iter().map(|a| a.to_string()));
    cmd::run("git", &full)
        .ok()
        .filter(|o| o.ok())
        .map(|o| o.stdout)
}

pub fn head(repo: &Path) -> Option<String> {
    git(repo, &["rev-parse", "HEAD"]).map(|s| s.trim().to_string())
}

pub fn short_head(repo: &Path) -> Option<String> {
    head(repo).map(|h| h.chars().take(7).collect())
}

pub fn rev_exists(repo: &Path, rev: &str) -> bool {
    git(repo, &["cat-file", "-e", &format!("{rev}^{{commit}}")]).is_some()
}

pub fn status_porcelain(repo: &Path) -> Option<String> {
    git(repo, &["status", "--porcelain"])
}

pub fn log_oneline(repo: &Path, range: &str) -> Option<String> {
    git(repo, &["log", "--oneline", "--no-decorate", range])
}

pub fn diff_stat(repo: &Path, base: &str) -> Option<String> {
    git(repo, &["diff", "--stat", base])
}

/// Files tracked by git plus untracked-but-not-ignored ones. Submodule
/// contents are not listed, so a submodule cannot smuggle a file into a scan
/// of "this repo".
pub fn files(repo: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let args: Vec<String> = vec![
        "-C".into(),
        repo.display().to_string(),
        "ls-files".into(),
        "-z".into(),
        "--cached".into(),
        "--others".into(),
        "--exclude-standard".into(),
    ];
    if let Ok(o) = cmd::run("git", &args) {
        if o.ok() {
            for rel in o.stdout.split('\0').filter(|s| !s.is_empty()) {
                out.push(repo.join(rel));
            }
        }
    }
    out
}

/// Count the dirty entries in a `git status --porcelain` listing.
pub fn dirty_count(status: &str) -> usize {
    status.lines().filter(|l| !l.trim().is_empty()).count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dirty_count_ignores_blank_lines() {
        assert_eq!(dirty_count(""), 0);
        assert_eq!(dirty_count("\n\n"), 0);
        assert_eq!(dirty_count(" M base/system.nix\n?? new.nix\n"), 2);
    }

    #[test]
    fn repo_detection() {
        let dir = std::env::temp_dir().join(format!("dots-git-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        assert!(!is_repo(&dir));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        assert!(is_repo(&dir));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
