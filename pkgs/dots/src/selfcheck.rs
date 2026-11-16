//! Integrity of the tool itself.
//!
//! `dots` performs the audit, so `dots` cannot be the thing that is quietly
//! editable. A store build is immutable and root-owned; its crate source is a
//! store path too, and both are verified against the store database before any
//! subcommand does work. A nix store path is owned by root with mode 0555, so a
//! canonicalised path under `/nix/store` is the property being relied on, not a
//! claim about who ran the build.

use crate::cmd;
use crate::{BUILD_SOURCE, VERSION};
use anyhow::{bail, Context, Result};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

pub struct SelfInfo {
    pub exe: String,
    pub source: Option<String>,
    pub skipped: bool,
    /// The running exe is the one `/run/current-system/sw/bin/dots` resolves
    /// to. False only during bootstrap, when that path does not exist yet.
    pub system_bound: bool,
}

/// Effective uid from `/proc/self/status`, so no libc bindings are needed.
pub fn euid() -> u32 {
    let text = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    parse_euid(&text).unwrap_or(0)
}

fn parse_euid(status: &str) -> Option<u32> {
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("Uid:") {
            let fields: Vec<&str> = rest.split_whitespace().collect();
            if let Some(effective) = fields.get(1) {
                return effective.parse().ok();
            }
        }
    }
    None
}

/// The tool drives sudo itself; running it as root would make every audit step
/// privileged for no reason.
pub fn refuse_root() -> Result<()> {
    if euid() == 0 {
        bail!(
            "dots must not run as root: it calls sudo for the switch and keeps \
             every other step as your user. Run it from your login account."
        );
    }
    Ok(())
}

fn writable_by_group_or_other(mode: u32) -> bool {
    mode & 0o022 != 0
}

/// Validate one immutable executable: under /nix/store, root-owned, not
/// group/other writable, and matching the store database.
pub fn check_exe(exe: &Path, source: Option<&Path>) -> Result<()> {
    let resolved =
        std::fs::canonicalize(exe).with_context(|| format!("resolving {}", exe.display()))?;
    let resolved_str = resolved.display().to_string();

    if !resolved_str.starts_with("/nix/store/") {
        bail!(
            "{resolved_str} is not a /nix/store path. This build is not store-pinned, \
             so the audit cannot vouch for the code that runs it. \
             Run /run/current-system/sw/bin/dots instead, or set DOTS_SKIP_SELF_CHECK=1 \
             to run a development build anyway."
        );
    }

    let md = std::fs::metadata(&resolved).with_context(|| format!("statting {resolved_str}"))?;
    if md.uid() != 0 {
        bail!("{resolved_str} is owned by uid {}, not root", md.uid());
    }
    if writable_by_group_or_other(md.mode()) {
        bail!(
            "{resolved_str} is group/other writable (mode {:04o})",
            md.mode() & 0o7777
        );
    }

    cmd::run_ok(
        &cmd::nix()?,
        &[
            "store".to_string(),
            "verify".to_string(),
            resolved_str.clone(),
        ],
    )
    .with_context(|| format!("verifying {resolved_str}"))?;

    match source {
        None => bail!(
            "this build has no embedded DOTS_SOURCE, so its crate source cannot be \
             verified. Rebuild through nix (pkgs/dots/default.nix sets it)."
        ),
        Some(path) => {
            let source_str = path.display().to_string();
            if !source_str.starts_with("/nix/store/") {
                bail!("embedded source {source_str} is not a /nix/store path");
            }
            if !path.exists() {
                bail!("embedded source {source_str} is missing from the store");
            }
            cmd::run_ok(
                &cmd::nix()?,
                &[
                    "store".to_string(),
                    "verify".to_string(),
                    source_str.clone(),
                ],
            )
            .with_context(|| format!("verifying crate source {source_str}"))?;
        }
    }
    Ok(())
}

