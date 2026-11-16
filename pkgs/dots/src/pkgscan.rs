//! Closure diffs and package provenance.
//!
//! `nix store diff-closures` is the forensic record of what a rebuild changes,
//! and the declared-package positions plus the flake archive say which input
//! each new path came from. Both are parsed defensively: nix's output is not a
//! stable machine format and it carries ANSI escapes.

use crate::storepath;
use std::collections::BTreeSet;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClosureChange {
    pub name: String,
    pub old: Option<String>,
    pub new: Option<String>,
    pub delta: Option<i64>,
    pub raw: String,
}

impl ClosureChange {
    /// A version upgrade: present before and after. Additions and removals
    /// (`∅` / `ε`) are already covered by the closure path diff.
    pub fn is_upgrade(&self) -> bool {
        self.old.is_some() && self.new.is_some()
    }
}

/// Remove ANSI SGR sequences (nix colours the size even when not a tty).
pub fn strip_ansi(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for c in chars.by_ref() {
                    if c.is_ascii_alphabetic() {
                        break;
                    }
                }
                continue;
            }
            continue;
        }
        out.push(c);
    }
    out
}

/// Parse a size such as `122.0 KiB`, `-102.5 KiB`, `4 KiB`, `1.2 MiB`.
pub fn parse_size(text: &str) -> Option<i64> {
    let mut negative = false;
    let mut number = String::new();
    let mut unit = String::new();
    let mut chars = text.chars().peekable();

    while let Some(&c) = chars.peek() {
        if c == '-' && number.is_empty() {
            negative = true;
            chars.next();
        } else if c.is_ascii_digit() || (c == '.' && !number.contains('.')) {
            number.push(c);
            chars.next();
        } else if c == ' ' || c == ',' || c == '(' {
            if number.is_empty() {
                chars.next();
            } else {
                break;
            }
        } else {
            break;
        }
    }
    if number.is_empty() {
        return None;
    }
    // The unit follows after a space, e.g. `122.0 KiB`.
    while matches!(chars.peek(), Some(' ')) {
        chars.next();
    }
    while let Some(&c) = chars.peek() {
        if c.is_ascii_alphabetic() {
            unit.push(c);
            chars.next();
        } else {
            break;
        }
    }
    let value: f64 = number.parse().ok()?;
    let multiplier: f64 = match unit.as_str() {
        "B" | "byte" | "bytes" | "Bytes" => 1.0,
        "KiB" | "Kib" | "kib" => 1024.0,
        "MiB" | "Mib" | "mib" => 1024.0 * 1024.0,
        "GiB" | "Gib" | "gib" => 1024.0 * 1024.0 * 1024.0,
        "TiB" | "Tib" | "tib" => 1024.0 * 1024.0 * 1024.0 * 1024.0,
        _ => return None,
    };
    let bytes = (value * multiplier).round() as i64;
    Some(if negative { -bytes } else { bytes })
}

fn split_size_suffix(text: &str) -> (String, Option<i64>) {
    // The size lives after the last `, ` or inside the last ` (...)`.
    let mut delta = None;
    let mut head = text.trim().to_string();
    if let Some(open) = head.rfind(" (") {
        if head.ends_with(')') {
            let inner = &head[open + 2..head.len() - 1];
            delta = parse_size(inner);
            head.truncate(open);
        }
    } else if let Some(comma) = head.rfind(", ") {
        if let Some(size) = parse_size(&head[comma + 2..]) {
            delta = Some(size);
            head.truncate(comma);
        }
    }
    let lowered = text.to_ascii_lowercase();
    if lowered.contains("decrease") {
        delta = delta.map(|d| -d.abs());
    }
    (head.trim().to_string(), delta)
}

