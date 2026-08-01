# AGENTS.md

Operational wisdom for this dotfiles repo. Non-obvious facts a fresh agent will otherwise get wrong. Dense on purpose. No em dashes in edits.

## Deploy flake is private

This repo is NOT the deploy flake. `~/.deploy-system` is a private flake that pins this repo as the `my-dotfiles` input. Its flake.lock stays private so pinned software versions never appear in this public repo (avoids CVE scanning of the versions in use).

All rebuilds go through it with the live-tree override, which makes uncommitted changes apply immediately:

- System level (root system.nix, hosts/): `sudo nixos-rebuild switch --flake ~/.deploy-system --override-input my-dotfiles path:/home/duskyelf/dotfiles --cores 16`
- Home-manager level (gui/, cli/): `home-manager switch --flake ~/.deploy-system --override-input my-dotfiles path:/home/duskyelf/dotfiles --cores 16`

Pick the command by what changed: gui/* and cli/* are home-manager modules, root system.nix and hosts/* are system modules. gui/niri.nix in particular is home-manager only.

## Screenpad (DP-2): the toggle is deliberately bare

Mod+1 is instant `power.sh screenpad on` + `niri msg output DP-2 on` (reverse for off), no sleeps,
no retries, no flock. That bareness is the fix, not a simplification: the DP link trains marginal,
i915 rejects the modeset while it is degraded (atomic test EINVAL, niri logs "error creating DRM
compositor"), and only a fresh bl_power cycle re-trains it. The instant `output on` misses the link
harmlessly; the kernel's own hotplug uevent about 1.5s later triggers niri's auto-connect when the
link is stable. Delays and retry loops land mid-training and churn the link further. If tempted to
"improve" it: don't, the correct retry is another Mod+1 press.

Facts: bl_power inverted (0 = off, 4 = on). `niri msg output DP-2 on` on an unmapped connector
replies "not connected, will apply when connected" and still exits 0, never trust its exit code.
`niri msg -j outputs` is compact single-line JSON; `current_mode` is a mode index (`Option<usize>`),
`logical` appears only when the output is really active.

## The system updates itself (daily)

`home.nix` defines a user timer: daily it runs `nix flake update nixpkgs nixpkgs-unstable-small zen-browser`
in `~/.deploy-system`, then `home-manager switch`, then commits `flake.lock` in the private repo.
Consequences for agents:
- The running machine drifts from this repo by design. Only those 3 inputs auto-update; niri, stylix,
  home-manager, jail-nix stay pinned until manually updated.
- This repo's `flake.lock` is gitignored and never committed, so the public repo has NO canonical pins.
  `~/.deploy-system` is the only lock source of truth. Treat the public repo as a source tree, not a deploy unit.
- A mismatch between observed machine behavior and repo state is usually the daily update, not a local edit.

## Many commands are jail wrappers

curl, wget, gh, worktrunk, opencode, and pi itself are built through the `jail` function in flake.nix
(jail-nix input, `xdg-app` combinator). All get network + mount-cwd + their own config dirs, nothing more.
- curl and wget cannot read arbitrary files (bwrap errors). That is the sandbox design, not a broken setup.
- The agent shell runs inside `jail "pi"`: readwrite on `~/.pi` (symlinked to the piBTW submodule),
  readonly on /nix/store and the PATH dirs, PATH restricted to `/run/current-system/sw/bin` and
  `~/.nix-profile/bin`. Only binaries under those paths are callable.
- piBTW and opencodeBTW submodules hold agent state; dirty submodule entries are normal noise.

## Load-bearing oddities, do not "clean up"

- The perl overlay in flake.nix (ModuleCPANTS-Analyse `doCheck = false`) is required for gnucash to build.
  The long comment explains why overrideScope is needed; removing the overlay breaks gnucash.
- hosts/asus/system.nix compiles its own kernel: linux_7_1 from nixpkgs-fast-release (release-26.05, not
  cached by default substituters) with march-native + LLVM LTO. Kernel changes mean a long local compile.
  `PREEMPT_LAZY = lib.mkForce no` resolves a config choice conflict (commit a2b03f7); touching it breaks the build.
- nixpkgs inputs are deliberately mixed: system nixpkgs = nixos-26.05, niri follows nixos-unstable,
  stylix = release-25.11 code following 26.05 nixpkgs (hence `enableReleaseChecks = false` in home.nix).
  Aligning them is not a fix.
- dGPU (NVIDIA) is prime OFFLOAD and optional: power.sh powersave/ultra-powersave remove the PCI device
  and unload nvidia modules; performance re-scans the bus and reloads them. niri ignores the nvidia render
  node via config. A missing nvidia module is a power mode, not a bug.

## Brightness and temperature

Two independent mechanisms, do not mix:
- Backlight: brightnessctl only. `-d asus_screenpad` for the screenpad, default device for the main panel.
- Color temperature: wl-gammarelay-rs only, via D-Bus: `busctl --user call rs.wl-gammarelay / rs.wl.gammarelay UpdateTemperature n <delta>`. The interface argument is required, and use `--` before `call` for negative values.
- No day/night timers anywhere.
- Kernel param `i915.enable_dpcd_backlight=3` is required for the OLED backlight to work; removing it breaks brightness.

## Taste: user preferences (visible only at zoom-out)

Each individual setting is discoverable; the pattern is not. Respect these when changing config.

- Desktop: content-first, zero chrome. gaps 0, no borders, no focus rings, no shadows, tab indicator
  hidden, single centered column at full width. Do not "improve" the minimalism.
- Touchpad is the primary input surface: volume, brightness, screenpad brightness, and color temperature
  are all Mod/Alt + TouchpadScroll variants. Physical keys are secondary.
- Notifications are transient (500-1000ms) and replace themselves, never stack. The Vim Mode / Visual
  Mode indicators are notification-based (Ctrl+Return family). Keep notifications quiet.
- Vim everywhere: zsh vi-mode, EDITOR=vim in every jail. Do not introduce modal editing conflicts.
- Network tools (curl, wget, gh, worktrunk, opencode, pi) run jailed by design. That is a trust
  boundary, not an oversight; never widen their access.
- Battery-first laptop: 80% charge threshold, powersave governor, turbo never on battery, deep sleep.
  Performance is opt-in: custom march-native kernel, prime-offload dGPU (CUDA only), Mod+9 power mode.
- Aesthetic: gruvbox-material-dark-hard (stylix), JetBrainsMono Nerd Font, kitty, fuzzel, swaybg with
  linux_fuck_nvidia.jpeg. The dGPU is a compute tool, not a display card.
- Prompt minimalism: starship with all git info off, zoxide as `cd`, one persistent tmux session named
  "main" auto-attached on shell start.
- Media keys work while locked (allow-when-locked on volume, brightness, temperature, screenpad toggle).
- Locale: en_US messages with en_IN number/date formats, Asia/Kolkata. Do not switch fully to en_IN.
- Commits: conventional-commit prefixes (fix:/feat:/chore:/docs:), signed with the SSH key by default,
  and no em dashes anywhere in messages or docs.

## Environment constraints

- The agent shell runs in a jailed sandbox (hostname "jail"), NOT the real machine: no niri, no /sys, no DRM, no sudo, no systemctl, no bash network (curl fails with bwrap errors). Anything needing system access must be given to the user as a command block, then their pasted output interpreted: rebuilds, DRM/backlight inspection, journalctl, niri msg, udevadm, systemctl. The user is the only bridge to system state; code edits happen in the jail, system verification happens on the machine.
- Network in the jail: web_search works but ONE call per turn with 2-4 queries; fetch_content works for raw.githubusercontent.com at any rev and the GitHub API.
- sudo NOPASSWD is scoped to `/home/duskyelf/.config/scripts/power.sh` ONLY (root system.nix). Any root action from a keybind must route through power.sh, or sudo will prompt and hang the keybind.
- scripts/ is symlinked into ~/.config via mkOutOfStoreSymlink: edits to scripts/ are live immediately, no rebuild needed.
- piBTW and opencodeBTW are agent submodules; their dirty states are noise, never commit them.
- niri 26.04 source is unpacked at /nix/store/k2nfl71r8lfxzgzj2yhfxycjkbqxx3im-source if internals are needed.
