//! The deploy pipeline: audit, build, report, prompt, switch, verify, record.
//!
//! Order matters. Nothing privileged happens before the evidence is printed, and
//! the state file is only written once a switch actually succeeded.

use crate::cmd;
use crate::git;
use crate::lockfile;
use crate::nix::{self, DeclaredPkg, Names, Target};
use crate::pkgscan;
use crate::power;
use crate::selfcheck::SelfInfo;
use crate::state::{self, Deploy, State};
use crate::storepath;
use crate::ui::{human_delta, human_size, Ui};
use anyhow::{bail, Context, Result};
use serde_json::Value;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

/// The wrapper input that the live-tree override replaces. Its locked rev is
/// deliberately stale between deploys, so it must not be reported as submodule
/// drift; the real ones are the submodules the wrapper pins separately.
const OVERRIDDEN_INPUT: &str = "my-dotfiles";

pub struct Ctx {
    pub dotfiles: PathBuf,
    pub deploy: PathBuf,
    pub ui: Ui,
    pub yes: bool,
    pub dry_run: bool,
    pub state_dir: PathBuf,
    pub names: Names,
    pub self_info: SelfInfo,
    warnings: RefCell<Vec<String>>,
    flushed_warnings: RefCell<usize>,
    archive: RefCell<Option<Vec<(String, String)>>>,
}

impl Ctx {
    pub fn new(
        dotfiles: PathBuf,
        deploy: Option<PathBuf>,
        ui: Ui,
        yes: bool,
        dry_run: bool,
        self_info: SelfInfo,
        resolve_flake: bool,
    ) -> Result<Ctx> {
        let dotfiles = std::fs::canonicalize(&dotfiles)
            .with_context(|| format!("resolving dotfiles dir {}", dotfiles.display()))?;
        if !dotfiles.join("flake.nix").is_file() {
            bail!(
                "{} does not look like the dotfiles flake (no flake.nix)",
                dotfiles.display()
            );
        }
        let deploy = deploy.unwrap_or_else(|| dotfiles.join("deploy-system"));
        let deploy = std::fs::canonicalize(&deploy)
            .with_context(|| format!("resolving deploy dir {}", deploy.display()))?;
        if !deploy.join("flake.nix").is_file() {
            bail!(
                "{} does not look like the deploy wrapper flake (no flake.nix)",
                deploy.display()
            );
        }
        let state_dir = state::state_dir()?;

        let mut ctx = Ctx {
            dotfiles,
            deploy,
            ui,
            yes,
            dry_run,
            state_dir,
            names: Names {
                host: String::new(),
                home: String::new(),
                user: String::new(),
            },
            self_info,
            warnings: RefCell::new(Vec::new()),
            flushed_warnings: RefCell::new(0),
            archive: RefCell::new(None),
        };
        ctx.names = if resolve_flake {
            nix::discover_names(&ctx)?
        } else {
            Names {
                host: String::new(),
                home: String::new(),
                user: String::new(),
            }
        };
        ctx.flush_warnings();
        Ok(ctx)
    }

    pub fn collect_warnings(&self, stderr: &str) {
        let mut warnings = self.warnings.borrow_mut();
        // The live-tree override always makes nix report a modified lock it
        // refused to write. That is the intended mode, not news, and its body
        // is the whole input diff. Everything else is kept with its body.
        let mut skip_body = false;
        for line in stderr.lines() {
            let trimmed = line.trim_end();
            if trimmed.trim().is_empty() {
                skip_body = false;
                continue;
            }
            if trimmed.starts_with("warning:") || trimmed.starts_with("error:") {
                skip_body = trimmed.contains("not writing modified lock file");
                if !skip_body && !warnings.iter().any(|w| w == trimmed) {
                    warnings.push(trimmed.to_string());
                }
                continue;
            }
            if skip_body {
                continue;
            }
            if (line.starts_with(' ')
                || line.starts_with('\t')
                || trimmed.starts_with('•')
                || trimmed.trim_start().starts_with('→'))
                && !warnings.iter().any(|w| w == trimmed)
            {
                // Nix puts the body of a warning on indented lines. Keeping
                // them attached avoids a bare "warning: …:" with no reason.
                if let Some(last) = warnings.last_mut() {
                    last.push('\n');
                    last.push_str(trimmed);
                }
            }
        }
    }

    /// Print nix stderr lines that have not been shown yet. Swallowing them
    /// would hide exactly the kind of input surprise this tool exists for.
    /// `warning:`/`error:` always show; the lock-update bullets are verbose.
    pub fn flush_warnings(&self) {
        let warnings = self.warnings.borrow();
        let mut flushed = self.flushed_warnings.borrow_mut();
        if *flushed >= warnings.len() {
            return;
        }
        let pending: Vec<&String> = warnings[*flushed..]
            .iter()
            .filter(|w| self.ui.verbose() || w.starts_with("warning:") || w.starts_with("error:"))
            .collect();
        if !pending.is_empty() {
            println!();
            println!("{}", self.ui.bold("nix warnings:"));
            for warning in pending {
                println!("  {}", warning.trim_start());
            }
        }
        *flushed = warnings.len();
    }

    fn inputs(&self) -> Result<Vec<(String, String)>> {
        if let Some(cached) = self.archive.borrow().as_ref() {
            return Ok(cached.clone());
        }
        let inputs = nix::archive_inputs(self)?;
        *self.archive.borrow_mut() = Some(inputs.clone());
        Ok(inputs)
    }

    fn env_flake_note(&self) -> String {
        format!(
            "path:{} + --override-input my-dotfiles path:{}",
            self.deploy.display(),
            self.dotfiles.display()
        )
    }
}

pub fn home_profile() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join(".local/state/nix/profiles/home-manager"))
}

fn baseline_for(target: Target) -> Option<String> {
    let path = match target {
        Target::System => PathBuf::from("/run/current-system"),
        Target::Home => home_profile()?,
    };
    cmd::resolve(&path).map(|p| p.display().to_string())
}

fn short_sha(sha: &str) -> String {
    sha.chars().take(12).collect()
}

/// `/usr/local/sbin//power.sh` and `/usr/local/sbin/./power.sh` are the same
/// link. The multiplicity check must not be fooled by spelling.
fn same_link(a: &str, b: &str) -> bool {
    Path::new(a).components().eq(Path::new(b).components())
}

fn rel_path(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .display()
        .to_string()
}

/// Mark lines that touch the root helper or the repo's own packages.
fn highlight(ui: &Ui, line: &str) -> String {
    if line.contains("scripts/power.sh") {
        format!("{} {}", ui.red("»"), ui.bold(line))
    } else if line.contains("pkgs/") {
        format!("{} {line}", ui.yellow("»"))
    } else {
        format!("  {line}")
    }
}

fn print_git_block(ui: &Ui, label: &str, repo: &Path, baseline: Option<&str>) {
    ui.sub(label);
    if !git::is_repo(repo) {
        ui.kv(label, "not a git repository");
        return;
    }
    let head = git::head(repo).unwrap_or_else(|| "<unknown>".into());
    ui.kv(
        "HEAD",
        &format!(
            "{} ({})",
            head.chars().take(7).collect::<String>(),
            repo.display()
        ),
    );

    if let Some(base) = baseline {
        if !git::rev_exists(repo, base) {
            ui.note(&format!(
                "  baseline {base} is not in this repo (history rewritten?); showing worktree only"
            ));
        } else {
            let range = format!("{base}..HEAD");
            match git::log_oneline(repo, &range) {
                Some(log) if !log.trim().is_empty() => {
                    let lines: Vec<&str> = log.lines().filter(|l| !l.trim().is_empty()).collect();
                    println!(
                        "  {:<16} {} commit(s) since {}",
                        "commits:",
                        lines.len(),
                        base.chars().take(7).collect::<String>()
                    );
                    for line in lines
                        .iter()
                        .take(if ui.verbose() { usize::MAX } else { 10 })
                    {
                        println!("    {line}");
                    }
                    if !ui.verbose() && lines.len() > 10 {
                        ui.note(&format!("    … {} more (--verbose)", lines.len() - 10));
                    }
                }
                _ => println!("  {:<16} none", "commits:"),
            }

            if let Some(diff) = git::diff_stat(repo, base) {
                if !diff.trim().is_empty() {
                    println!("  {:<16}", "worktree vs base:");
                    for line in diff.lines() {
                        println!("{}", highlight(ui, line));
                    }
                }
            }
        }
    }

    match git::status_porcelain(repo) {
        Some(status) if !status.trim().is_empty() => {
            let count = git::dirty_count(&status);
            println!(
                "  {:<16} {} entr{}",
                "dirty:",
                count,
                if count == 1 { "y" } else { "ies" }
            );
            for line in status.lines().filter(|l| !l.trim().is_empty()) {
                println!("{}", highlight(ui, line));
            }
        }
        Some(_) => println!("  {:<16} clean", "dirty:"),
        None => ui.note("  dirty: git status unavailable"),
    }
}