/// Parse the whole output of `nix store diff-closures`.
pub fn parse_diff_closures(text: &str) -> Vec<ClosureChange> {
    let mut out = Vec::new();
    for raw in text.lines() {
        let line = strip_ansi(raw);
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        // `+name-version (1.2 MiB)` / `-name-version (4 KiB)` forms.
        if let Some(rest) = line.strip_prefix('+').or_else(|| line.strip_prefix('-')) {
            let removed = line.starts_with('-');
            let (head, delta) = split_size_suffix(rest);
            let (name, version) = storepath::split_name_version(head.trim());
            out.push(ClosureChange {
                name,
                old: if removed { version.clone() } else { None },
                new: if removed { None } else { version },
                delta: delta.map(|d| if removed { -d.abs() } else { d.abs() }),
                raw: line.to_string(),
            });
            continue;
        }

        let Some((name, rest)) = line.split_once(": ") else {
            continue;
        };
        let (versions, suffix) = match rest.split_once(" → ") {
            Some((old, after)) => {
                let (head, delta) = split_size_suffix(after);
                ((Some(old.trim().to_string()), Some(head)), Some(delta))
            }
            None => {
                let (head, delta) = split_size_suffix(rest);
                let _ = head;
                ((None, None), Some(delta))
            }
        };
        let (old, new) = versions;
        let delta = suffix.flatten();
        let normalize = |v: Option<String>| -> Option<String> {
            match v.as_deref().map(str::trim) {
                Some("ε") | Some("∅") | Some("") | None => None,
                Some(other) => Some(other.to_string()),
            }
        };
        out.push(ClosureChange {
            name: name.trim().to_string(),
            old: normalize(old),
            new: normalize(new),
            delta,
            raw: line.to_string(),
        });
    }
    out
}

/// Store paths only in `new` / only in `old`.
pub fn set_diff(old: &[String], new: &[String]) -> (Vec<String>, Vec<String>) {
    let old_set: BTreeSet<&String> = old.iter().collect();
    let new_set: BTreeSet<&String> = new.iter().collect();
    let added = new_set
        .difference(&old_set)
        .map(|s| (*s).clone())
        .collect::<Vec<_>>();
    let removed = old_set
        .difference(&new_set)
        .map(|s| (*s).clone())
        .collect::<Vec<_>>();
    (added, removed)
}

/// Which flake input provided the file a package's `meta.position` points at.
///
/// Longest matching prefix wins: nested sources such as
/// `my-dotfiles/nixpkgs-fast-release` must beat their parent's copy.
pub fn attribute_position(position: &str, inputs: &[(String, String)]) -> Option<String> {
    let mut best: Option<(&str, usize)> = None;
    for (name, path) in inputs {
        if position == path || position.starts_with(&format!("{path}/")) {
            let len = path.len();
            if best.map_or(true, |(_, best_len)| len > best_len) {
                best = Some((name.as_str(), len));
            }
        }
    }
    best.map(|(name, _)| name.to_string())
}

/// Human label for an input name: the dotfiles checkout is `dotfiles`, a nested
/// input under it (`my-dotfiles/nixpkgs-fast-release`) is reported by its own
/// name, since that is the nixpkgs instance the package was built against.
pub fn input_label(name: &str) -> String {
    if name == "my-dotfiles" {
        "dotfiles".to_string()
    } else if let Some(rest) = name.strip_prefix("my-dotfiles/") {
        rest.to_string()
    } else {
        name.to_string()
    }
}