/// `/run/current-system/sw/bin/dots`, resolved into the store. That path is the
/// one the system declares, so it is the one the audit must be running.
pub fn system_binary() -> Option<PathBuf> {
    let path = Path::new("/run/current-system/sw/bin/dots");
    let resolved = std::fs::canonicalize(path).ok()?;
    if resolved.starts_with("/nix/store/") {
        Some(resolved)
    } else {
        None
    }
}

/// Refuse to audit from any binary other than the system's, so `dots` cannot be
/// shadowed by a dev build or a private copy in a shell that happens to have a
/// different PATH first. Before the first switch the path does not exist; that
/// bootstrap case is allowed with a one-line note.
pub fn require_system_binding(exe: &Path) -> Result<bool> {
    match system_binary() {
        Some(system) => {
            if system != exe {
                bail!(
                    "the running binary is {}\n\
                     but the system ships {}\n\
                     Run /run/current-system/sw/bin/dots so the audit is the code the system \
                     declares.",
                    exe.display(),
                    system.display()
                );
            }
            Ok(true)
        }
        None => {
            eprintln!(
                "dots: note: /run/current-system/sw/bin/dots does not exist yet (bootstrap before \
                 the first system switch); accepting {} unbound",
                exe.display()
            );
            Ok(false)
        }
    }
}

/// The header: which binary is speaking, what source it was built from, and
/// which checkout it is auditing. `source` alone would be ambiguous, because a
/// dev build can embed a source path without being the system binary.
pub fn signature(info: &SelfInfo, dotfiles: &Path) -> String {
    format!(
        "dots {VERSION} · exe {} ({}) · built from {} · auditing {}",
        info.exe,
        if info.system_bound {
            "system-bound"
        } else {
            "not bound to /run/current-system"
        },
        info.source.as_deref().unwrap_or("<not embedded>"),
        dotfiles.display()
    )
}

/// Run the self-check for a real subcommand.
pub fn check() -> Result<SelfInfo> {
    let exe = std::env::current_exe().context("locating the running binary")?;

    if std::env::var("DOTS_SKIP_SELF_CHECK").ok().as_deref() == Some("1") {
        // The warning itself is printed by the caller for every subcommand,
        // `status` included, so it appears exactly once.
        let resolved = std::fs::canonicalize(&exe).unwrap_or(exe);
        let system_bound = system_binary().map(|s| s == resolved).unwrap_or(false);
        return Ok(SelfInfo {
            exe: resolved.display().to_string(),
            source: BUILD_SOURCE.map(str::to_string),
            skipped: true,
            system_bound,
        });
    }

    let source: Option<PathBuf> = match BUILD_SOURCE {
        Some(path) => Some(PathBuf::from(path)),
        None => None,
    };
    let resolved =
        std::fs::canonicalize(&exe).with_context(|| format!("resolving {}", exe.display()))?;
    check_exe(&resolved, source.as_deref())?;
    let system_bound = require_system_binding(&resolved)?;

    Ok(SelfInfo {
        exe: resolved.display().to_string(),
        source: BUILD_SOURCE.map(str::to_string),
        skipped: false,
        system_bound,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_paths_outside_the_store() {
        let dir = std::env::temp_dir().join(format!("dots-selfcheck-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("dots");
        std::fs::write(&exe, b"#!/bin/sh\n").unwrap();

        let err = check_exe(&exe, None).unwrap_err().to_string();
        assert!(err.contains("/nix/store"), "unexpected error: {err}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn mode_check_ignores_the_owner_write_bit_only() {
        assert!(!writable_by_group_or_other(0o100555));
        assert!(writable_by_group_or_other(0o100775));
        assert!(writable_by_group_or_other(0o100557));
    }

    #[test]
    fn euid_parsing_uses_the_effective_field() {
        let status = "Name:\tdots\nUid:\t1000\t1000\t1000\t1000\nGid:\t100\t100\t100\t100\n";
        assert_eq!(parse_euid(status), Some(1000));
        assert_eq!(parse_euid("Uid:\t0\t0\t0\t0\n"), Some(0));
        assert_eq!(parse_euid("nothing"), None);
    }
}
