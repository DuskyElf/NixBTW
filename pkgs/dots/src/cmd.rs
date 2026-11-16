//! Process helpers. Everything that shells out goes through here so failures
//! carry the stderr tail instead of an opaque exit code.
//!
//! Security-critical tools are resolved absolutely, not from `PATH`: the audit
//! is only worth reading if the `nix` that verifies the store, the `sudo` that
//! performs the switch, and the `nixos-rebuild` that activates are the ones the
//! running system installed. `PATH` is inherited and editable, so it is a
//! bootstrap fallback at best, and every fallback says so loudly.

use anyhow::{bail, Context, Result};
use std::ffi::OsStr;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::OnceLock;

pub struct Out {
    pub status: ExitStatus,
    pub stdout: String,
    pub stderr: String,
}

impl Out {
    pub fn ok(&self) -> bool {
        self.status.success()
    }
}

/// Run a command, capturing both streams.
pub fn run<P: AsRef<OsStr>>(prog: P, args: &[String]) -> Result<Out> {
    let prog = prog.as_ref();
    let out = Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("running {}", prog.to_string_lossy()))?;
    Ok(Out {
        status: out.status,
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    })
}

/// Run a command with inherited stdio, for long interactive steps (the switch).
pub fn run_stream<P: AsRef<OsStr>>(prog: P, args: &[String]) -> Result<ExitStatus> {
    let prog = prog.as_ref();
    Command::new(prog)
        .args(args)
        .status()
        .with_context(|| format!("running {}", prog.to_string_lossy()))
}

/// Same as `run`, but a non-zero exit is an error carrying the stderr tail.
pub fn run_ok<P: AsRef<OsStr>>(prog: P, args: &[String]) -> Result<Out> {
    let out = run(prog.as_ref(), args)?;
    if !out.ok() {
        bail!(
            "{} failed ({}):\n{}",
            prog.as_ref().to_string_lossy(),
            out.status,
            tail(&out.stderr, 40)
        );
    }
    Ok(out)
}

/// Last `n` lines, for error reporting.
pub fn tail(text: &str, n: usize) -> String {
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(n);
    lines[start..].join("\n")
}

pub fn which(prog: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(prog))
        .find(|p| p.is_file())
}

pub fn exists(prog: &str) -> bool {
    which(prog).is_some()
}

fn warn_once(slot: &'static OnceLock<()>, message: &str) {
    if slot.set(()).is_ok() {
        eprintln!("dots: warning: {message}");
    }
}

/// A `/run/current-system/sw/bin/<name>` entry that canonicalises into the
/// store, returned under its profile name. `nix` and `nix-store` are one
/// multicall binary that dispatches on `argv[0]`, so canonicalising the path we
/// execute would turn `nix-store -qR` into `nix -qR`. The store check is done
/// on the resolved target, the name is kept.
fn system_tool(name: &str) -> Option<PathBuf> {
    let path = Path::new("/run/current-system/sw/bin").join(name);
    let resolved = std::fs::canonicalize(&path).ok()?;
    if resolved.starts_with("/nix/store/") {
        Some(path)
    } else {
        None
    }
}

/// `nix`, from the running system, with `PATH` only as a loud bootstrap
/// fallback. The self-check's `nix store verify` must not be shimmable.
pub fn nix() -> Result<PathBuf> {
    named_tool("nix")
}

/// `nix-store`, resolved the same way as `nix`.
pub fn nix_store() -> Result<PathBuf> {
    named_tool("nix-store")
}

/// `diff` produces evidence a human is asked to trust, so prefer the system
/// copy too; PATH remains a bootstrap fallback with a warning.
pub fn diff() -> Result<PathBuf> {
    named_tool("diff")
}

fn named_tool(name: &str) -> Result<PathBuf> {
    static WARNED: OnceLock<()> = OnceLock::new();
    if let Some(path) = system_tool(name) {
        return Ok(path);
    }
    let Some(found) = which(name) else {
        bail!("{name} is not in /run/current-system/sw/bin and not on PATH");
    };
    let resolved = std::fs::canonicalize(&found).unwrap_or_else(|_| found.clone());
    let pinned = resolved.starts_with("/nix/store/");
    warn_once(
        &WARNED,
        &format!(
            "using {name} from PATH ({} → {}{}): /run/current-system/sw/bin/{name} is missing. \
             Bootstrap path only; this tool is not pinned by the running system",
            found.display(),
            resolved.display(),
            if pinned { "" } else { ", outside /nix/store" }
        ),
    );
    Ok(found)
}

/// The setuid sudo wrapper. Nothing else may perform the switch: a `sudo` from
/// `PATH` would let the audit be pointed at a different binary than the one
/// that gets root.
pub fn sudo() -> Result<PathBuf> {
    let wrapper = Path::new("/run/wrappers/bin/sudo");
    let md = std::fs::symlink_metadata(wrapper)
        .with_context(|| format!("statting {}", wrapper.display()))?;
    if md.file_type().is_symlink() {
        bail!(
            "{} is a symlink; the switch requires the setuid wrapper itself",
            wrapper.display()
        );
    }
    if md.uid() != 0 {
        bail!(
            "{} is owned by uid {}, not root",
            wrapper.display(),
            md.uid()
        );
    }
    if md.mode() & 0o4000 == 0 {
        bail!(
            "{} is not setuid (mode {:04o}); refusing to use it for the switch",
            wrapper.display(),
            md.mode() & 0o7777
        );
    }
    Ok(wrapper.to_path_buf())
}