/// Stage 1: what changed since the recorded baseline.
fn stage_changes(ctx: &Ctx, state: &State) {
    let ui = &ctx.ui;
    ui.heading("stage 1: change tracking");
    ui.kv("eval", &ctx.env_flake_note());

    let baseline = state.last_deploy.as_ref().and_then(|d| d.commit.clone());
    match &baseline {
        Some(commit) => ui.kv(
            "baseline",
            &format!(
                "{} (recorded {})",
                commit.chars().take(7).collect::<String>(),
                state
                    .last_deploy
                    .as_ref()
                    .map(|d| d.time.clone())
                    .unwrap_or_default()
            ),
        ),
        None => ui.note("baseline: no deploy recorded yet; the first switch records one"),
    }

    print_git_block(ui, "dotfiles", &ctx.dotfiles, baseline.as_deref());
    print_git_block(ui, "deploy-system", &ctx.deploy, None);

    // Flake inputs against the snapshot taken at the last deploy.
    let lock_now = std::fs::read_to_string(ctx.deploy.join("flake.lock")).unwrap_or_default();
    match state::read_snapshot(&ctx.state_dir, "flake.lock.prev") {
        Some(prev) => {
            ui.sub("flake inputs");
            let old: Value = serde_json::from_str(&prev).unwrap_or(Value::Null);
            let new: Value = serde_json::from_str(&lock_now).unwrap_or(Value::Null);
            let diff = lockfile::diff(&old, &new);
            if diff.is_empty() {
                println!("  {:<16} unchanged since the last deploy", "lock:");
            }
            if !diff.added.is_empty() {
                ui.alert("  TRUST BOUNDARY: new flake inputs appeared");
                for node in &diff.added {
                    println!(
                        "  {} {}  {}",
                        ui.red("+"),
                        node.name,
                        node.url.clone().unwrap_or_else(|| "<no url>".into())
                    );
                    if let Some(rev) = &node.rev {
                        println!(
                            "      rev {}  {}",
                            lockfile::short_rev(rev),
                            node.last_modified
                                .map(lockfile::format_day)
                                .unwrap_or_default()
                        );
                    }
                    println!(
                        "      {}",
                        ui.dim("a new input is new code with its own build and cache trust")
                    );
                }
            }
            for node in &diff.removed {
                println!(
                    "  {} {}  {}",
                    ui.dim("-"),
                    node.name,
                    node.url.clone().unwrap_or_default()
                );
            }
            for (old_node, new_node) in &diff.changed {
                let old_rev = old_node
                    .rev
                    .as_deref()
                    .map(lockfile::short_rev)
                    .unwrap_or_else(|| "∅".into());
                let new_rev = new_node
                    .rev
                    .as_deref()
                    .map(lockfile::short_rev)
                    .unwrap_or_else(|| "∅".into());
                println!(
                    "  {} {}  {} → {}  {} → {}",
                    ui.yellow("~"),
                    new_node.name,
                    old_rev,
                    new_rev,
                    old_node
                        .last_modified
                        .map(lockfile::format_day)
                        .unwrap_or_default(),
                    new_node
                        .last_modified
                        .map(lockfile::format_day)
                        .unwrap_or_default()
                );
                if old_node.url != new_node.url {
                    println!(
                        "      url {} → {}",
                        old_node.url.clone().unwrap_or_default(),
                        new_node.url.clone().unwrap_or_default()
                    );
                }
            }
        }
        None => {
            ui.sub("flake inputs");
            ui.note("no flake.lock snapshot yet; the next deploy records one");
        }
    }

    // Submodule drift is the documented gotcha: the wrapper pins each submodule
    // separately, so a moved submodule commit needs `nix flake update <name>`.
    ui.sub("submodule drift");
    let lock: Value = serde_json::from_str(&lock_now).unwrap_or(Value::Null);
    let mut drift = false;
    for (name, node) in lockfile::nodes(&lock) {
        if name == OVERRIDDEN_INPUT {
            println!(
                "  {:<16} {name}: the live tree overrides the locked rev",
                "overridden:"
            );
            continue;
        }
        let Some(url) = node.url.as_deref() else {
            continue;
        };
        let Some(path) = lockfile::local_path(url) else {
            continue;
        };
        let path = PathBuf::from(path);
        if !path.exists() {
            println!(
                "  {:<16} {} → {name}: path {path:?} does not exist here",
                "skipped:", name
            );
            continue;
        }
        let Some(locked) = node.rev.as_deref() else {
            println!("  {:<16} {name} (path input, no locked rev)", "unpinned:");
            continue;
        };
        match git::head(&path) {
            Some(head) if head == locked => {
                if ctx.ui.verbose() {
                    println!(
                        "  {:<16} {} {}",
                        "in sync:",
                        name,
                        lockfile::short_rev(locked)
                    );
                }
            }
            Some(head) => {
                drift = true;
                ui.warn(
                    "drifted",
                    &format!(
                        "{name}: locked {} vs checkout {} ({})",
                        lockfile::short_rev(locked),
                        lockfile::short_rev(&head),
                        path.display()
                    ),
                );
            }
            None => println!(
                "  {:<16} {name}: {path:?} is not a git checkout",
                "skipped:"
            ),
        }
    }
    if drift {
        ui.note(
            "  the wrapper pins submodules separately: run `nix flake update <name>` in \
             deploy-system, or the switch will build the locked rev, not your checkout",
        );
    } else {
        println!("  {:<16} no submodule commit drift", "submodules:");
    }

    ctx.flush_warnings();
}

pub struct Built {
    pub target: Target,
    pub path: String,
    /// The drv the audited evaluation produced. The build's deriver must be
    /// this, or the tree changed between eval and build.
    pub drv: String,
    pub old: Option<String>,
    pub declared: Vec<DeclaredPkg>,
}

pub struct PowerReport {
    pub source_text: String,
    pub sha: String,
    /// Switching would change the code root executes, so the typed `apply`
    /// gate applies. Derived from the live copy first, state second.
    pub changed: bool,
    /// The live store copy's text differs from (or could not be compared to)
    /// `scripts/power.sh`. False means `changed` came from the derivation
    /// moving (runtimeInputs, nixpkgs, the generated wrapper).
    pub text_changed: bool,
    pub link: String,
    pub store_target: Option<String>,
    /// The evaluated facts this report was built from. Re-evaluated right
    /// before the switch, so an edit in between is refused instead of applied.
    pub core: nix::SystemCore,
    /// The rendered niri KDL the keybind audit read. Rechecked before the
    /// switch like the rest of the evidence.
    pub niri_config: String,
    /// Hard failures found by the audit. Any entry refuses the switch and makes
    /// `dots audit` exit non-zero: a `FAIL` line that still switches is
    /// decorative, and this audit is the reason the tool exists.
    pub problems: Vec<String>,
}

/// Whether a switch would change what root runs. The live store copy wins over
/// the recorded state: state is user-writable, and deleting it must not turn a
/// changed root helper into an ordinary prompt. `None` means the live copy could
/// not be read, so fall back to the recorded hash.
fn root_changes(recorded: &str, sha: &str, live_matches: Option<bool>) -> bool {
    match live_matches {
        Some(true) => false,
        Some(false) => true,
        None => recorded.is_empty() || recorded != sha,
    }
}

fn read_module(ctx: &Ctx, name: &str) -> Option<String> {
    std::fs::read_to_string(ctx.dotfiles.join(name)).ok()
}

