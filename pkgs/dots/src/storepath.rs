//! Store path parsing: `/nix/store/<32 char hash>-<name>-<version>`.
//!
//! The name/version split follows nixpkgs' `parseDrvName`: the version starts at
//! the first hyphen followed by a digit.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorePath {
    pub full: String,
    pub hash: String,
    pub name: String,
}

impl StorePath {
    /// `name-version`, or just `name` when the path carries no version, plus
    /// the split itself.
    pub fn split(&self) -> (String, Option<String>) {
        split_name_version(&self.name)
    }

    pub fn display_name(&self) -> String {
        self.split()
            .1
            .map(|v| format!("{} {v}", self.split().0))
            .unwrap_or_else(|| self.name.clone())
    }
}

/// Last component of a store path: `/nix/store/x-foo-1.0` -> `x-foo-1.0`.
pub fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Parse a store path, requiring the `/nix/store/` prefix and a 32 character
/// hash so a random path is never mistaken for one.
pub fn parse(path: &str) -> Option<StorePath> {
    let trimmed = path.trim_end_matches('/');
    let full = trimmed.strip_prefix("/nix/store/")?;
    if full.len() < 34 {
        return None;
    }
    let (hash, rest) = full.split_at(32);
    if !hash
        .chars()
        .all(|c| "0123456789abcdfghijklmnpqrsvwxyz".contains(c))
    {
        return None;
    }
    let name = rest.strip_prefix('-')?;
    if name.is_empty() {
        return None;
    }
    Some(StorePath {
        full: trimmed.to_string(),
        hash: hash.to_string(),
        name: name.to_string(),
    })
}

/// Split a derivation name into (name, version). `None` means "no version
/// component", which is what a source path or a `-source` copy looks like.
pub fn split_name_version(name: &str) -> (String, Option<String>) {
    let bytes = name.as_bytes();
    for (i, c) in name.char_indices() {
        if c != '-' {
            continue;
        }
        let next = bytes.get(i + 1).copied();
        if next.map_or(false, |b| b.is_ascii_digit()) {
            return (name[..i].to_string(), Some(name[i + 1..].to_string()));
        }
    }
    (name.to_string(), None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_names_like_nixpkgs() {
        assert_eq!(
            split_name_version("intel-gpu-tools-2.3"),
            ("intel-gpu-tools".into(), Some("2.3".into()))
        );
        assert_eq!(
            split_name_version("gcc-wrapper-15.3.0"),
            ("gcc-wrapper".into(), Some("15.3.0".into()))
        );
        assert_eq!(
            split_name_version("nixos-system-asus-26.05.20261113.f1e5c35"),
            (
                "nixos-system-asus".into(),
                Some("26.05.20261113.f1e5c35".into())
            )
        );
        assert_eq!(
            split_name_version("python3.13-auto-cpufreq-3.0.0"),
            ("python3.13-auto-cpufreq".into(), Some("3.0.0".into()))
        );
        assert_eq!(
            split_name_version("t3code-0.1.10-main.6b7027b"),
            ("t3code".into(), Some("0.1.10-main.6b7027b".into()))
        );
        assert_eq!(
            split_name_version("xgcc-15.3.0-libgcc"),
            ("xgcc".into(), Some("15.3.0-libgcc".into()))
        );
        assert_eq!(split_name_version("source"), ("source".into(), None));
        assert_eq!(
            split_name_version("dummy-xdg-mime-dirs1"),
            ("dummy-xdg-mime-dirs1".into(), None)
        );
    }

    #[test]
    fn parses_store_paths() {
        let p = parse("/nix/store/2bi6cv1d9rd2izzbm9g3i0y3ywwc46b7-source").unwrap();
        assert_eq!(p.hash, "2bi6cv1d9rd2izzbm9g3i0y3ywwc46b7");
        assert_eq!(p.name, "source");
        assert_eq!(p.split(), ("source".to_string(), None));

        let p = parse(
            "/nix/store/lh344r5g4gb5vlvij784bd8yrn8fs9kb-nixos-system-asus-26.05.20261113.f1e5c35",
        )
        .unwrap();
        assert_eq!(p.name, "nixos-system-asus-26.05.20261113.f1e5c35");
    }

    #[test]
    fn rejects_non_store_paths() {
        assert!(parse("/home/duskyelf/dotfiles").is_none());
        assert!(parse("/nix/store/not-a-hash-foo").is_none());
        assert!(parse("nix/store/00000000000000000000000000000000-x").is_none());
    }

    #[test]
    fn basenames() {
        assert_eq!(basename("/nix/store/x-foo-1.0"), "x-foo-1.0");
        assert_eq!(basename("x-foo-1.0"), "x-foo-1.0");
    }
}
