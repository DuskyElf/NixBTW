//! `dots` wraps the two rebuild paths of this repo so every switch is
//! accompanied by the evidence that matters: what changed, what the root
//! helper is about to become, and which packages enter the closure.
//!
//! The binary is store-pinned (see `selfcheck`), so the code that performs
//! the audit is the code the system declares.

pub mod cmd;
pub mod deploy;
pub mod git;
pub mod lockfile;
pub mod nix;
pub mod pkgscan;
pub mod power;
pub mod selfcheck;
pub mod state;
pub mod storepath;
pub mod ui;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The checkout this build was pinned to. Baked in through `DOTS_DOTFILES`
/// so a store build always audits the tree it ships with.
pub const BUILD_DOTFILES: Option<&str> = option_env!("DOTS_DOTFILES");

/// The crate source, as a store path. Used by the self-check.
pub const BUILD_SOURCE: Option<&str> = option_env!("DOTS_SOURCE");
