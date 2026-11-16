//! CLI surface. Every subcommand that does real work passes the self-check
//! first: the audit is only worth reading if the auditor is the pinned binary.

use anyhow::{bail, Result};
use clap::{Args, Parser, Subcommand};
use dots::deploy::{self, Ctx};
use dots::nix::Target;
use dots::selfcheck;
use dots::ui::Ui;
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "dots",
    version,
    about = "Audited system/home rebuilds for the dotfiles repo",
    long_about = "Builds through the deploy wrapper with the live tree, shows what changed, \
                  audits scripts/power.sh before it goes to root, diffs closures with package \
                  provenance, then switches."
)]
struct Cli {
    /// The dotfiles checkout (default: the one this binary was built against)
    #[arg(long, global = true, value_name = "PATH")]
    dotfiles: Option<PathBuf>,

    /// The private deploy wrapper (default: <dotfiles>/deploy-system)
    #[arg(long, global = true, value_name = "PATH")]
    deploy: Option<PathBuf>,

    /// Show full diffs, every added path and every upgrade
    #[arg(long, global = true)]
    verbose: bool,

    /// Never use colour
    #[arg(long, global = true)]
    no_color: bool,

    /// Do not prompt before switching
    #[arg(long, short = 'y', global = true)]
    yes: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Last recorded deploy and the drift since then; no build
    Status,
    /// Static audit only: git, flake inputs, power.sh, sudo invariant
    Audit,
    /// Audit and switch the system
    System(BuildArgs),
    /// Audit and switch home-manager
    Home(BuildArgs),
    /// Audit and switch system, then home, stopping on failure
    Both(BuildArgs),
}

#[derive(Args)]
struct BuildArgs {
    /// Build and audit, print everything, do not switch
    #[arg(long)]
    dry_run: bool,
}

fn main() {
    let cli = Cli::parse();
    if let Err(err) = run(cli) {
        eprintln!("dots: error: {err:#}");
        std::process::exit(1);
    }
}

fn run(cli: Cli) -> Result<()> {
    // Root is refused before anything else: every privileged step is an explicit
    // `sudo` call, and the audit itself must run as the login user.
    selfcheck::refuse_root()?;
    let info = selfcheck::check()?;
    if info.skipped {
        // Printed for every subcommand, `status` included: a tool that skipped
        // its own verification must never look like a verified one.
        eprintln!(
            "dots: WARNING: DOTS_SKIP_SELF_CHECK=1 — the binary and its source are NOT verified. \
             Every result below is unverified code output."
        );
    }

    let ui = Ui::new(cli.no_color, cli.verbose);
    let dotfiles = match cli.dotfiles {
        Some(path) => path,
        None => match dots::BUILD_DOTFILES {
            Some(path) => {
                if std::path::Path::new(path).is_dir() {
                    PathBuf::from(path)
                } else {
                    fallback_dotfiles()?
                }
            }
            None => fallback_dotfiles()?,
        },
    };

    let dry_run = match &cli.command {
        Command::System(args) | Command::Home(args) | Command::Both(args) => args.dry_run,
        _ => false,
    };

    let ctx = Ctx::new(
        dotfiles,
        cli.deploy,
        ui,
        cli.yes,
        dry_run,
        info,
        // `status` reads only local state and git; no flake eval, no nix warnings.
        !matches!(&cli.command, Command::Status),
    )?;

    // The header states exactly which binary is speaking, what source it was
    // built from, and which checkout it audits.
    println!(
        "{}",
        ctx.ui
            .bold(&selfcheck::signature(&ctx.self_info, &ctx.dotfiles))
    );

    match cli.command {
        Command::Status => deploy::status(&ctx),
        Command::Audit => deploy::audit(&ctx),
        Command::System(_) => deploy::deploy(&ctx, &[Target::System]),
        Command::Home(_) => deploy::deploy(&ctx, &[Target::Home]),
        Command::Both(_) => deploy::deploy(&ctx, &[Target::System, Target::Home]),
    }
}

/// Without an embedded checkout (a development build), fall back to the
/// conventional location so `cargo run` still has something to point at.
fn fallback_dotfiles() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").unwrap_or_default();
    let candidate = PathBuf::from(home).join("dotfiles");
    if candidate.join("flake.nix").is_file() {
        Ok(candidate)
    } else {
        bail!("no dotfiles dir: pass --dotfiles PATH (this build has no embedded DOTS_DOTFILES)")
    }
}
