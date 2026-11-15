This repo is the user's entire machine. NixOS, home-manager, niri, scripts, editors, agents. A bad edit here breaks boot, login, or work. You are a guest with wide read access. Treat that as trust to repay with care, not room to act.

Control rules:
* Never widen a trust boundary to make a job easier. Sandboxed commands stay sandboxed. `power.sh` stays the only root path from keybinds.
* Test before you report back. Reproduce with a deterministic check where possible and paste the exact result.
* Leave the tree clean. Never commit agent state, lock noise, or session files.

Before every commit, Review. The change must be reviewed by review agent(s) with appropriate skills before it lands, and the review must take care of the big picture and if the change missed something that must be changed alongside it. Reviewing in your own context does not count; you share the assumptions that produced the diff. Fix what they find, or explain the dismissal in the commit body.

Top level owns the machine: `flake.nix`, `home.nix`, `system.nix`, `cli/`, `gui/`, `hosts/`, `scripts/`, `quickshell/`, `hot-configs/`, plus `deploy-system/` (private wrapper flake, gitignored, never pushed).

Subrepos own their domains. Read their docs when you work inside them and do not duplicate them here:
* `neovimBTW/`
* `opencodeBTW/`

This repo is NOT the deploy flake. `deploy-system/` is a private wrapper flake pinning this repo as `my-dotfiles`. It is gitignored with its own nested git repo and never pushed, so its flake.lock is the only lock source of truth. You may read it and propose edits to it. The user applies them.

All rebuilds go through the wrapper with the live-tree override so uncommitted edits apply immediately:

* System (`system.nix`, `hosts/`): `sudo nixos-rebuild switch --flake /home/duskyelf/dotfiles/deploy-system --override-input my-dotfiles path:/home/duskyelf/dotfiles --cores 16`
* Home (`gui/`, `cli/`): `home-manager switch --flake /home/duskyelf/dotfiles/deploy-system --override-input my-dotfiles path:/home/duskyelf/dotfiles --cores 16`

Everything on this machine is handled by systemd timers pretty much.

A daily user timer runs `nix flake update nixpkgs nixpkgs-unstable-small zen-browser` (see ./home.nix)  in `deploy-system/`, switches home-manager, and commits that lock. Only those 3 inputs auto-update. When the machine disagrees with this repo, suspect that drift first, not a local edit. Do not hand-edit pins the timer owns.

Submodule bumps (e.g. `neovimBTW`) do not reach a switch through the live-tree override alone. The wrapper pins each submodule as its own flake input, so run `nix flake update <name>` inside `deploy-system/` after the bump, then switch.

T3 Code is not the nixpkgs package. `cli/t3code-main.nix` reuses that recipe on upstream main, and `cli/t3code-main.lock.nix` holds the rev plus the three fixed-output hashes that follow a rev. `scripts/update-t3code-main.sh` moves that pin inside the daily timer, before the switch, and keeps the old pin when a commit does not build. Do not swap it back to `pkgs.t3code` or edit the hashes by hand.

`scripts/` is symlinked into `~/.config` via mkOutOfStoreSymlink, so edits go live at once, no rebuild. Exception: `power.sh` is store-pinned and symlinked into `/usr/local/sbin`, so it needs a nixos-rebuild. Any root action from a keybind must route through `power.sh` or sudo hangs the keybind.

Packages are as jailed as possible using jail.nix, see each file's module to check their perms.

Q. What belongs in this file (AGENTS.md) ?
Wisdom that a new agent needs about the repo and the machine, the overall context of what's happening. Don't forget to update this file cautiously.

At boot, `screenpad-off` (hosts/asus/system.nix) does the power-off, not niri: the asus_screenpad backlight probes late, so niri spawn-at-startup races and fails silent, leaving the panel lit. The service waits up to 30s for the device.
