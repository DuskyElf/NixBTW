This repo is the user's entire machine. NixOS, home-manager, niri, scripts, editors, agents. A bad edit here breaks boot, login, or work. You are a guest with wide read access. Treat that as trust to repay with care, not room to act.

## Control rules

You steward the whole system. Keep each change small, reversible, and scoped to what was asked.

* Confirm before anything destructive or hard to reverse: deletes, rewrites, submodule moves, store or boot changes.
* You have no sudo password, the user does. The only sudo you can run yourself is `sudo /usr/local/sbin/power.sh ...`, which is NOPASSWD so niri keybinds can act as root without a prompt hanging them. `timestamp_timeout=0` means every other sudo prompts fresh with no credential cache. Never use `power.sh` to dodge permissions. Anything else needing root goes to the user as one copy paste command block.
* `nixos-rebuild` needs sudo, so you cannot run it. Hand it to the user prefilled in one copy paste block. `home-manager switch` needs no sudo, so you can run it yourself; confirm first since it changes the live session, then report the result.
* Signing and pushing work from here with the user's keys and `gh` auth. Sign commits by default, push only when asked.
* Never widen a trust boundary to make a job easier. Sandboxed commands stay sandboxed. `power.sh` stays the only root path from keybinds.
* Test before you report back. Reproduce with a deterministic check where possible and paste the exact result.
* Leave the tree clean. Never commit agent state, lock noise, or session files.

## Repo map

Top level owns the machine: `flake.nix`, `home.nix`, `system.nix`, `cli/`, `gui/`, `hosts/`, `scripts/`, `quickshell/`, `hot-configs/`, plus `deploy-system/` (private wrapper flake, gitignored, never pushed).

Subrepos own their domains. Read their docs when you work inside them and do not duplicate them here:

* `neovimBTW/` is the Neovim config (submodule).
* `opencodeBTW/` is the opencode setup: agents, commands, skills, plugins. Opencode behavior and tool quirks belong there, not here.
* `piBTW/` is pi agent state and config (submodule, symlinked to `~/.pi`). Its `AGENTS.md` and `CONTEXT.md` rule inside it. Dirty entries there are runtime noise. Never commit them.

If a fact lives in config or a subrepo doc, point at it. Do not copy it here.

## Rebuild model: source tree, not a deploy unit

This repo is NOT the deploy flake. `deploy-system/` is a private wrapper flake pinning this repo as `my-dotfiles`. It is gitignored with its own nested git repo and never pushed, so its flake.lock is the only lock source of truth. You may read it and propose edits to it. The user applies them.

All rebuilds go through the wrapper with the live-tree override so uncommitted edits apply immediately:

* System (`system.nix`, `hosts/`): `sudo nixos-rebuild switch --flake /home/duskyelf/dotfiles/deploy-system --override-input my-dotfiles path:/home/duskyelf/dotfiles --cores 16`
* Home (`gui/`, `cli/`): `home-manager switch --flake /home/duskyelf/dotfiles/deploy-system --override-input my-dotfiles path:/home/duskyelf/dotfiles --cores 16`
* `gui/niri.nix` is home-manager only.
* `nixos-rebuild` needs sudo and you have no password: hand it to the user, prefilled, in a single command block. `home-manager switch` you can run yourself after confirming.

`my-dotfiles.inputs.stylix.follows` in the private flake overrides this repo's stylix pin, so editing `flake.nix` here alone is inert for stylix.

A daily user timer runs `nix flake update nixpkgs nixpkgs-unstable-small zen-browser` in `deploy-system/`, switches home-manager, and commits that lock. Only those 3 inputs auto-update. When the machine disagrees with this repo, suspect that drift first, not a local edit. Do not hand-edit pins the timer owns.

## Liveness and shell

The shell sees the user's filesystem, network, and systemd user bus. Direct curl, `systemctl --user`, and /sys reads work. `web_search` runs one call per turn with 2 to 4 queries. `fetch_content` covers raw.githubusercontent.com and the GitHub API.

`scripts/` is symlinked into `~/.config` via mkOutOfStoreSymlink, so edits go live at once, no rebuild. Exception: `power.sh` is store-pinned and symlinked into `/usr/local/sbin`, so it needs a nixos-rebuild. Any root action from a keybind must route through `power.sh` or sudo hangs the keybind.