/// `nixos-rebuild` from the running system, pinned into the store.
pub fn nixos_rebuild() -> Result<PathBuf> {
    let path = Path::new("/run/current-system/sw/bin/nixos-rebuild");
    let resolved =
        std::fs::canonicalize(path).with_context(|| format!("resolving {}", path.display()))?;
    if !resolved.starts_with("/nix/store/") {
        bail!(
            "{} resolves to {}, outside /nix/store",
            path.display(),
            resolved.display()
        );
    }
    // Keep the name as well: scripts sometimes branch on `$0`, and the store
    // target is checked above.
    Ok(path.to_path_buf())
}

/// `home-manager` is a user-installed command, not a system one. It may come
/// from `PATH`, but a copy outside the store is called out: it is the code that
/// activates the home generation.
pub fn home_manager() -> Result<PathBuf> {
    static WARNED: OnceLock<()> = OnceLock::new();
    let Some(found) = which("home-manager") else {
        bail!("home-manager is not on PATH; cannot switch home");
    };
    let resolved = std::fs::canonicalize(&found).unwrap_or(found);
    if !resolved.starts_with("/nix/store/") {
        warn_once(
            &WARNED,
            &format!(
                "home-manager resolves to {}, outside /nix/store: the activation code is not \
                 store-pinned",
                resolved.display()
            ),
        );
    }
    Ok(resolved)
}

/// Render a command line so it can be copied into a shell as-is.
pub fn shell_join(parts: &[String]) -> String {
    parts
        .iter()
        .map(|p| {
            let safe = !p.is_empty()
                && p.chars()
                    .all(|c| c.is_ascii_alphanumeric() || "_-./:=@+,".contains(c));
            if safe {
                p.clone()
            } else {
                format!("'{}'", p.replace('\'', "'\\''"))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Read a symlink chain to its final target, if it resolves.
pub fn resolve(path: &Path) -> Option<PathBuf> {
    std::fs::canonicalize(path).ok()
}

/// A fresh temp file, created with `create_new` so a pre-existing symlink at
/// the candidate path is never written through. Callers remove it.
pub fn temp_file(label: &str) -> Result<PathBuf> {
    static COUNTER: AtomicUsize = AtomicUsize::new(0);
    let dir = std::env::temp_dir();
    for _ in 0..64 {
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = dir.join(format!("dots-{}-{n}-{label}.tmp", std::process::id()));
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(_) => return Ok(path),
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(err) => {
                return Err(err)
                    .with_context(|| format!("creating a temp file in {}", dir.display()))
            }
        }
    }
    bail!("could not create a unique temp file in {}", dir.display())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tail_keeps_the_end() {
        let text = (1..=10)
            .map(|i| i.to_string())
            .collect::<Vec<_>>()
            .join("\n");
        assert_eq!(tail(&text, 3), "8\n9\n10");
        assert_eq!(tail("one", 5), "one");
        assert_eq!(tail("", 5), "");
    }

    #[test]
    fn shell_join_quotes_when_needed() {
        assert_eq!(
            shell_join(&["nix".into(), "build".into(), "path:/a b".into()]),
            "nix build 'path:/a b'"
        );
        assert_eq!(
            shell_join(&["--override-input".into(), "my-dotfiles".into()]),
            "--override-input my-dotfiles"
        );
    }

    #[test]
    fn temp_files_never_reuse_an_existing_path() {
        let first = temp_file("test").unwrap();
        let second = temp_file("test").unwrap();
        assert_ne!(first, second);
        assert!(first.is_file());
        std::fs::remove_file(&first).unwrap();
        std::fs::remove_file(&second).unwrap();
    }

    #[test]
    fn temp_file_does_not_follow_a_planted_symlink() {
        let victim = temp_file("victim").unwrap();
        std::fs::write(&victim, b"untouched").unwrap();

        // Force the next candidate to collide with the planted symlink by
        // counting: the pid+counter suffix is what makes this predictable.
        let collision = temp_file("collide").unwrap();
        std::fs::remove_file(&collision).unwrap();
        std::os::unix::fs::symlink(&victim, &collision).unwrap();

        // A create_new open on the symlink path must fail, never write through.
        let result = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&collision);
        assert!(result.is_err(), "create_new must not follow a symlink");
        assert_eq!(std::fs::read(&victim).unwrap(), b"untouched");

        std::fs::remove_file(&collision).unwrap();
        std::fs::remove_file(&victim).unwrap();
    }

    #[test]
    fn sudo_wrapper_is_required_absolutely() {
        match sudo() {
            Ok(path) => assert_eq!(path, PathBuf::from("/run/wrappers/bin/sudo")),
            Err(err) => assert!(err.to_string().contains("/run/wrappers/bin/sudo"), "{err}"),
        }
    }
}
