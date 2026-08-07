# AGENTS.md

Operational wisdom for this dotfiles repo. Only non-obvious facts a fresh agent would otherwise get wrong; anything readable from the config is omitted. Dense on purpose. No em dashes in edits.

## Rebuild model: source tree, not a deploy unit

This repo is NOT the deploy flake. `~/.deploy-system` is a private flake pinning this repo as `my-dotfiles`; its flake.lock is never committed here (avoids CVE-scanning pinned versions), so the public repo has no canonical pins and the private repo is the only lock source of truth.

All rebuilds go through the private repo with the live-tree override so uncommitted edits apply immediately:

- System (root system.nix, hosts/): `sudo nixos-rebuild switch --flake ~/.deploy-system --override-input my-dotfiles path:/home/duskyelf/dotfiles --cores 16`
- Home (gui/, cli/): `home-manager switch --flake ~/.deploy-system --override-input my-dotfiles path:/home/duskyelf/dotfiles --cores 16`
- gui/niri.nix is home-manager only.

The private repo is a read-only btrfs mount inside the jail (EROFS): the user edits it. Its `my-dotfiles.inputs.stylix.follows` overrides the repo's stylix url, so a repo flake.nix pin edit alone is inert.

scripts/ lifecycle: `scripts/` is symlinked into `~/.config` via mkOutOfStoreSymlink, so edits go live immediately, no rebuild. Exception: `power.sh` is store-pinned (content read at eval time, symlinked into /usr/local/sbin), so editing it needs a nixos-rebuild. Also, sudo NOPASSWD is scoped to `/usr/local/sbin/power.sh` ONLY: any root action from a keybind must route through power.sh, or sudo prompts and hangs the keybind.

## Machine drifts from this repo by design

A daily user timer runs `nix flake update nixpkgs nixpkgs-unstable-small zen-browser` in `~/.deploy-system`, switches home-manager, and commits that flake.lock. Only those 3 inputs auto-update; the rest stay pinned until manually bumped. A mismatch between observed machine behavior and repo state is usually this drift, not a local edit.

## Agent shell runs inside a jail

PATH is `/run/current-system/sw/bin` and `~/.nix-profile/bin` only; /nix/store and PATH dirs are readonly. No niri, /sys, DRM, sudo, systemctl, or bash network (curl fails with bwrap errors). The user is the only bridge to system state: hand them command blocks, interpret their pasted output. web_search works (one call per turn, 2-4 queries); fetch_content covers raw.githubusercontent.com and the GitHub API.

## Many commands are jail wrappers (trust boundary)

curl, wget, gh, worktrunk, pi go through flake.nix's `jail` (jail-nix, `xdg-app`): network + mount-cwd + own config dirs, nothing more. This is a deliberate trust boundary; never widen their access. Gotchas:
- Jail curl can't WRITE with `-o` (exits 23, CURLE_WRITE_ERROR). Use a shell redirect (`curl ... > file`) so the shell opens the target outside the sandbox.
- A daemon backgrounded while holding a flock inherits the fd and holds the lock forever; every later run reports "another run is in progress". Close it on spawn (`daemon ... 9>&- &`). Bitten by scripts/wallpaper.mjs via lib/lock.mjs.
- piBTW submodule holds agent state; dirty entries are noise, never commit.

## Load-bearing oddities, do not "clean up"

- Perl overlay in flake.nix (ModuleCPANTS-Analyse `doCheck = false`) is required for gnucash to build; its comment explains the overrideScope.
- hosts/asus/system.nix compiles its own kernel (march-native + LLVM LTO) from nixpkgs-fast-release; changes mean a long local compile. `PREEMPT_LAZY = lib.mkForce no` resolves a config conflict (commit a2b03f7).
- nixpkgs inputs are deliberately mixed (system release, niri unstable, stylix aligned with system); aligning them is not a fix.
- Zen and other apps read light/dark from the portal's `org.freedesktop.appearance`, mapped to dconf `org/gnome/desktop/interface.color-scheme`. home.nix pins `prefer-dark`; unset, zen renders light despite `stylix.polarity = "dark"`. `stylix.targets.zen-browser.enable = false` only gates CSS, not dark/light. (niri issue #2878)
- Stylix's gtk target sets `gtk.gtk4.theme` internally; a manual `gtk.gtk4.theme` line duplicates the definition and fails home-manager.
- dGPU (NVIDIA) is prime OFFLOAD and optional: powersave/ultra-powersave remove the PCI device and unload modules; performance re-scans the bus. niri ignores the nvidia render node. A missing nvidia module is a power mode, not a bug.

## Screenpad (DP-2): the toggle is deliberately bare

Mod+1 runs `power.sh screenpad on` + `niri msg output DP-2 on`, no sleeps/retries/flock. That bareness is the fix: the DP link trains marginal, i915 rejects the modeset mid-training (EINVAL), and only a fresh bl_power cycle re-trains it; the kernel's own hotplug uevent ~1.5s later triggers auto-connect. Delays and retries churn the link. Do not "improve" it; the retry is another Mod+1. Details: bl_power is inverted (0 off, 4 on); `niri msg output DP-2 on` on an unmapped connector still exits 0, never trust its exit code.

## Brightness and temperature: two independent mechanisms, do not mix

Backlight via brightnessctl only (`-d asus_screenpad` for the screenpad). Color temperature via wl-gammarelay-rs D-Bus only (`busctl --user call rs.wl-gammarelay / rs.wl.gammarelay UpdateTemperature n <delta>`; interface arg required, `--` before negative deltas). No day/night timers. Kernel param `i915.enable_dpcd_backlight=3` is required for the OLED backlight; removing it breaks brightness.

## Design of this laptop: the pattern, not the settings

The settings live in the config; the pattern behind them is what to respect when changing config.

- **Content-first minimalism.** Zero chrome: no gaps, borders, focus rings, shadows, or tab indicator; single centered full-width column. Do not "improve" the minimalism.
- **Touchpad is the primary input.** Volume, brightness, screenpad brightness, and color temperature are Mod/Alt + scroll variants; physical keys are secondary. Media keys stay allow-when-locked.
- **Battery-first, performance opt-in.** 80% charge cap, powersave governor, no turbo on battery, deep sleep. Perf = custom march-native kernel + prime-offload dGPU (CUDA only) via power mode. The dGPU is a compute tool, not a display card.
- **Vim everywhere.** zsh vi-mode, EDITOR=vim in every jail. No modal-editing conflicts.
- **Quiet transient UI.** Notifications last 500-1000ms and replace themselves, never stack; Vim/Visual-mode indicators are notification-based (Ctrl+Return family). Keep notifications quiet.
- **Systemd-first background work.** Lifecycle belongs to user timers/services, not shell daemons or niri spawn-at-startup (wallpaper fetch/rotate/resume/startup, awww-daemon, wl-gammarelay, gamma-temperature, break-timer, flake-auto-update). Reach for a `systemd.user.timer`/`service` before a backgrounded script.

Commits: conventional prefixes (fix:/feat:/chore:/docs:), SSH-signed by default, no em dashes in messages or docs.
