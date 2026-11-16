This repo is the user's entire machine. NixOS, home-manager, niri, scripts, editors, agents. A bad edit here breaks boot, login, or work. You are a guest with wide read access. Treat that as trust to repay with care, not room to act.

Control rules:
* Never widen a trust boundary to make a job easier. Sandboxed commands stay sandboxed. `power.sh` stays the only root path from keybinds.
* Test before you report back. Reproduce with a deterministic check where possible and paste the exact result.
* Leave the tree clean. Never commit agent state, lock noise, or session files.

Before every commit, Review. The change must be reviewed by review agent(s) with appropriate skills before it lands, and the review must take care of the big picture and if the change missed something that must be changed alongside it. Reviewing in your own context does not count; you share the assumptions that produced the diff. Fix what they find, or explain the dismissal in the commit body.

Top level owns the machine: `flake.nix`, `lib/`, `base/`, `apps/`, `pkgs/`, `hosts/`, `scripts/`, `quickshell/`, `hot-configs/`, plus `deploy-system/` (private wrapper flake, gitignored, never pushed).

The layout is the first thing to read:
* `flake.nix` declares inputs and outputs, nothing else.
* `lib/` is the plumbing: nixpkgs instances, the jail wrapper, the kernel call, `mkHost`.
* `base/` is machine-wide config. `base/system.nix` is policy and unconfigured packages, `base/home.nix` is stylix, gc and timers.
* `apps/` is one app's config per file, with split apps in their own subdirectory. `apps/default.nix` splits them into `homeModules` and `systemModules`; that list, not the filename, says which rebuild applies.
* `pkgs/` is packages this repo builds itself. `pkgs/t3code/` is the T3 Code pin.
* `hosts/<name>/` is one machine. `config.nix` holds its identity and hardware as data (user, home, hostname, time zone, state versions, panels, battery, GPU); `default.nix` lists that host's modules; `system.nix` holds the driver and kernel work. `lib/host.nix` is the schema and `lib/mkHost.nix` evaluates it once, passing it to `base/` and `apps/` as `hostConfig`. Never hardcode a username, connector name, or device path in `base/` or `apps/`; add an option to the schema instead.

Subrepos own their domains. Read their docs when you work inside them and do not duplicate them here:
* `neovimBTW/`
* `opencodeBTW/`
* `wallpaper-guardian/` (Guardian wallpaper pool CLI, Rust, own flake and home-manager module)

This repo is NOT the deploy flake. `deploy-system/` is a private wrapper flake pinning this repo as `my-dotfiles`. It is gitignored with its own nested git repo and never pushed, so its flake.lock is the only lock source of truth. You may read it and propose edits to it. The user applies them.

All rebuilds go through the wrapper with the live-tree override so uncommitted edits apply immediately:

* System (`base/system.nix`, the system list in `apps/default.nix`, `hosts/`): `sudo nixos-rebuild switch --flake /home/duskyelf/dotfiles/deploy-system --override-input my-dotfiles path:/home/duskyelf/dotfiles --cores 16`
* Home (`base/home.nix`, the home list in `apps/default.nix`): `home-manager switch --flake /home/duskyelf/dotfiles/deploy-system --override-input my-dotfiles path:/home/duskyelf/dotfiles --cores 16`

Everything on this machine is handled by systemd timers pretty much.

A daily user timer runs `nix flake update nixpkgs nixpkgs-unstable-small zen-browser` (see `base/home.nix`)  in `deploy-system/`, switches home-manager, and commits that lock. Only those 3 inputs auto-update. When the machine disagrees with this repo, suspect that drift first, not a local edit. Do not hand-edit pins the timer owns.

Submodule bumps (e.g. `neovimBTW`) do not reach a switch through the live-tree override alone. The wrapper pins each submodule as its own flake input, so run `nix flake update <name>` inside `deploy-system/` after the bump, then switch. `wallpaper-guardian` is pinned the same way.

`dots` (`pkgs/dots`, in `environment.systemPackages`) is the manual rebuild path: `dots system`, `dots home`, `dots both`. It audits git and the flake inputs, parses the composed sudoers plus `scripts/power.sh`, builds through the wrapper with the live tree, diffs closures with package provenance, then asks before switching. A changed root helper (the script or the derivation that runs it) needs the word `apply` typed out, because the new copy runs as root; `--yes` cannot skip that. Once the system ships it, the running binary must be `/run/current-system/sw/bin/dots` (a locally built copy is refused); the first install is necessarily the manual command below. `dots audit` is the same static evidence without a build and `dots status` is the last recorded deploy. State and log live in `~/.local/state/dots/`. It uses the same wrapper and live-tree override as the two commands below, adding `--no-write-lock-file`, so a manual switch never rewrites the wrapper lock, and the daily timer is untouched.

T3 Code is not the nixpkgs package. `pkgs/t3code/default.nix` reuses that recipe on upstream main, and `pkgs/t3code/lock.nix` holds the rev plus the three fixed-output hashes that follow a rev. `scripts/update-t3code-main.sh` moves that pin inside the daily timer, before the switch, and keeps the old pin when a commit does not build. Do not swap it back to the nixpkgs `t3code` attribute or edit the hashes by hand.

`scripts/` is symlinked into `~/.config` via mkOutOfStoreSymlink, so edits go live at once, no rebuild. Exception: `power.sh` is store-pinned and symlinked into `/usr/local/sbin`, so it needs a nixos-rebuild. Any root action from a keybind must route through `power.sh` or sudo hangs the keybind.

Packages are as jailed as possible using `lib/jail.nix`, see each app module to check their perms.

Q. What belongs in this file (AGENTS.md) ?
Wisdom that a new agent needs about the repo and the machine, the overall context of what's happening. Don't forget to update this file cautiously.

At boot, `screenpad-off` (hosts/asus/system.nix) does the power-off, not niri: the asus_screenpad backlight probes late, so niri spawn-at-startup races and fails silent, leaving the panel lit. The service waits up to 30s for the device.