/// `cache` when cache.nixos.org signed the path, otherwise a local build.
pub fn cache_provenance(signatures: &[String]) -> &'static str {
    if signatures
        .iter()
        .any(|s| s.starts_with("cache.nixos.org-1:"))
    {
        "cache"
    } else {
        "local build"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = include_str!("../tests/fixtures/diff-closures.txt");

    #[test]
    fn parses_the_captured_real_sample() {
        let changes = parse_diff_closures(SAMPLE);

        let nixos = changes
            .iter()
            .find(|c| c.name == "nixos-system-asus")
            .expect("system version bump");
        assert_eq!(nixos.old.as_deref(), Some("26.05.20261108.ac588ef"));
        assert_eq!(nixos.new.as_deref(), Some("26.05.20261113.f1e5c35"));
        assert!(nixos.is_upgrade());

        let electron = changes
            .iter()
            .find(|c| c.name == "electron-unwrapped")
            .expect("electron upgrade");
        assert_eq!(electron.old.as_deref(), Some("44.10.2"));
        assert_eq!(electron.new.as_deref(), Some("44.11.3"));
        assert_eq!(electron.delta, Some(124_928));

        let guardian = changes
            .iter()
            .find(|c| c.name == "wallpaper-guardian")
            .expect("added package");
        assert_eq!(guardian.old, None);
        assert_eq!(guardian.new.as_deref(), Some("0.1.0"));
        assert_eq!(guardian.delta, Some(10_380_902));

        let cheerio = changes
            .iter()
            .find(|c| c.name == "cheerio")
            .expect("removed package");
        assert_eq!(cheerio.old.as_deref(), Some("1.2.0.tgz"));
        assert_eq!(cheerio.new, None);
        assert_eq!(cheerio.delta, Some(-104_960));

        // `ε → ∅` noise carries no versions and is never an upgrade.
        assert!(changes
            .iter()
            .any(|c| c.name == "machine" && !c.is_upgrade()));
        assert!(changes
            .iter()
            .all(|c| c.raw != "machine: ε → ∅" || c.is_upgrade() == false));
    }

    #[test]
    fn parses_pluss_minus_and_increase_forms() {
        let text = "\
+bar-0.1 (1.2 MiB)
-baz-0.2 (4 KiB)
qux: 1.0 → 1.1 (123.4 KiB increase)
quux: 2.0 → 1.0 (4.0 KiB decrease)
";
        let changes = parse_diff_closures(text);
        assert_eq!(changes.len(), 4);
        assert_eq!(changes[0].name, "bar");
        assert_eq!(changes[0].new.as_deref(), Some("0.1"));
        assert_eq!(changes[0].delta, Some(1_258_291));
        assert_eq!(changes[1].name, "baz");
        assert_eq!(changes[1].old.as_deref(), Some("0.2"));
        assert_eq!(changes[1].delta, Some(-4096));
        assert_eq!(changes[2].delta, Some(126_362));
        assert_eq!(changes[3].delta, Some(-4096));
    }

    #[test]
    fn strips_ansi_colours() {
        let line = "electron-unwrapped: 44.10.2 → 44.11.3, \x1b[31;1m122.0 KiB\x1b[0m";
        let clean = strip_ansi(line);
        assert!(!clean.contains('\x1b'));
        let changes = parse_diff_closures(line);
        assert_eq!(changes[0].delta, Some(124_928));
    }

    #[test]
    fn set_diff_is_symmetric() {
        let old = vec!["/nix/store/a-x".to_string(), "/nix/store/b-y".to_string()];
        let new = vec!["/nix/store/b-y".to_string(), "/nix/store/c-z".to_string()];
        let (added, removed) = set_diff(&old, &new);
        assert_eq!(added, vec!["/nix/store/c-z".to_string()]);
        assert_eq!(removed, vec!["/nix/store/a-x".to_string()]);
    }

    #[test]
    fn position_attribution_prefers_the_longest_input() {
        let inputs = vec![
            (
                "nixpkgs".to_string(),
                "/nix/store/2bi6cv1d9rd2izzbm9g3i0y3ywwc46b7-source".to_string(),
            ),
            (
                "my-dotfiles".to_string(),
                "/nix/store/kan5jf9dv2arhnr1bbfaj284nrpyyzpa-source".to_string(),
            ),
            (
                "my-dotfiles/nixpkgs-fast-release".to_string(),
                "/nix/store/386k7n7dgrs03cmf23n988w01016aqvm-source".to_string(),
            ),
        ];

        assert_eq!(
            attribute_position(
                "/nix/store/2bi6cv1d9rd2izzbm9g3i0y3ywwc46b7-source/pkgs/by-name/in/intel-gpu-tools/package.nix:104",
                &inputs
            )
            .as_deref(),
            Some("nixpkgs")
        );
        assert_eq!(
            attribute_position(
                "/nix/store/kan5jf9dv2arhnr1bbfaj284nrpyyzpa-source/pkgs/dots/default.nix:9",
                &inputs
            )
            .as_deref(),
            Some("my-dotfiles")
        );
        assert_eq!(
            attribute_position(
                "/nix/store/386k7n7dgrs03cmf23n988w01016aqvm-source/pkgs/os-specific/linux/nvidia-x11/default.nix:1",
                &inputs
            )
            .as_deref(),
            Some("my-dotfiles/nixpkgs-fast-release")
        );
        assert_eq!(attribute_position("/home/x/file.nix:1", &inputs), None);
        assert_eq!(input_label("my-dotfiles"), "dotfiles");
        assert_eq!(
            input_label("my-dotfiles/nixpkgs-fast-release"),
            "nixpkgs-fast-release"
        );
        assert_eq!(input_label("niri"), "niri");
    }

    #[test]
    fn cache_provenance_needs_the_cache_key() {
        assert_eq!(
            cache_provenance(&["cache.nixos.org-1:abc".to_string()]),
            "cache"
        );
        assert_eq!(cache_provenance(&[]), "local build");
        assert_eq!(cache_provenance(&["other:abc".to_string()]), "local build");
    }
}