/// Stage 2, static half: source scan, sudo invariant, runtime link, closure
/// availability. No build, no write.
fn stage_power_static(ctx: &Ctx, state: &State) -> Result<PowerReport> {
    let ui = &ctx.ui;
    ui.heading("stage 2: power.sh root surface");

    // The evaluated activation script names the store copy a switch would link.
    // Fetch it first: the diff below is against that copy, not a guess.
    let script_path = ctx.dotfiles.join("scripts/power.sh");
    let source_text = std::fs::read_to_string(&script_path)
        .with_context(|| format!("reading {}", script_path.display()))?;
    let sha = state::sha256_hex(source_text.as_bytes());

    // A stale copy of this file is only used by the unit tests, but it is
    // committed, so drift between it and the real helper is worth one line.
    let fixture = ctx.dotfiles.join("pkgs/dots/tests/fixtures/power.sh");
    if let Ok(fixture_text) = std::fs::read_to_string(&fixture) {
        if fixture_text != source_text {
            ui.warn(
                "fixture",
                "pkgs/dots/tests/fixtures/power.sh has drifted from scripts/power.sh (unit tests scan the old copy)",
            );
        }
    }

    let core = nix::eval_system_core(ctx)?;
    let activation_links = power::parse_activation_links(&core.power_script);
    let Some(configured_link) = activation_links.first().map(|l| l.link.clone()) else {
        bail!(
            "config.system.activationScripts.powerScript declares no `ln -sfn` for the root \
             helper; there is no link to audit"
        );
    };
    let store_target = activation_links.first().map(|l| l.target.clone());
    let runtime = power::inspect_link(&configured_link);
    ctx.flush_warnings();

    // The baseline for a root helper is what root runs right now, not only the
    // recorded hash. A missing or deleted state file must not quietly downgrade
    // a changed helper to the ordinary prompt.
    let live_text_equal = runtime
        .resolved
        .as_ref()
        .and_then(|resolved| std::fs::read_to_string(resolved).ok())
        .map(|text| power::compare_bodies(&text, &source_text).equal);
    let live_matches = match (&store_target, &runtime.resolved) {
        (Some(target), Some(resolved)) if resolved == target => live_text_equal,
        // The link is absent or points at another store path. Even with the
        // same script text, root starts running a different derivation:
        // runtimeInputs, the generated shebang, the wrapper. Gate it.
        (Some(_), _) => Some(false),
        (None, _) => None,
    };
    let recorded = state
        .last_system
        .as_ref()
        .or(state.last_deploy.as_ref())
        .map(|d| d.power_sha.clone())
        .unwrap_or_default();
    let changed = root_changes(&recorded, &sha, live_matches);
    let mut problems = Vec::new();
    if activation_links.len() != 1 {
        problems.push(format!(
            "activationScripts.powerScript declares {} `ln -sfn` line(s); exactly one is allowed",
            activation_links.len()
        ));
    }

    ui.kv("script", &script_path.display().to_string());
    let note = if changed {
        if recorded.is_empty() {
            ui.red("no baseline; this changes what root runs")
        } else {
            ui.red("changed since the last deploy")
        }
    } else if recorded.is_empty() {
        ui.green("root already runs this copy")
    } else {
        ui.green("unchanged since the last deploy")
    };
    ui.kv("sha256", &format!("{sha}  {note}"));

    // a) the diff, against the copy saved at the last deploy.
    match state::read_snapshot(&ctx.state_dir, "power.sh.prev") {
        Some(prev) if prev != source_text => {
            ui.sub("diff since the last recorded deploy");
            let prev_path = ctx.state_dir.join("power.sh.prev");
            match power::unified_diff(&prev_path, &source_text, "power") {
                Ok(diff) => {
                    let lines: Vec<&str> = diff.lines().collect();
                    let cap = if ui.verbose() { usize::MAX } else { 120 };
                    for line in lines.iter().take(cap) {
                        if line.starts_with('+') && !line.starts_with("+++") {
                            println!("{}", ui.red(line));
                        } else if line.starts_with('-') && !line.starts_with("---") {
                            println!("{}", ui.green(line));
                        } else {
                            println!("{line}");
                        }
                    }
                    if lines.len() > cap {
                        ui.note(&format!(
                            "… {} more diff lines (--verbose shows all)",
                            lines.len() - cap
                        ));
                    }
                }
                Err(err) => ui.warn("diff", &format!("could not produce a diff: {err}")),
            }
        }
        Some(_) => println!(
            "  {:<16} identical to the copy saved at the last deploy",
            "diff:"
        ),
        None => ui.note("diff: no saved copy yet; the next system switch saves one"),
    }

    // The copy root runs right now is the real baseline, whether or not dots
    // recorded a deploy. Diff it always: when the target changed, this is the
    // only diff that shows what root moves from.
    ui.sub("against the copy root runs now");
    if let Some(resolved) = &runtime.resolved {
        match std::fs::read_to_string(resolved) {
            Ok(store_text) => {
                let comparison = power::compare_bodies(&store_text, &source_text);
                let target_matches = store_target.as_deref() == Some(resolved.as_str());
                if comparison.equal {
                    if target_matches {
                        ui.ok(
                            "active copy",
                            &format!(
                                "{resolved} is already scripts/power.sh; a switch changes nothing"
                            ),
                        );
                    } else {
                        ui.warn(
                            "active copy",
                            &format!(
                                "{resolved} is byte-identical to scripts/power.sh, but the evaluated \
                                 helper is {}, so root moves to a new derivation (runtimeInputs or \
                                 nixpkgs changed)",
                                store_target.clone().unwrap_or_else(|| "<none>".into())
                            ),
                        );
                    }
                } else {
                    ui.warn(
                        "active copy",
                        &format!(
                            "{resolved} differs from scripts/power.sh; switching updates root"
                        ),
                    );
                    match cmd::temp_file("active") {
                        Ok(tmp) => {
                            if std::fs::write(&tmp, power::store_body(&store_text)).is_ok() {
                                if let Ok(diff) = power::unified_diff(&tmp, &source_text, "active")
                                {
                                    let lines: Vec<&str> = diff.lines().collect();
                                    let cap = if ui.verbose() { usize::MAX } else { 120 };
                                    for line in lines.iter().take(cap) {
                                        if line.starts_with('+') && !line.starts_with("+++") {
                                            println!("{}", ui.red(line));
                                        } else if line.starts_with('-') && !line.starts_with("---")
                                        {
                                            println!("{}", ui.green(line));
                                        } else {
                                            println!("{line}");
                                        }
                                    }
                                    if lines.len() > cap {
                                        ui.note(&format!(
                                            "… {} more diff lines (--verbose shows all)",
                                            lines.len() - cap
                                        ));
                                    }
                                }
                            }
                            let _ = std::fs::remove_file(&tmp);
                        }
                        Err(err) => {
                            ui.warn("active copy", &format!("no temp file for the diff: {err}"))
                        }
                    }
                }
                if !target_matches {
                    ui.note(&format!(
                        "evaluated target: {}",
                        store_target.clone().unwrap_or_else(|| "<none>".into())
                    ));
                }
            }
            Err(err) => ui.warn("active copy", &format!("cannot read {resolved}: {err}")),
        }
    } else {
        ui.note("active copy: the runtime link does not resolve, so nothing is live yet");
    }

    // b) the static scan.
    let scan = power::scan_source(&source_text);
    ui.sub("static scan");
    match scan.set_euo {
        Some(line) => ui.ok("shell options", &format!("set -euo pipefail (line {line})")),
        None => {
            ui.bad("shell options", "set -euo pipefail not found");
            problems.push("power.sh does not set -euo pipefail".to_string());
        }
    }

    let sysfs = scan
        .writes
        .iter()
        .filter(|w| w.class == power::WriteClass::Sysfs)
        .count();
    let devices = scan
        .writes
        .iter()
        .filter(|w| w.class == power::WriteClass::Device)
        .count();
    let flagged = scan.flagged_writes();
    if flagged.is_empty() {
        ui.ok(
            "abs writes",
            &format!(
                "{} total, {sysfs} sysfs (allowed), {devices} device (informational), 0 flagged",
                scan.writes.len()
            ),
        );
    } else {
        ui.bad(
            "abs writes",
            &format!("{} outside the sysfs allowlist", flagged.len()),
        );
        problems.push(format!(
            "{} absolute write(s) outside the sysfs allowlist at line(s) {}",
            flagged.len(),
            flagged
                .iter()
                .map(|w| w.line.to_string())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    for write in scan
        .writes
        .iter()
        .filter(|w| w.class != power::WriteClass::Device)
    {
        let class = match write.class {
            power::WriteClass::Sysfs => ui.dim("sysfs"),
            power::WriteClass::Flagged => ui.red("FLAGGED"),
            power::WriteClass::Device => ui.dim("device"),
        };
        println!("  {:>4}  {:<52} {class}", write.line, write.target);
    }
    if devices > 0 {
        ui.note("  /dev/null and friends are device sinks, listed only in --verbose");
        if ui.verbose() {
            for write in scan
                .writes
                .iter()
                .filter(|w| w.class == power::WriteClass::Device)
            {
                println!("  {:>4}  {}", write.line, write.target);
            }
        }
    }

    let mut ops: BTreeMap<&str, Vec<usize>> = BTreeMap::new();
    for (kind, line) in &scan.privileged {
        ops.entry(kind.as_str()).or_default().push(*line);
    }
    println!("  {:<16}", "privileged ops:");
    for (kind, lines) in &ops {
        println!(
            "    {kind:<14} lines {}",
            lines
                .iter()
                .map(usize::to_string)
                .collect::<Vec<_>>()
                .join(", ")
        );
    }

    if scan.substitutions.is_empty() {
        println!("  {:<16} none", "command subs:");
    } else {
        println!("  {:<16}", "command subs:");
        for (line, snippet) in &scan.substitutions {
            println!("    line {line:<4} {}", ui.dim(snippet));
        }
    }

    if scan.dangerous.is_empty() {
        ui.kv(
            "capabilities",
            "no keyword hits (blocklist, not proof: the diff and the byte-identical store copy \
             are the evidence)",
        );
    } else {
        let hits = scan
            .dangerous
            .iter()
            .map(|(w, l)| format!("{w}@{l}"))
            .collect::<Vec<_>>()
            .join(", ");
        ui.bad(
            "capabilities",
            &format!("{} hit(s): {hits}", scan.dangerous.len()),
        );
        problems.push(format!(
            "power.sh uses blocklisted command word(s) {hits}; a root helper with these needs a human decision"
        ));
    }
    let network = scan.network_commands();
    if !network.is_empty() {
        ui.alert("  network commands in a root script: review before switching");
        let hits = network
            .iter()
            .map(|(w, l)| format!("{w}@{l}"))
            .collect::<Vec<_>>()
            .join(", ");
        problems.push(format!("power.sh invokes network command(s): {hits}"));
    }

    let kills = scan.privileged.iter().filter(|(k, _)| k == "kill").count();
    if kills == 0 {
        println!("  {:<16} none", "kill guards:");
    } else if scan.unguarded_kills.is_empty() {
        ui.ok(
            "kill guards",
            &format!("{kills} kill(s), each preceded by a /proc/<pid>/comm equality guard"),
        );
    } else {
        ui.bad(
            "kill guards",
            &format!(
                "kills an unverified pid at line(s) {}",
                scan.unguarded_kills
                    .iter()
                    .map(usize::to_string)
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        );
        problems.push(format!(
            "power.sh kills an unverified pid at line(s) {}",
            scan.unguarded_kills
                .iter()
                .map(usize::to_string)
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }

    if let Some(findings) = power::shellcheck(&script_path)? {
        if findings.trim().is_empty() {
            ui.ok("shellcheck", "no findings at warning level");
        } else {
            println!("  {:<16} warning-level findings:", "shellcheck");
            for line in findings.lines() {
                println!("    {line}");
            }
        }
    } else {
        println!(
            "  {:<16} not on PATH (skipped; dots never fetches it)",
            "shellcheck:"
        );
    }

    // Closure availability: from the store copy the activation links, not from
    // guesswork.
    let mut available = BTreeMap::new();
    let mut missing = Vec::new();
    if let Some(target) = &store_target {
        let script_store = Path::new(target)
            .parent()
            .and_then(Path::parent)
            .map(|p| p.display().to_string());
        if let Some(script_store) = script_store {
            if Path::new(&script_store).exists() {
                let closure = nix::closure(&script_store)?;
                available = power::closure_commands(&closure);
            } else {
                ui.note(&format!(
                    "  closure: {script_store} is not in the store yet; run `dots system` to evaluate it"
                ));
            }
        }
    }
    let runtime_inputs = read_module(ctx, "base/system.nix")
        .map(|text| nix::read_runtime_inputs(&text))
        .unwrap_or_default();

    let invoked = scan.invoked();
    let mut outside: Vec<(String, String)> = Vec::new();
    if available.is_empty() {
        println!("  {:<16} (not built yet)", "invoked commands:");
    } else {
        println!(
            "  {:<16} {} ({} bin names in the closure)",
            "invoked commands:",
            invoked.join(" "),
            available.len()
        );
        for command in &invoked {
            match power::provider(command, &available) {
                Some(provider) => {
                    if !power::in_runtime_inputs(provider, &runtime_inputs) {
                        outside.push((command.clone(), storepath::basename(provider).to_string()));
                    }
                }
                None => {
                    if !scan.functions.contains(command) {
                        missing.push(command.clone());
                    }
                }
            }
        }
        if missing.is_empty() {
            ui.ok("closure", "every invoked command is provided");
        } else {
            ui.bad(
                "closure",
                &format!(
                    "invoked but not in the script closure: {} (runtime failure)",
                    missing.join(", ")
                ),
            );
            problems.push(format!(
                "power.sh invokes command(s) not in its closure: {}",
                missing.join(", ")
            ));
        }
        if outside.is_empty() {
            ui.ok(
                "runtimeInputs",
                &format!("{} listed, all providers covered", runtime_inputs.len()),
            );
        } else {
            ui.warn(
                "runtimeInputs",
                &format!(
                    "providers not in the module's list: {}",
                    outside
                        .iter()
                        .map(|(c, p)| format!("{c} ({p})"))
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            );
        }
        println!("  {:<16} {}", "runtime list:", runtime_inputs.join(" "));
    }

    // c) root invariants: the composed sudoers file and the evaluated
    // compositor settings are the authority. The source grep below is a
    // counter for humans, nothing more.
    ui.sub("root invariants");

    let sudoers = power::audit_sudoers(&core.sudo_config, &ctx.names.user, &configured_link);
    if sudoers.ok() {
        ui.ok(
            "eval'd rules",
            &format!(
                "composed sudoers: {}",
                sudoers.spec_line().unwrap_or_default()
            ),
        );
        ui.ok(
            "sudo cache",
            "composed sudoers: one global Defaults timestamp_timeout=0",
        );
    } else {
        for problem in &sudoers.problems {
            ui.bad("eval'd rules", problem);
            problems.push(format!("composed sudoers: {problem}"));
        }
    }

    // The activation text is what the switch runs. A second `ln -sfn` for the
    // same link, later in the composed script, would win over the audited one.
    // `activationScripts.script` is the composed script (the same body
    // /run/current-system/activate gets); concatenating every snippet would
    // count the powerScript snippet twice, once on its own and once embedded.
    let merged_links = power::parse_activation_links(&core.activation_text);
    let to_link: Vec<&power::ActivationLink> = merged_links
        .iter()
        .filter(|l| same_link(&l.link, &configured_link))
        .collect();
    match to_link.as_slice() {
        [only] => {
            let audited = store_target.clone().unwrap_or_default();
            if only.target == audited {
                ui.ok(
                    "activation",
                    &format!("exactly one ln -sfn {} {}", only.target, only.link),
                );
            } else {
                ui.bad(
                    "activation",
                    &format!(
                        "the composed activation script links {} → {}, the powerScript snippet says {audited}",
                        only.link, only.target
                    ),
                );
                problems.push(format!(
                    "the composed activation script links {} to {}, not the audited {audited}",
                    only.link, only.target
                ));
            }
        }
        [] => {
            ui.bad(
                "activation",
                &format!("the composed activation script never links {configured_link}"),
            );
            problems.push(format!(
                "the composed activation script does not link {configured_link}"
            ));
        }
        many => {
            ui.bad(
                "activation",
                &format!(
                    "the composed activation script links {configured_link} {} times: {}",
                    many.len(),
                    many.iter()
                        .map(|l| format!("{} → {}", l.link, l.target))
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            );
            problems.push(format!(
                "the composed activation script links {configured_link} {} times; exactly one is allowed",
                many.len()
            ));
        }
    }

    let binds = match nix::eval_niri_config(ctx) {
        Ok(text) => Some(text),
        Err(err) => {
            ui.bad(
                "keybinds",
                &format!("could not evaluate programs.niri.finalConfig: {err:#}"),
            );
            problems.push(format!(
                "could not evaluate programs.niri.finalConfig to check sudo calls: {err:#}"
            ));
            None
        }
    };
    if let Some(config) = &binds {
        let keybinds = power::audit_niri_config(config, &configured_link);
        if keybinds.ok() {
            ui.ok(
                "keybinds",
                &format!(
                    "eval'd programs.niri.finalConfig (the rendered KDL): {} sudo call(s), \
                     every one targets {configured_link}",
                    keybinds.sudo_calls
                ),
            );
        } else {
            for problem in &keybinds.problems {
                ui.bad("keybind", problem);
                problems.push(format!("keybind: {problem}"));
            }
        }
    }

    // Informational only: a rule can be declared in extraConfig, in another
    // module, or outside .nix entirely, so this is not evidence.
    let mut files: Vec<(String, String)> = Vec::new();
    for path in git::files(&ctx.dotfiles) {
        if let Ok(text) = std::fs::read_to_string(&path) {
            files.push((rel_path(&ctx.dotfiles, &path), text));
        }
    }
    let apps: Vec<String> = files
        .iter()
        .map(|(p, _)| p.clone())
        .filter(|p| p.starts_with("apps/") && p.ends_with(".nix"))
        .collect();
    let sources = power::scan_sources(&files, &apps);
    println!(
        "  {:<16} {} NOPASSWD mention(s) in the checked-in files (informational: the composed \
         file above is authoritative)",
        "source grep:",
        sources.nopasswd.len()
    );
    let mentioned_files: Vec<String> = {
        let mut files: Vec<String> = sources
            .sudo_mentions
            .iter()
            .filter_map(|entry| entry.rsplit_once(':').map(|(f, _)| f.to_string()))
            .collect();
        files.sort();
        files.dedup();
        files
    };
    println!(
        "  {:<16} {} sudo mention(s) in {} (informational: the eval'd finalConfig above is \
         authoritative)",
        "keybind grep:",
        sources.sudo_mentions.len(),
        if mentioned_files.is_empty() {
            "no app module".to_string()
        } else {
            mentioned_files.join(", ")
        }
    );

    match (&runtime.resolved, runtime.uid, runtime.mode) {
        (Some(resolved), Some(uid), Some(mode)) if runtime.ok() => ui.ok(
            "runtime link",
            &format!(
                "{configured_link} → {resolved} (uid {uid}, mode {:04o})",
                mode & 0o7777
            ),
        ),
        _ => {
            ui.bad(
                "runtime link",
                &format!("{configured_link} is not a safe store link"),
            );
            problems.push(format!(
                "{configured_link} is not a safe store link: {}",
                runtime.problems.join("; ")
            ));
            for problem in &runtime.problems {
                println!("    {problem}");
            }
        }
    }
    if let Some(target) = &store_target {
        println!(
            "  {:<16} {target} (declared by activationScripts.powerScript)",
            "audited target:"
        );
    }

    ctx.flush_warnings();

    Ok(PowerReport {
        source_text,
        sha,
        changed,
        text_changed: live_text_equal != Some(true),
        link: configured_link,
        store_target,
        core,
        niri_config: binds.unwrap_or_default(),
        problems,
    })
}

fn build_target(ctx: &Ctx, target: Target) -> Result<Built> {
    let ui = &ctx.ui;
    ui.sub(&format!("build {}", target.label()));
    println!("  {:<16} {}", "target:", nix::build_attr(ctx, target));
    // The drv of the evaluation that was just audited. Binding the build to it
    // closes the gap where the wrapper flake (or the live tree) changes between
    // eval and build and the switch would install something never audited.
    let drv = nix::eval_drv(ctx, target)?;
    let path = nix::build(ctx, target)?;
    let built_drv = nix::deriver(&path)?;
    if built_drv != drv {
        bail!(
            "the tree changed between eval and build for {}: evaluated {drv}, built {built_drv}. \
             Re-run `dots {}` so the audit covers what would be switched.",
            target.label(),
            target.label()
        );
    }
    ui.ok("derivation", &format!("{drv} (the evaluated drv)"));
    ui.kv("built", &path);
    let old = baseline_for(target);
    match &old {
        Some(old) if *old == path => ui.ok("baseline", &format!("{old} (no change)")),
        Some(old) => ui.kv("baseline", old),
        None => ui.note("baseline: nothing installed yet"),
    }
    let declared = nix::packages(ctx, target)?;
    ctx.flush_warnings();
    Ok(Built {
        target,
        path,
        drv,
        old,
        declared,
    })
}

fn find_dots_binary(closure: &[String]) -> Option<String> {
    closure
        .iter()
        .find(|path| Path::new(path).join("bin/dots").exists())
        .cloned()
}

/// Stage 3: the closure diff, with provenance.
fn report_packages(ctx: &Ctx, built: &Built) -> Result<()> {
    let ui = &ctx.ui;
    ui.heading(&format!("stage 3: packages ({})", built.target.label()));

    let new_closure = nix::closure(&built.path)?;
    let old_closure = match &built.old {
        Some(old) => nix::closure(old).unwrap_or_default(),
        None => Vec::new(),
    };
    let (added, removed) = pkgscan::set_diff(&old_closure, &new_closure);

    let mut all = added.clone();
    all.extend(removed.iter().cloned());
    let info = nix::path_info(&all).unwrap_or_default();
    let size_of = |path: &str| info.get(path).map(|i| i.nar_size).unwrap_or(0);

    let added_bytes: u64 = added.iter().map(|p| size_of(p)).sum();
    let removed_bytes: u64 = removed.iter().map(|p| size_of(p)).sum();

    ui.kv(
        "closure",
        &format!("{} → {} paths", old_closure.len(), new_closure.len()),
    );
    ui.kv(
        "added",
        &format!("{} paths, {}", added.len(), human_size(added_bytes)),
    );
    ui.kv(
        "removed",
        &format!("{} paths, {}", removed.len(), human_size(removed_bytes)),
    );

    // Declared packages give positions, positions give the input. An archive
    // failure is cosmetic (offline, say): keep the diff and mark origins unknown
    // instead of aborting the deploy.
    let inputs = match ctx.inputs() {
        Ok(inputs) => inputs,
        Err(err) => {
            ui.warn(
                "provenance",
                &format!("cannot read flake inputs ({err}); origins will show as ?"),
            );
            Vec::new()
        }
    };
    let declared_by_out: BTreeMap<&str, &DeclaredPkg> =
        built.declared.iter().map(|p| (p.out.as_str(), p)).collect();

    let mut origin_of: BTreeMap<String, String> = BTreeMap::new();
    let mut input_of: BTreeMap<String, String> = BTreeMap::new();
    let mut declared_added = 0usize;
    for path in &added {
        if let Some(pkg) = declared_by_out.get(path.as_str()) {
            declared_added += 1;
            if let Some(position) = &pkg.position {
                if let Some(input) = pkgscan::attribute_position(position, &inputs) {
                    let label = pkgscan::input_label(&input);
                    origin_of.insert(path.clone(), label.clone());
                    input_of.insert(path.clone(), label);
                } else {
                    origin_of.insert(path.clone(), format!("declared ({})", pub_trim(position)));
                }
            } else {
                origin_of.insert(path.clone(), "declared".to_string());
            }
        }
    }

    // Undeclared paths: find a newly added declared package whose closure has
    // them. Capped, because each check is a `nix-store -qR`.
    let candidates: Vec<&DeclaredPkg> = built
        .declared
        .iter()
        .filter(|p| added.iter().any(|a| a == &p.out))
        .collect();
    let cap = 12;
    for path in &added {
        if origin_of.contains_key(path) {
            continue;
        }
        if candidates.len() > cap {
            origin_of.insert(path.clone(), "dependency".to_string());
            continue;
        }
        let mut found = None;
        for pkg in &candidates {
            if let Ok(closure) = nix::closure(&pkg.out) {
                if closure.iter().any(|c| c == path) {
                    found = Some(pkg.name.clone());
                    break;
                }
            }
        }
        match found {
            Some(name) => {
                origin_of.insert(path.clone(), format!("dep:{name}"));
            }
            None => {
                origin_of.insert(path.clone(), "dependency".to_string());
            }
        }
    }

    let mut rows: Vec<(u64, String, String, String, String)> = Vec::new();
    for path in &added {
        // Strip the store hash before splitting name from version.
        let display_name = match storepath::parse(path) {
            Some(parsed) => match storepath::split_name_version(&parsed.name) {
                (name, Some(version)) => format!("{name} {version}"),
                (name, None) => name,
            },
            None => storepath::basename(path).to_string(),
        };
        let origin = origin_of
            .get(path)
            .cloned()
            .unwrap_or_else(|| "dependency".into());
        let input = input_of.get(path).cloned().unwrap_or_default();
        let label = if !input.is_empty() {
            input.clone()
        } else {
            // A dash here used to read as "nothing to see", i.e. nixpkgs.
            // `?` means the origin is genuinely unknown (a dependency or a
            // package without meta.position), not a clean bill of health.
            "?".to_string()
        };
        let note = if input.is_empty() {
            origin.clone()
        } else {
            String::new()
        };
        let signatures = info
            .get(path)
            .map(|i| i.signatures.clone())
            .unwrap_or_default();
        let cache = pkgscan::cache_provenance(&signatures);
        rows.push((size_of(path), display_name, label, cache.to_string(), note));
    }
    rows.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));

    println!();
    println!(
        "  added paths, largest first{}:",
        if added.len() > 25 && !ui.verbose() {
            " (top 25)"
        } else {
            ""
        }
    );
    if rows.is_empty() {
        println!("    none");
    }
    let limit = if ui.verbose() { usize::MAX } else { 25 };
    for (size, name, label, cache, note) in rows.iter().take(limit) {
        let non_nixpkgs = label != "?" && label != "nixpkgs";
        let marker = if non_nixpkgs {
            ui.yellow("!")
        } else {
            " ".to_string()
        };
        let label = if label.chars().count() > 12 {
            let short: String = label.chars().take(11).collect();
            format!("{short}…")
        } else {
            label.clone()
        };
        println!(
            "  {:>10}  {marker}{:<12} {:<46} {:<11} {}",
            human_size(*size),
            label,
            name,
            cache,
            ui.dim(note)
        );
    }
    if rows.len() > limit {
        ui.note(&format!("    … {} more (--verbose)", rows.len() - limit));
    }

    // Non-nixpkgs paths deserve their own line: that is the supply-chain
    // question, not a formatting detail.
    let mut by_input: BTreeMap<String, usize> = BTreeMap::new();
    let mut unattributed = 0usize;
    for path in &added {
        match input_of.get(path) {
            Some(input) if input != "nixpkgs" => {
                *by_input.entry(input.clone()).or_insert(0) += 1;
            }
            Some(_) => {}
            None => unattributed += 1,
        }
    }
    if declared_added > 0 || !by_input.is_empty() || unattributed > 0 {
        ui.sub("provenance");
        println!(
            "  {:<16} {} of {} added paths are declared packages",
            "declared:",
            declared_added,
            added.len()
        );
        if by_input.is_empty() {
            println!("  {:<16} none", "non-nixpkgs:");
        } else {
            for (input, count) in &by_input {
                println!(
                    "  {:<16} {} {count} path(s) — {}",
                    "non-nixpkgs:",
                    ui.yellow(&format!("!{input}")),
                    "not reviewed by anyone but that input"
                );
            }
        }
        if unattributed > 0 {
            println!(
                "  {:<16} {unattributed} path(s) — no meta.position or a dependency; origin unknown, not nixpkgs",
                "unattributed:"
            );
        }
        println!(
            "  {:<16} ! = declared package from a non-nixpkgs input; ? = origin not attributed; dep:<pkg> = closure of a new declared package",
            "legend:"
        );
    }

    // Upgrades from the closure diff.
    let changes = built
        .old
        .as_ref()
        .map(|old| nix::diff_closures(old, &built.path))
        .transpose()?
        .unwrap_or_default();
    let parsed = pkgscan::parse_diff_closures(&changes);
    let upgrades: Vec<&pkgscan::ClosureChange> = parsed.iter().filter(|c| c.is_upgrade()).collect();
    ui.sub("upgrades");
    if upgrades.is_empty() {
        println!("  {:<16} none", "versions:");
    } else {
        let limit = if ui.verbose() { usize::MAX } else { 20 };
        for change in upgrades.iter().take(limit) {
            println!(
                "  {:<40} {} → {}  {}",
                change.name,
                change.old.clone().unwrap_or_default(),
                change.new.clone().unwrap_or_default(),
                change.delta.map(human_delta).unwrap_or_default()
            );
        }
        if upgrades.len() > limit {
            ui.note(&format!("  … {} more (--verbose)", upgrades.len() - limit));
        }
    }

    // The tool's own binary, old vs new.
    ui.sub("dots binary");
    let new_dots = find_dots_binary(&new_closure);
    let old_dots = built
        .old
        .as_ref()
        .and_then(|old| nix::closure(old).ok())
        .and_then(|closure| find_dots_binary(&closure));
    match (&old_dots, &new_dots) {
        (Some(old), Some(new)) if old == new => ui.ok("unchanged", new),
        (Some(old), Some(new)) => {
            ui.warn("changed", &format!("{old} → {new}"));
        }
        (None, Some(new)) => ui.kv("deployed", &format!("{new} (first time)")),
        (_, None) if built.target == Target::Home => ui.note(
            "dots is a system package; a home switch cannot change the binary that runs this",
        ),
        (_, None) => ui.note("the new closure does not ship dots"),
    }

    Ok(())
}

fn pub_trim(position: &str) -> String {
    position.split('/').take(4).collect::<Vec<_>>().join("/")
}

/// After the build: prove the linked store copy is the audited source.
fn verify_power_built(ctx: &Ctx, report: &mut PowerReport, built: &Built) -> Result<()> {
    if !built.target.touches_root() {
        return Ok(());
    }
    let ui = &ctx.ui;
    ui.sub("power.sh store copy");

    let Some(target) = &report.store_target else {
        ui.bad(
            "activation",
            "no ln -sfn target found in activationScripts.powerScript",
        );
        report
            .problems
            .push("no power.sh link target found in activationScripts.powerScript".to_string());
        return Ok(());
    };
    let store_dir = Path::new(target).parent().and_then(Path::parent);
    let Some(store_dir) = store_dir else {
        ui.bad(
            "activation",
            &format!("cannot derive the store directory from {target}"),
        );
        report.problems.push(format!(
            "cannot derive the power.sh store directory from {target}"
        ));
        return Ok(());
    };
    let store_dir = store_dir.display().to_string();

    let closure = nix::closure(&built.path)?;
    if closure.iter().any(|p| p == &store_dir) {
        ui.ok(
            "in closure",
            &format!("{store_dir} is part of {}", built.path),
        );
    } else {
        ui.bad(
            "in closure",
            &format!("{store_dir} is NOT in the new system closure"),
        );
        report.problems.push(format!(
            "{store_dir} is not in the new system closure {}",
            built.path
        ));
    }

    match std::fs::read_to_string(target) {
        Ok(store_text) => {
            let comparison = power::compare_bodies(&store_text, &report.source_text);
            if comparison.equal {
                ui.ok(
                    "byte compare",
                    &format!(
                        "store copy == scripts/power.sh minus its shebang ({} vs {} bytes incl. generated header)",
                        comparison.store_bytes, comparison.source_bytes
                    ),
                );
            } else {
                ui.bad(
                    "byte compare",
                    &format!(
                        "{}: store {} bytes, source {} bytes",
                        comparison.note, comparison.store_bytes, comparison.source_bytes
                    ),
                );
                report.problems.push(format!(
                    "the store copy root will run is not scripts/power.sh: {}",
                    comparison.note
                ));
            }
        }
        Err(err) => {
            ui.bad("byte compare", &format!("cannot read {target}: {err}"));
            report.problems.push(format!(
                "cannot read the power.sh store copy {target}: {err}"
            ));
        }
    }
    Ok(())
}

/// The decision behind the prompt, separated from stdin so the two rules that
/// matter are testable: `--yes` never answers the strict question, and a strict
/// switch needs the exact word `apply`.
fn confirm_decision(strict: bool, yes: bool, typed: Option<&str>) -> Result<bool> {
    if strict {
        if yes {
            bail!(
                "scripts/power.sh changed and will run as root; --yes cannot skip the typed `apply` confirmation. Run `dots system` interactively."
            );
        }
        return Ok(typed.map(|line| line.trim() == "apply").unwrap_or(false));
    }
    if yes {
        return Ok(true);
    }
    Ok(typed
        .map(|line| matches!(line.trim().to_ascii_lowercase().as_str(), "y" | "yes"))
        .unwrap_or(false))
}

/// Ask before the switch. A changed root helper must be acknowledged by typing
/// the word, not by pressing enter.
fn confirm(ctx: &Ctx, strict: bool, text_changed: bool) -> Result<bool> {
    let ui = &ctx.ui;
    println!();
    if strict {
        // Checked before anything is printed: --yes must not even reach the
        // prompt for the one question that exists because the new code is root.
        if ctx.yes {
            return confirm_decision(true, true, None);
        }
        if text_changed {
            ui.alert("scripts/power.sh changed since the last recorded deploy.");
        } else {
            ui.alert(
                "The root helper's derivation changed; scripts/power.sh itself is byte-identical.",
            );
            println!(
                "\nThe store path moved because runtimeInputs, nixpkgs, or the generated wrapper \
                 changed. Root still gets a different build."
            );
        }
        println!();
        println!(
            "The new copy runs as root through the NOPASSWD sudo rule. Read the diff above;\n\
             the store copy is byte-identical to the source, so what you read is what runs."
        );
        println!();
        print!("Type `apply` to switch, anything else aborts: ");
        std::io::stdout().flush().ok();
        let mut line = String::new();
        if std::io::stdin().read_line(&mut line).is_err() {
            return Ok(false);
        }
        return confirm_decision(true, false, Some(&line));
    }

    if ctx.yes {
        ui.kv("prompt", "skipped (--yes)");
        return Ok(true);
    }

    print!("Switch now? [y/N] ");
    std::io::stdout().flush().ok();
    let mut line = String::new();
    if std::io::stdin().read_line(&mut line).is_err() {
        return Ok(false);
    }
    confirm_decision(false, false, Some(&line))
}

fn switch_command(ctx: &Ctx, target: Target) -> Result<(PathBuf, Vec<String>)> {
    // The wrapper lock is the timer's source of truth. The override would make
    // nix refuse to write a lock it would have to modify, and
    // `--no-write-lock-file` says so explicitly: a manual switch must never
    // rewrite it, even in the cases where nix would still allow a write.
    let common = vec![
        "--flake".to_string(),
        ctx.deploy.display().to_string(),
        "--override-input".to_string(),
        "my-dotfiles".to_string(),
        format!("path:{}", ctx.dotfiles.display()),
        "--no-write-lock-file".to_string(),
    ];
    match target {
        Target::System => {
            let sudo = cmd::sudo()?;
            let rebuild = cmd::nixos_rebuild()?;
            let mut args = vec![rebuild.display().to_string(), "switch".to_string()];
            args.extend(common);
            Ok((sudo, args))
        }
        Target::Home => {
            let home_manager = cmd::home_manager()?;
            let mut args = vec!["switch".to_string()];
            args.extend(common);
            Ok((home_manager, args))
        }
    }
}

fn run_switch(ctx: &Ctx, target: Target) -> Result<bool> {
    let ui = &ctx.ui;
    let (prog, args) = switch_command(ctx, target)?;
    let mut parts = vec![prog.display().to_string()];
    parts.extend(args.iter().cloned());
    let shown = cmd::shell_join(&parts);
    println!();
    ui.kv("switching", &shown);

    let status = cmd::run_stream(&prog, &args)?;
    if !status.success() {
        println!();
        ui.bad("switch", &format!("{shown} failed ({status})"));
        return Ok(false);
    }
    ui.ok("switched", target.label());
    Ok(true)
}

/// Post-switch verification. This is the last place the tool can notice that
/// the switch installed something other than the audited build, so a mismatch
/// is an error: the deploy is not recorded and the state file is not written.
fn post_switch(ctx: &Ctx, report: &PowerReport, built: &Built) -> Result<()> {
    let ui = &ctx.ui;
    ui.sub("post-switch");
    let mut problems: Vec<String> = Vec::new();

    if built.target == Target::System {
        match cmd::resolve(Path::new("/run/current-system")).map(|p| p.display().to_string()) {
            Some(current) if current == built.path => {
                ui.ok("activated", &format!("{current} is the audited build"))
            }
            Some(current) => {
                ui.bad(
                    "activated",
                    &format!("/run/current-system is {current}, audited {}", built.path),
                );
                problems.push(format!(
                    "/run/current-system is {current}, but this run built and audited {}",
                    built.path
                ));
            }
            None => {
                ui.bad("activated", "/run/current-system does not resolve");
                problems.push("/run/current-system does not resolve".to_string());
            }
        }

        // The activated activation script is the only truth about what got
        // linked. More than one link to the audited path means a later one won.
        let activate = std::fs::read_to_string("/run/current-system/activate").unwrap_or_default();
        if activate.trim().is_empty() {
            ui.bad("activated link", "/run/current-system/activate is empty");
            problems.push("/run/current-system/activate is empty".to_string());
        } else {
            let links = power::parse_activation_links(&activate);
            let matching: Vec<&power::ActivationLink> = links
                .iter()
                .filter(|l| same_link(&l.link, &report.link))
                .collect();
            match matching.as_slice() {
                [only] => {
                    let audited = report.store_target.clone().unwrap_or_default();
                    if only.target == audited {
                        ui.ok(
                            "activated link",
                            &format!("{} → {}", only.link, only.target),
                        );
                    } else {
                        ui.bad(
                            "activated link",
                            &format!(
                                "the activated system links {} → {}, audited {audited}",
                                only.link, only.target
                            ),
                        );
                        problems.push(format!(
                            "the activated system links {} to {}, not the audited {audited}",
                            only.link, only.target
                        ));
                    }
                    match std::fs::read_to_string(&only.target) {
                        Ok(text) => {
                            let comparison = power::compare_bodies(&text, &report.source_text);
                            if comparison.equal {
                                ui.ok("store copy", "activated copy matches scripts/power.sh");
                            } else {
                                ui.bad(
                                    "store copy",
                                    &format!("activated copy {}", comparison.note),
                                );
                                problems
                                    .push(format!("the activated store copy {}", comparison.note));
                            }
                        }
                        Err(err) => {
                            ui.bad("store copy", &format!("cannot read {}: {err}", only.target));
                            problems.push(format!(
                                "cannot read the activated store copy {}: {err}",
                                only.target
                            ));
                        }
                    }
                }
                [] => {
                    ui.bad(
                        "activated link",
                        &format!(
                            "no ln -sfn … {} in /run/current-system/activate",
                            report.link
                        ),
                    );
                    problems.push(format!(
                        "the activated system has no link for {}",
                        report.link
                    ));
                }
                many => {
                    ui.bad(
                        "activated link",
                        &format!(
                            "the activated system links {} {} times",
                            report.link,
                            many.len()
                        ),
                    );
                    problems.push(format!(
                        "the activated system links {} {} times; exactly one is audited",
                        report.link,
                        many.len()
                    ));
                }
            }
        }
    }

    if built.target == Target::Home {
        if let Some(profile) = home_profile() {
            match cmd::resolve(&profile).map(|p| p.display().to_string()) {
                Some(current) if current == built.path => {
                    ui.ok("activated", &format!("{current} is the audited build"))
                }
                Some(current) => {
                    ui.bad(
                        "activated",
                        &format!("{profile:?} is {current}, audited {}", built.path),
                    );
                    problems.push(format!(
                        "{profile:?} is {current}, but this run built and audited {}",
                        built.path
                    ));
                }
                None => {
                    ui.bad("activated", "home profile does not resolve");
                    problems.push("the home-manager profile does not resolve".to_string());
                }
            }
        }
    }

    // A home switch cannot relink the root helper. Checking it there would
    // compare the system target of the next build with the link home did not
    // touch, and fail a successful switch.
    if built.target == Target::System {
        let runtime = power::inspect_link(&report.link);
        let audited = report.store_target.clone().unwrap_or_default();
        match (&runtime.resolved, runtime.uid, runtime.mode) {
            (Some(resolved), Some(uid), Some(mode)) if runtime.ok() && *resolved == audited => ui
                .ok(
                    "runtime link",
                    &format!(
                        "{} → {resolved} (uid {uid}, mode {:04o})",
                        report.link,
                        mode & 0o7777
                    ),
                ),
            _ => {
                ui.bad(
                    "runtime link",
                    &format!(
                        "{} does not canonicalize to the audited {audited}",
                        report.link
                    ),
                );
                problems.push(format!(
                    "{} does not canonicalize to the audited target {audited}: resolved {:?}; {}",
                    report.link,
                    runtime.resolved,
                    runtime.problems.join("; ")
                ));
                for problem in &runtime.problems {
                    println!("    {problem}");
                }
            }
        }
    }

    ui.note(
        "the scan above is static; the decisive evidence is the diff and the byte-identical store copy",
    );

    if !problems.is_empty() {
        println!();
        for problem in &problems {
            println!("  - {problem}");
        }
        bail!(
            "post-switch verification failed ({} problem(s)); the deploy was not recorded",
            problems.len()
        );
    }
    Ok(())
}

/// The repo state the build was produced from. Taken before the build so a
/// commit or a lock edit during the run cannot be attributed to the result.
#[derive(Debug, Clone)]
pub struct RepoSnapshot {
    pub commit: Option<String>,
    pub dirty: bool,
    pub lock_sha: String,
    /// The lock file as it was when the build started: the `flake.lock.prev`
    /// baseline must describe the tree that was built, not a later edit.
    pub lock_text: String,
}

fn snapshot_repo(ctx: &Ctx) -> RepoSnapshot {
    let lock_text = std::fs::read_to_string(ctx.deploy.join("flake.lock")).unwrap_or_default();
    RepoSnapshot {
        commit: git::head(&ctx.dotfiles).map(|h| h.chars().take(7).collect::<String>()),
        dirty: git::status_porcelain(&ctx.dotfiles)
            .map(|s| git::dirty_count(&s) > 0)
            .unwrap_or(true),
        lock_sha: state::sha256_hex(lock_text.as_bytes()),
        lock_text,
    }
}

fn record(
    ctx: &Ctx,
    state: &mut State,
    snapshot: &RepoSnapshot,
    report: &PowerReport,
    built: &[Built],
) -> Result<()> {
    for target in built {
        let power_sha = if target.target.touches_root() {
            report.sha.clone()
        } else {
            // A home switch cannot change the root helper; keep the last root
            // deploy's hash so `status` and the next gate read the truth.
            state
                .last_system
                .as_ref()
                .map(|d| d.power_sha.clone())
                .unwrap_or_default()
        };
        let deploy = Deploy {
            time: state::format_timestamp(state::now_epoch()),
            target: target.target.label().to_string(),
            commit: snapshot.commit.clone(),
            dirty: snapshot.dirty,
            lock_sha: snapshot.lock_sha.clone(),
            power_sha,
            result: Some(target.path.clone()),
            exe: ctx.self_info.exe.clone(),
            source: ctx.self_info.source.clone().unwrap_or_default(),
            paths: vec![target.path.clone()],
        };
        state.record(deploy.clone(), target.target.touches_root());
        state::append_log(&ctx.state_dir, &deploy)?;
    }
    state.save(&ctx.state_dir)?;

    // The snapshots are the baseline for the next run. `power.sh.prev` tracks
    // the last deploy that actually linked the root helper, which is the only
    // baseline a diff against root can honestly use.
    if !snapshot.lock_text.is_empty() {
        state::write_snapshot(&ctx.state_dir, "flake.lock.prev", &snapshot.lock_text)?;
    }
    if built.iter().any(|b| b.target.touches_root()) {
        state::write_snapshot(&ctx.state_dir, "power.sh.prev", &report.source_text)?;
    }
    Ok(())
}

/// Re-read and re-evaluate everything the audit relied on, right before the
/// switch. This does not make the eval→activation window disappear; it makes a
/// change inside it visible instead of silently applied.
fn recheck_before_switch(ctx: &Ctx, report: &PowerReport, built: &[Built]) -> Result<()> {
    let ui = &ctx.ui;
    ui.sub("pre-switch recheck");
    let mut changed: Vec<String> = Vec::new();

    let script_path = ctx.dotfiles.join("scripts/power.sh");
    match std::fs::read_to_string(&script_path) {
        Ok(text) => {
            let sha = state::sha256_hex(text.as_bytes());
            if sha != report.sha {
                changed.push(format!(
                    "scripts/power.sh changed since the audit ({sha} != {})",
                    report.sha
                ));
            }
        }
        Err(err) => changed.push(format!("cannot re-read {}: {err}", script_path.display())),
    }

    match nix::eval_system_core(ctx) {
        Ok(core) => {
            if core.power_script != report.core.power_script {
                changed.push("the power.sh activation snippet changed".to_string());
            }
            if core.activation_text != report.core.activation_text {
                changed.push("the composed activation script changed".to_string());
            }
            if core.sudo_config != report.core.sudo_config {
                changed.push("the composed sudoers file changed".to_string());
            }
            if core.toplevel_drv != report.core.toplevel_drv {
                changed.push(format!(
                    "the system toplevel drv changed ({} != {})",
                    core.toplevel_drv, report.core.toplevel_drv
                ));
            }
        }
        Err(err) => changed.push(format!(
            "re-evaluating the system configuration failed: {err:#}"
        )),
    }

    match nix::eval_niri_config(ctx) {
        Ok(config) if config == report.niri_config => {}
        Ok(_) => changed.push("programs.niri.finalConfig changed".to_string()),
        Err(err) => changed.push(format!(
            "re-evaluating programs.niri.finalConfig failed: {err:#}"
        )),
    }

    for b in built {
        match nix::eval_drv(ctx, b.target) {
            Ok(drv) if drv == b.drv => {}
            Ok(drv) => changed.push(format!(
                "the {} drv changed since the build ({} != {})",
                b.target.label(),
                drv,
                b.drv
            )),
            Err(err) => changed.push(format!(
                "re-evaluating the {} drv failed: {err:#}",
                b.target.label()
            )),
        }
    }

    if changed.is_empty() {
        ui.ok(
            "unchanged",
            "power.sh, activation scripts, composed sudoers, niri config and drv paths are what the audit saw",
        );
        return Ok(());
    }
    for entry in &changed {
        ui.bad("changed", entry);
    }
    bail!(
        "the tree changed between the audit and the switch ({}); nothing was switched and no \
         state was written",
        changed.join("; ")
    );
}

fn print_integrity(ctx: &Ctx, state: &State) {
    let ui = &ctx.ui;
    ui.heading("stage 0: tool integrity (checked before anything else)");
    if ctx.self_info.skipped {
        ui.alert("SELF-CHECK SKIPPED: DOTS_SKIP_SELF_CHECK=1");
        return;
    }
    ui.ok(
        "exe",
        &format!(
            "{} (uid 0, not group/other writable, store-verified)",
            ctx.self_info.exe
        ),
    );
    match &ctx.self_info.source {
        Some(source) => ui.ok("built from", &format!("{source} (store-verified)")),
        None => ui.bad("built from", "no embedded DOTS_SOURCE"),
    }
    match &state.last_deploy {
        Some(deploy) => {
            if deploy.exe != ctx.self_info.exe {
                ui.warn(
                    "exe changed",
                    &format!("{} → {}", deploy.exe, ctx.self_info.exe),
                );
            } else {
                println!("  {:<16} unchanged since the last deploy", "exe");
            }
            if deploy.source != ctx.self_info.source.clone().unwrap_or_default() {
                ui.warn(
                    "built from changed",
                    &format!(
                        "{} → {}",
                        deploy.source,
                        ctx.self_info.source.clone().unwrap_or_default()
                    ),
                );
            }
        }
        None => ui.note("no previous deploy recorded"),
    }
}

pub fn deploy(ctx: &Ctx, targets: &[Target]) -> Result<()> {
    let state = State::load(&ctx.state_dir);
    // The snapshot is taken before the build so `dots status` describes the
    // tree that produced the result, not whatever the tree became afterwards.
    let snapshot = snapshot_repo(ctx);
    print_integrity(ctx, &state);
    stage_changes(ctx, &state);
    let mut report = stage_power_static(ctx, &state)?;

    let mut built = Vec::new();
    for target in targets {
        built.push(build_target(ctx, *target)?);
    }
    for b in &built {
        report_packages(ctx, b)?;
        verify_power_built(ctx, &mut report, b)?;
    }

    if !report.problems.is_empty() {
        println!();
        ctx.ui.bad(
            "audit",
            &format!(
                "{} hard failure(s); refusing to switch",
                report.problems.len()
            ),
        );
        for problem in &report.problems {
            println!("  - {problem}");
        }
        bail!("audit found hard failures; nothing was switched and no state was written");
    }

    if ctx.dry_run {
        // Resolve the privilege path even on a dry run: a missing home-manager
        // or a tampered sudo wrapper should fail now, not after `apply`.
        for target in targets {
            let (prog, args) = switch_command(ctx, *target)?;
            let mut parts = vec![prog.display().to_string()];
            parts.extend(args);
            ctx.ui.kv("switch path", &cmd::shell_join(&parts));
        }
        println!();
        ctx.ui.kv(
            "dry run",
            "built and audited; nothing switched and no state written",
        );
        return Ok(());
    }

    // A changed root helper always gets the typed gate, first deploy included.
    // Deliberately not keyed on state.json or on a previous deploy.
    let strict = report.changed && targets.contains(&Target::System);
    if !confirm(ctx, strict, report.text_changed)? {
        // A non-zero exit here matters: a script that pipes no stdin must not
        // read "did nothing" as a successful deploy.
        bail!("aborted before switching; nothing was switched and no state was written");
    }

    recheck_before_switch(ctx, &report, &built)?;

    let mut mutable_state = state;
    for b in &built {
        if !run_switch(ctx, b.target)? {
            bail!(
                "switch failed for {}; later targets were not switched",
                b.target.label()
            );
        }
        post_switch(ctx, &report, b)?;
        record(
            ctx,
            &mut mutable_state,
            &snapshot,
            &report,
            std::slice::from_ref(b),
        )?;
        ctx.ui.kv(
            "recorded",
            &format!("{} in {}", b.target.label(), ctx.state_dir.display()),
        );
    }
    Ok(())
}

pub fn status(ctx: &Ctx) -> Result<()> {
    let ui = &ctx.ui;
    let state = State::load(&ctx.state_dir);
    ui.heading("deploy state");
    ui.kv("state dir", &ctx.state_dir.display().to_string());

    let Some(deploy) = state.last_deploy.clone() else {
        ui.note("no deploy recorded yet; `dots system --dry-run` shows what one would do");
        return Ok(());
    };
    // Root's copy is set by the last deploy that linked a helper. A home switch
    // cannot change it, so last_deploy is the wrong baseline for this line.
    let root_power = state
        .last_system
        .as_ref()
        .map(|d| d.power_sha.as_str())
        .unwrap_or(deploy.power_sha.as_str());

    ui.kv(
        "last deploy",
        &format!("{}  target {}", deploy.time, deploy.target),
    );
    ui.kv(
        "commit",
        &format!(
            "{} ({})",
            deploy.commit.clone().unwrap_or_else(|| "<none>".into()),
            if deploy.dirty {
                ui.yellow("dirty tree")
            } else {
                "clean".into()
            }
        ),
    );
    ui.kv("built", deploy.result.as_deref().unwrap_or("<none>"));
    ui.kv(
        "recorded hashes",
        &format!(
            "flake.lock {}  power.sh {}",
            short_sha(&deploy.lock_sha),
            short_sha(&deploy.power_sha)
        ),
    );

    ui.sub("drift since then");
    let head = git::head(&ctx.dotfiles);
    let baseline = deploy.commit.clone();
    match (&baseline, &head) {
        (Some(base), Some(now)) => {
            if !git::rev_exists(&ctx.dotfiles, base) {
                ui.note("the recorded commit is gone from history");
            } else if base.chars().take(7).eq(now.chars().take(7)) {
                println!("  {:<16} HEAD is the recorded commit", "commits:");
            } else {
                let range = format!("{base}..HEAD");
                match git::log_oneline(&ctx.dotfiles, &range) {
                    Some(log) if !log.trim().is_empty() => {
                        let lines: Vec<&str> =
                            log.lines().filter(|l| !l.trim().is_empty()).collect();
                        println!("  {:<16} {} since {}", "commits:", lines.len(), base);
                        for line in lines.iter().take(10) {
                            println!("    {line}");
                        }
                        if lines.len() > 10 {
                            ui.note(&format!("    … {} more", lines.len() - 10));
                        }
                    }
                    _ => println!("  {:<16} none", "commits:"),
                }
            }
        }
        _ => ui.note("commits: no git HEAD"),
    }

    let dirty_now = git::status_porcelain(&ctx.dotfiles)
        .map(|s| git::dirty_count(&s))
        .unwrap_or(0);
    println!("  {:<16} {} file(s)", "dirty now:", dirty_now);

    let lock_now = state::sha256_file(&ctx.deploy.join("flake.lock")).unwrap_or_default();
    println!(
        "  {:<16} {}",
        "flake.lock:",
        if lock_now == deploy.lock_sha {
            "unchanged".to_string()
        } else {
            ui.yellow("changed").to_string()
        }
    );
    let power_now = state::sha256_file(&ctx.dotfiles.join("scripts/power.sh")).unwrap_or_default();
    println!(
        "  {:<16} {}",
        "power.sh (root):",
        if power_now == root_power {
            "unchanged".to_string()
        } else {
            ui.red("changed").to_string()
        }
    );

    let current_system =
        cmd::resolve(Path::new("/run/current-system")).map(|p| p.display().to_string());
    match (&current_system, deploy.result.as_deref()) {
        (Some(now), Some(recorded)) if deploy.target == "system" || deploy.target == "both" => {
            if now == recorded {
                println!("  {:<16} {} (recorded build)", "current system:", now);
            } else {
                println!("  {:<16} {} (recorded {recorded})", "current system:", now);
            }
        }
        (Some(now), _) => println!("  {:<16} {now}", "current system:"),
        _ => ui.note("current system: /run/current-system does not resolve"),
    }
    if let Some(profile) = home_profile() {
        if let Some(now) = cmd::resolve(&profile) {
            println!("  {:<16} {}", "home profile:", now.display());
        }
    }

    ui.sub("tool");
    ui.kv("exe", &ctx.self_info.exe);
    ui.kv(
        "built from",
        ctx.self_info.source.as_deref().unwrap_or("<not embedded>"),
    );
    if deploy.exe != ctx.self_info.exe {
        ui.warn(
            "exe changed",
            &format!("{} → {}", deploy.exe, ctx.self_info.exe),
        );
    }
    if deploy.source != ctx.self_info.source.clone().unwrap_or_default() {
        ui.warn(
            "built from changed",
            "the running dots was built from a different source than the recorded deploy",
        );
    }

    println!();
    ui.note("next: `dots audit` (read-only) or `dots system --dry-run` (builds, does not switch)");
    Ok(())
}

pub fn audit(ctx: &Ctx) -> Result<()> {
    let ui = &ctx.ui;
    let state = State::load(&ctx.state_dir);

    ui.heading("git");
    let head = git::head(&ctx.dotfiles).unwrap_or_else(|| "<unknown>".into());
    ui.kv(
        "HEAD",
        &format!(
            "{} ({})",
            head.chars().take(7).collect::<String>(),
            ctx.dotfiles.display()
        ),
    );
    let dirty = git::status_porcelain(&ctx.dotfiles).unwrap_or_default();
    ui.kv(
        "dotfiles",
        &format!(
            "{} dirty entr{}",
            git::dirty_count(&dirty),
            if git::dirty_count(&dirty) == 1 {
                "y"
            } else {
                "ies"
            }
        ),
    );
    if ui.verbose() {
        for line in dirty.lines().filter(|l| !l.trim().is_empty()) {
            println!("{}", highlight(ui, line));
        }
    }
    let deploy_dirty = git::status_porcelain(&ctx.deploy).unwrap_or_default();
    ui.kv(
        "deploy-system",
        &format!(
            "{} dirty entr{} in the private wrapper",
            git::dirty_count(&deploy_dirty),
            if git::dirty_count(&deploy_dirty) == 1 {
                "y"
            } else {
                "ies"
            }
        ),
    );

    ui.heading("flake inputs");
    let lock_now = std::fs::read_to_string(ctx.deploy.join("flake.lock")).unwrap_or_default();
    match state::read_snapshot(&ctx.state_dir, "flake.lock.prev") {
        Some(prev) => {
            let old: Value = serde_json::from_str(&prev).unwrap_or(Value::Null);
            let new: Value = serde_json::from_str(&lock_now).unwrap_or(Value::Null);
            let diff = lockfile::diff(&old, &new);
            if diff.is_empty() {
                ui.ok("lock", "unchanged since the last recorded deploy");
            } else {
                for node in &diff.added {
                    ui.alert(&format!(
                        "TRUST BOUNDARY: new input {} ({})",
                        node.name,
                        node.url.clone().unwrap_or_default()
                    ));
                }
                for node in &diff.removed {
                    ui.kv(
                        "removed",
                        &format!("{} ({})", node.name, node.url.clone().unwrap_or_default()),
                    );
                }
                for (old_node, new_node) in &diff.changed {
                    ui.kv(
                        "changed",
                        &format!(
                            "{}: {} → {} ({} → {})",
                            new_node.name,
                            old_node
                                .rev
                                .as_deref()
                                .map(lockfile::short_rev)
                                .unwrap_or_else(|| "∅".into()),
                            new_node
                                .rev
                                .as_deref()
                                .map(lockfile::short_rev)
                                .unwrap_or_else(|| "∅".into()),
                            old_node
                                .last_modified
                                .map(lockfile::format_day)
                                .unwrap_or_default(),
                            new_node
                                .last_modified
                                .map(lockfile::format_day)
                                .unwrap_or_default()
                        ),
                    );
                }
            }
        }
        None => ui.note("no flake.lock snapshot yet; run a deploy to record one"),
    }

    // Submodule drift.
    let lock: Value = serde_json::from_str(&lock_now).unwrap_or(Value::Null);
    for (name, node) in lockfile::nodes(&lock) {
        if name == OVERRIDDEN_INPUT {
            ui.note(&format!(
                "{name}: the live tree overrides the locked rev (not drift)"
            ));
            continue;
        }
        let Some(url) = node.url.as_deref() else {
            continue;
        };
        let Some(path) = lockfile::local_path(url) else {
            continue;
        };
        let path = PathBuf::from(path);
        if !path.exists() {
            continue;
        }
        match (node.rev.as_deref(), git::head(&path)) {
            (Some(locked), Some(head)) if locked != head => ui.warn(
                "submodule",
                &format!(
                    "{name} locked at {} but the checkout is at {} — run `nix flake update {name}` in deploy-system",
                    lockfile::short_rev(locked),
                    lockfile::short_rev(&head)
                ),
            ),
            (None, _) => ui.note(&format!("{name}: path input with no locked rev")),
            _ => {}
        }
    }

    let report = stage_power_static(ctx, &state)?;

    ui.heading("tool integrity");
    if ctx.self_info.skipped {
        ui.alert("SELF-CHECK SKIPPED: DOTS_SKIP_SELF_CHECK=1");
    } else {
        ui.ok("exe", &ctx.self_info.exe);
        ui.ok(
            "built from",
            ctx.self_info.source.as_deref().unwrap_or("<not embedded>"),
        );
    }
    if !report.problems.is_empty() {
        println!();
        ui.bad(
            "audit",
            &format!("{} hard failure(s)", report.problems.len()),
        );
        for problem in &report.problems {
            println!("  - {problem}");
        }
        println!();
        ui.note("static scan; the decisive evidence is the diff and the byte-identical store copy");
        bail!("audit found hard failures");
    }
    println!();
    ui.note("static scan; the decisive evidence is the diff and the byte-identical store copy");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{confirm_decision, root_changes, same_link};

    #[test]
    fn link_spellings_are_equal() {
        assert!(same_link(
            "/usr/local/sbin/power.sh",
            "/usr/local/sbin//./power.sh"
        ));
        assert!(!same_link(
            "/usr/local/sbin/power.sh",
            "/usr/local/sbin/other.sh"
        ));
    }

    #[test]
    fn live_copy_wins_over_stale_state() {
        // State says "old", but root already runs exactly this source: no gate.
        assert!(!root_changes("old", "new", Some(true)));
    }

    #[test]
    fn differing_live_copy_always_gates() {
        assert!(root_changes("new", "new", Some(false)));
        assert!(root_changes("", "new", Some(false)));
    }

    #[test]
    fn missing_live_copy_falls_back_to_state() {
        assert!(!root_changes("new", "new", None));
        assert!(root_changes("old", "new", None));
        // No state and no readable live copy: first deploy, gate it.
        assert!(root_changes("", "new", None));
    }

    #[test]
    fn yes_never_answers_the_strict_gate() {
        assert!(confirm_decision(true, true, None).is_err());
        assert!(confirm_decision(true, true, Some("apply")).is_err());
    }

    #[test]
    fn strict_gate_needs_the_exact_word() {
        assert!(confirm_decision(true, false, Some("apply")).unwrap());
        assert!(confirm_decision(true, false, Some(" apply\n")).unwrap());
        assert!(!confirm_decision(true, false, Some("y")).unwrap());
        assert!(!confirm_decision(true, false, Some("yes")).unwrap());
        assert!(!confirm_decision(true, false, None).unwrap());
    }

    #[test]
    fn ordinary_prompt_accepts_y_and_yes() {
        assert!(confirm_decision(false, false, Some("y")).unwrap());
        assert!(confirm_decision(false, false, Some("YES")).unwrap());
        assert!(!confirm_decision(false, false, Some("n")).unwrap());
        assert!(confirm_decision(false, true, None).unwrap());
    }
}
