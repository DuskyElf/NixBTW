This repo is the user's entire machine. NixOS, home-manager, niri, scripts, editors, agents. A bad edit here breaks boot, login, or work. You are a guest with wide read access. Treat that as trust to repay with care, not room to act.

Control rules:
* Never widen a trust boundary to make a job easier. Sandboxed commands stay sandboxed. `power.sh` stays the only root path from keybinds.
* Test before you report back. Reproduce with a deterministic check where possible and paste the exact result.
* Leave the tree clean. Never commit agent state, lock noise, or session files.

Before every commit, Review. The change must be reviewed by review agent(s) with appropriate skills before it lands, and the review must take care of the big picture and if the change missed something that must be changed alongside it. Reviewing in your own context does not count; you share the assumptions that produced the diff. Fix what they find, or explain the dismissal in the commit body.

Top level owns the machine: `flake.nix`, `lib/`, `base/`, `apps/`, `pkgs/`, `hosts/`, the docs and CI, plus `deploy-system/` (private wrapper flake, gitignored, pushed to `NixBTW-deploy`). A file an asset owner needs lives beside the code that owns it instead of at the top: `apps/quickshell/` holds the QML and the status scripts, `apps/daily-update/` the daily run and its project pin, `apps/home-switch/` `hm-switch.sh`, `apps/power/` `power.sh`, `apps/tmux/` `tmux.conf`, `pkgs/t3code/` its pin script, and `lib/deploy/` the wrapper bootstrap.

The layout is the first thing to read:
* `flake.nix` declares inputs and outputs, nothing else. Every directory under `hosts/` becomes a host, so a new machine is a directory, never a flake edit.
* `lib/` is the plumbing: nixpkgs instances, the jail wrapper, the kernel call, `mkHost`, and `lib/deploy/`. `lib/host.nix` is the option schema, evaluated once by `lib/mkHost.nix` and passed to `base/` and `apps/` as `hostConfig`, so never hardcode a username, connector name, or device path in a shared module; add an option instead.
* `base/` is machine-wide config split by machine type: `core.nix` and `workstation.nix` on the system side, `home.nix` and `home-workstation.nix` on the home side. A host lists the half it wants, and the bootloader stays in the host's `system.nix` because it is hardware.
* `apps/` is one app's config per file, with split apps in a subdirectory that also holds their own assets. There is no registry: a host imports the module it wants, one import per half for a split app, and the list the import sits in decides which rebuild applies.
* `hosts/<name>/` is one machine: `config.nix` holds its identity and hardware as data, `default.nix` the imports, `system.nix` the drivers, kernel, and bootloader, `disk.nix` and `disko.nix` the disk layout.

Two machines carry these: `hosts/asus/` is the laptop, `hosts/homelab/` a headless box on the LAN that runs the same tree from its own checkout and wrapper. A change to a shared module has to suit both, and the comments under `hosts/homelab/` cover its hardware and tuning.

Subrepos own their domains. Read their docs when you work inside them and do not duplicate them here:
* `apps/nvim/neovimBTW/`
* `apps/opencode/opencodeBTW/`
* `apps/wallpaper/wallpaper-guardian/`

This repo is NOT the deploy flake. `deploy-system/` is a private wrapper flake pinning this repo as `my-dotfiles`. It is gitignored with its own nested git repo, pushed to the private `NixBTW-deploy` repository, and its flake.lock is the lock source of truth for the wrapper's own inputs. The checkout keeps an untracked, gitignored `flake.lock` of its own, which a `path:` override reads and a standalone git-flake eval ignores (git flakes read tracked files only); the daily run rewrites it as you so the two stay in agreement. You may read the wrapper and propose edits to it. The user applies them.

All rebuilds go through the wrapper with the live-tree override, so uncommitted edits apply immediately:

* System (`base/core.nix`, `base/workstation.nix`, the system imports in a host's `default.nix`, `hosts/`): `sudo /usr/local/sbin/nixos-switch.sh`. It takes `/run/nixos-switch.lock` and the host's `--cores`, and a `--target-host` run cannot take that lock, so redeploy a remote host by ssh and the helper there.
* Home (`base/home.nix`, `base/home-workstation.nix`, the home imports in a host's `default.nix`, and a `hosts/` value only the home half reads such as `ssh.aliases`): `~/.config/scripts/hm-switch.sh`. A tree it has already built returns in about a second, `--force` re-activates, and its state is `~/.local/state/hm-switch`.

A host with no helper yet, the plain `home-manager switch` that `news`, `rollback` and `generations` need, and the table of what needs which rebuild are in `README.md` under Rebuild.

Everything on both machines is handled by systemd timers pretty much. One daily user timer, `daily-update`, runs `apps/daily-update/daily-update.sh`: pull, move the pins that host owns, run the system switch and then the home switch, and collect the user and root profiles. Which of those a machine takes is host data in `lib/host.nix` `dailyUpdate`, not a branch in the script. When the machine disagrees with this repo, suspect that drift first, not a local edit. Do not hand-edit pins the timer owns.

Submodule bumps (e.g. `neovimBTW`) do not reach a switch through the live-tree override alone. The wrapper pins each submodule as its own flake input, so run `nix flake update <name>` inside `deploy-system/` after the bump, then switch; the daily timer does it for the inputs in `dailyUpdate.wrapperInputs`.

Edits to a live-linked asset go live at once, no rebuild: `apps/quickshell/` is linked to `~/.config/quickshell`, `apps/tmux/tmux.conf` and `apps/opencode/opencodeBTW` the same way, and `apps/daily-update/active-projects` is read at run time. Exception: `apps/power/power.sh` is store-pinned and symlinked into `/usr/local/sbin`, so it needs a nixos-rebuild, and any root action from a keybind must route through it or sudo hangs the keybind.

Packages are as jailed as possible using `lib/jail.nix`, see each app module to check their perms.

What belongs in this file (AGENTS.md):
A line stays only if every task needs it, a new agent would get it wrong without it, and no comment in the code already says it. When you add a line, name the task that breaks without it; when a behavior changes, prune the line that explains it. Everything else is a comment beside the code it describes, kept in sync with the change; install steps and one-off procedures go in `README.md`, the human-facing manual.
