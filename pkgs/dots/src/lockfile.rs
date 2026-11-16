//! `flake.lock` reading: node diffs between the current lock and the snapshot
//! taken at the last deploy, plus submodule drift.
//!
//! The wrapper flake pins this repo and each submodule as its own input, so a
//! submodule commit that moved inside the checkout does not reach a switch
//! through the live-tree override alone. That is a documented gotcha (AGENTS.md)
//! and worth a warning on every run.

use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Node {
    pub name: String,
    pub url: Option<String>,
    pub rev: Option<String>,
    pub last_modified: Option<i64>,
}

pub struct LockDiff {
    pub added: Vec<Node>,
    pub removed: Vec<Node>,
    pub changed: Vec<(Node, Node)>,
}

impl LockDiff {
    pub fn is_empty(&self) -> bool {
        self.added.is_empty() && self.removed.is_empty() && self.changed.is_empty()
    }
}

fn node_from(name: &str, node: &Value) -> Option<Node> {
    let locked = node.get("locked")?;
    let original = node.get("original");
    Some(Node {
        name: name.to_string(),
        url: original
            .and_then(|o| o.get("url"))
            .and_then(Value::as_str)
            .map(str::to_string),
        rev: locked
            .get("rev")
            .and_then(Value::as_str)
            .map(str::to_string),
        last_modified: locked.get("lastModified").and_then(Value::as_i64),
    })
}

/// All nodes with a `locked` block, keyed by node name. `root` is a follower
/// and carries no lock, so it drops out here.
pub fn nodes(lock: &Value) -> BTreeMap<String, Node> {
    let mut out = BTreeMap::new();
    if let Some(map) = lock.get("nodes").and_then(Value::as_object) {
        for (name, node) in map {
            if let Some(n) = node_from(name, node) {
                out.insert(name.clone(), n);
            }
        }
    }
    out
}

pub fn diff(old: &Value, new: &Value) -> LockDiff {
    let old_nodes = nodes(old);
    let new_nodes = nodes(new);
    let mut added = Vec::new();
    let mut removed = Vec::new();
    let mut changed = Vec::new();

    for (name, node) in &new_nodes {
        match old_nodes.get(name) {
            None => added.push(node.clone()),
            Some(prev) => {
                if prev.rev != node.rev
                    || prev.url != node.url
                    || prev.last_modified != node.last_modified
                {
                    changed.push((prev.clone(), node.clone()));
                }
            }
        }
    }
    for (name, node) in &old_nodes {
        if !new_nodes.contains_key(name) {
            removed.push(node.clone());
        }
    }
    LockDiff {
        added,
        removed,
        changed,
    }
}

pub fn short_rev(rev: &str) -> String {
    rev.chars().take(7).collect()
}

/// Which local checkout a node's `original.url` points at, if any.
pub fn local_path(url: &str) -> Option<String> {
    let rest = if let Some(rest) = url.strip_prefix("git+file://") {
        rest
    } else if let Some(rest) = url.strip_prefix("file://") {
        rest
    } else if let Some(rest) = url.strip_prefix("path:") {
        rest
    } else {
        return None;
    };
    let path = rest.split('?').next().unwrap_or(rest);
    if path.is_empty() {
        None
    } else {
        Some(path.to_string())
    }
}

/// Howard Hinnant's civil_from_days, used for `locked.lastModified` (epoch
/// seconds) without pulling in a date crate.
pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

pub fn format_day(epoch: i64) -> String {
    let (y, m, d) = civil_from_days(epoch.div_euclid(86_400));
    format!("{y:04}-{m:02}-{d:02}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn lock_with(nodes: Value) -> Value {
        json!({ "nodes": nodes, "root": "root", "version": 7 })
    }

    #[test]
    fn diffs_added_removed_and_changed() {
        let old = lock_with(json!({
            "root": { "inputs": {} },
            "nixpkgs": {
                "locked": { "lastModified": 100, "narHash": "sha256-a", "rev": "aaaaaaaaaaaaaaaa", "type": "github" },
                "original": { "owner": "NixOS", "repo": "nixpkgs", "type": "github" }
            },
            "gone": {
                "locked": { "lastModified": 5, "rev": "bbbbbbbbbbbbbbbb", "type": "github" },
                "original": { "url": "github:foo/bar" }
            }
        }));
        let new = lock_with(json!({
            "root": { "inputs": {} },
            "nixpkgs": {
                "locked": { "lastModified": 200, "narHash": "sha256-b", "rev": "cccccccccccccccc", "type": "github" },
                "original": { "owner": "NixOS", "repo": "nixpkgs", "type": "github" }
            },
            "fresh": {
                "locked": { "lastModified": 300, "rev": "dddddddddddddddd", "type": "github" },
                "original": { "url": "github:new/input" }
            }
        }));

        let d = diff(&old, &new);
        assert_eq!(d.added.len(), 1);
        assert_eq!(d.added[0].name, "fresh");
        assert_eq!(d.added[0].url.as_deref(), Some("github:new/input"));
        assert_eq!(d.removed.len(), 1);
        assert_eq!(d.removed[0].name, "gone");
        assert_eq!(d.changed.len(), 1);
        assert_eq!(d.changed[0].0.rev.as_deref(), Some("aaaaaaaaaaaaaaaa"));
        assert_eq!(d.changed[0].1.rev.as_deref(), Some("cccccccccccccccc"));
        assert_eq!(short_rev("cccccccccccccccc"), "ccccccc");
        assert!(!d.is_empty());
    }

    #[test]
    fn identical_locks_diff_clean() {
        let lock = lock_with(json!({
            "nixpkgs": {
                "locked": { "lastModified": 1, "rev": "abc", "type": "github" },
                "original": { "url": "github:NixOS/nixpkgs" }
            }
        }));
        assert!(diff(&lock, &lock).is_empty());
    }

    #[test]
    fn local_urls_resolve_to_paths() {
        assert_eq!(
            local_path("git+file:///home/duskyelf/dotfiles/neovimBTW?ref=refs/heads/main&rev=abc"),
            Some("/home/duskyelf/dotfiles/neovimBTW".to_string())
        );
        assert_eq!(
            local_path("path:/home/duskyelf/dotfiles"),
            Some("/home/duskyelf/dotfiles".to_string())
        );
        assert_eq!(local_path("github:foo/bar"), None);
    }

    #[test]
    fn civil_days_are_correct() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(20_000), (2024, 10, 4));
        assert_eq!(format_day(1_760_000_000), "2025-10-09");
    }
}
