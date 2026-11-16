//! Persistent state under `$XDG_STATE_HOME/dots` (or `~/.local/state/dots`).
//!
//! Nothing here ever writes inside the repo: the repo is the thing being
//! audited, so a recording tool must not change it.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub const VERSION: u32 = 1;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Deploy {
    pub time: String,
    pub target: String,
    pub commit: Option<String>,
    #[serde(default)]
    pub dirty: bool,
    pub lock_sha: String,
    pub power_sha: String,
    pub result: Option<String>,
    pub exe: String,
    pub source: String,
    #[serde(default)]
    pub paths: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct State {
    #[serde(default)]
    pub version: u32,
    #[serde(default)]
    pub last_deploy: Option<Deploy>,
    /// The last deploy that switched the system. `power.sh` is only linked by
    /// the system activation, so its baseline is this record, not `last_deploy`.
    #[serde(default)]
    pub last_system: Option<Deploy>,
}

impl State {
    pub fn load(dir: &Path) -> State {
        let path = dir.join("state.json");
        match fs::read_to_string(&path) {
            Ok(text) => match serde_json::from_str::<State>(&text) {
                Ok(mut state) => {
                    state.version = VERSION;
                    state
                }
                Err(err) => {
                    eprintln!(
                        "dots: warning: ignoring unreadable {}: {err}",
                        path.display()
                    );
                    State::default()
                }
            },
            Err(_) => State::default(),
        }
    }

    pub fn save(&self, dir: &Path) -> Result<()> {
        let mut state = self.clone();
        state.version = VERSION;
        let text = serde_json::to_string_pretty(&state)?;
        atomic_write(&dir.join("state.json"), format!("{text}\n").as_bytes())
    }

    pub fn record(&mut self, deploy: Deploy, system: bool) {
        if system {
            self.last_system = Some(deploy.clone());
        }
        self.last_deploy = Some(deploy);
    }
}

/// Temp file + rename. A half written state file must never be observed.
pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let tmp = path.with_extension(format!("{}.tmp", std::process::id()));
    {
        let mut file =
            fs::File::create(&tmp).with_context(|| format!("creating {}", tmp.display()))?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path).with_context(|| format!("renaming into {}", path.display()))?;
    Ok(())
}

pub fn append_log(dir: &Path, deploy: &Deploy) -> Result<()> {
    let path = dir.join("logs/deploys.jsonl");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let line = serde_json::to_string(deploy)?;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .with_context(|| format!("opening {}", path.display()))?;
    writeln!(file, "{line}")?;
    Ok(())
}

/// `$XDG_STATE_HOME/dots` or `$HOME/.local/state/dots`.
pub fn state_dir() -> Result<PathBuf> {
    if let Some(dir) = std::env::var_os("XDG_STATE_HOME") {
        if !dir.is_empty() {
            return Ok(PathBuf::from(dir).join("dots"));
        }
    }
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join(".local/state/dots"))
}

pub fn read_snapshot(dir: &Path, name: &str) -> Option<String> {
    fs::read_to_string(dir.join(name)).ok()
}

pub fn write_snapshot(dir: &Path, name: &str, text: &str) -> Result<()> {
    atomic_write(&dir.join(name), text.as_bytes())
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

pub fn sha256_file(path: &Path) -> Option<String> {
    let bytes = fs::read(path).ok()?;
    Some(sha256_hex(&bytes))
}

pub fn now_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// `2026-11-16T09:44:00Z`, built without a date crate.
pub fn format_timestamp(epoch: i64) -> String {
    let days = epoch.div_euclid(86_400);
    let secs = epoch.rem_euclid(86_400);
    let (year, month, day) = crate::lockfile::civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        secs / 3600,
        (secs % 3600) / 60,
        secs % 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps_are_utc_and_zero_padded() {
        assert_eq!(format_timestamp(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_timestamp(1_000_000_000), "2001-09-09T01:46:40Z");
        assert_eq!(format_timestamp(1_764_000_000), "2025-11-24T16:00:00Z");
    }

    #[test]
    fn sha256_matches_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn state_roundtrips_and_tracks_the_system_baseline() {
        let dir = std::env::temp_dir().join(format!("dots-state-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);

        let mut state = State::default();
        let deploy = Deploy {
            time: "2026-11-16T00:00:00Z".into(),
            target: "system".into(),
            commit: Some("abc".into()),
            dirty: false,
            lock_sha: "l".into(),
            power_sha: "p".into(),
            result: Some("/nix/store/x".into()),
            exe: "/nix/store/e".into(),
            source: "/nix/store/s".into(),
            paths: vec!["/nix/store/x".into()],
        };
        state.record(deploy, true);
        state.save(&dir).unwrap();

        let loaded = State::load(&dir);
        assert_eq!(loaded.version, VERSION);
        assert_eq!(
            loaded.last_deploy.as_ref().unwrap().commit.as_deref(),
            Some("abc")
        );
        assert!(loaded.last_system.is_some());
        let _ = fs::remove_dir_all(&dir);
    }
}