Sandboxed commands (`curl`, `wget`, `gh`, `worktrunk`, `pi`) get network plus mount-cwd plus own config dirs, nothing more:

* Sandboxed curl cannot WRITE with `-o` (exit 23). Use a shell redirect (`curl ... > file`) so the shell opens the target.
* A daemon backgrounded while holding a flock inherits the fd and holds the lock forever. Close it on spawn (`daemon ... 9>&- &`). Seen via `scripts/wallpaper.mjs` and `lib/lock.mjs`.

## What belongs in this file

Only durable wisdom. A line stays here if a fresh agent would otherwise get it wrong, it cannot be read from config, and it will still matter in six months. Everything else goes to its subrepo doc, a code comment, or nowhere.

Do not append session notes, reproduction logs, transient tool quirks, or readable-from-config facts. When you learn something, ask whether it clears that bar before adding it. Prune stale lines when behavior changes. Keep comments in code in sync with the change that caused them. No em dashes in edits.

## Load-bearing oddities, do not clean up

* Perl overlay in `flake.nix` (`doCheck = false` on ModuleCPANTS-Analyse) is required for gnucash to build.
* `hosts/asus/system.nix` compiles its own kernel (march-native plus LLVM LTO) from nixpkgs-fast-release. Changes mean a long local compile. `PREEMPT_LAZY = lib.mkForce no` resolves a config conflict (commit a2b03f7).
* nixpkgs inputs are deliberately mixed (system release, niri unstable, stylix aligned with system). Aligning them is not a fix.
* Zen reads light/dark from the portal's `org.freedesktop.appearance`, mapped to dconf `org/gnome/desktop/interface.color-scheme`. `home.nix` pins `prefer-dark`. Unset, zen renders light despite `stylix.polarity = "dark"`. `stylix.targets.zen-browser.enable = false` only gates CSS, not light/dark (niri issue 2878).
* Stylix's gtk target sets `gtk.gtk4.theme` internally. A manual line duplicates the definition and fails home-manager.
* dGPU (NVIDIA) is prime OFFLOAD and optional: powersave modes remove the PCI device and unload modules, performance re-scans the bus. niri ignores the nvidia render node. A missing nvidia module is a power mode, not a bug.

## Screenpad (DP-2): the toggle stays bare

Mod+1 reads bl_power (4 is on) and either turns off (`niri msg output DP-2 off` plus `power.sh screenpad off`) or on (`power.sh screenpad on` plus `niri msg output DP-2 on`). No sleeps, retries, or flock. That bareness is the fix: the DP link trains marginal, i915 rejects the modeset mid-training (EINVAL), and only a fresh bl_power cycle re-trains it. The kernel hotplug uevent about 1.5s later triggers auto-connect. Do not improve it. The retry is another Mod+1. `niri msg output DP-2 on` on an unmapped connector still exits 0, so never trust its exit code.

At boot, `screenpad-off` (hosts/asus/system.nix) does the power-off, not niri: the asus_screenpad backlight probes late, so niri spawn-at-startup races and fails silent, leaving the panel lit. The service waits up to 30s for the device.

## Design of this laptop: the pattern, not the settings

Settings live in config. Respect the pattern when changing config.

* Content-first minimalism. Zero chrome: no gaps, borders, focus rings, shadows, or tab indicator. Single centered full-width column.
* Touchpad is the primary input. Volume, brightness, screenpad brightness, and color temperature are Mod/Alt plus scroll variants. Physical keys are secondary. Media keys stay allow-when-locked.
* Battery-first, performance opt-in. 80 percent charge cap, powersave governor, no turbo on battery, deep sleep. Perf is the custom march-native kernel plus prime-offload dGPU (CUDA only) via power mode.
* Systemd-first background work. Lifecycle belongs to user timers and services, not shell daemons or niri spawn-at-startup (wallpaper fetch/rotate/resume/startup, awww-daemon, quickshell, wl-gammarelay, gamma-temperature, break-timer, flake-auto-update). Reach for a `systemd.user.timer` or service before a backgrounded script.
