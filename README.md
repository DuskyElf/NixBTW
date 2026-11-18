# NixBTW

The NixOS and home-manager config for my laptop (`asus`, a UX581GV), plus the
small tools around it: the status scripts, the T3 Code stable pin, and the
kernel cache. The Guardian wallpaper pool lives in `wallpaper-guardian/`, a
separate flake and submodule.

This repo is the source tree, not the deploy unit. `deploy-system/` is a
gitignored wrapper flake that pins every input and holds `flake.lock`. It stays
private on purpose, so the exact nixpkgs, stylix, niri, and zen-browser
revisions are not published. A fresh clone can evaluate after its submodules
are checked out and Nix resolves the floating inputs, but the machine's exact
closure comes from that wrapper.

## Layout

| Path | Holds |
| --- | --- |
| `flake.nix` | Inputs and outputs. Nothing computes here. |
| `lib/` | nixpkgs instances, the jail wrapper, the kernel selection, `mkHost` |
| `base/` | Machine-wide config: system policy and unowned packages in `base/system.nix`, stylix and timers in `base/home.nix` |
| `apps/` | One app's config per file, with split apps in their own subdirectory. `apps/default.nix` lists which are home modules and which are system modules |
| `pkgs/` | Packages this repo builds itself, such as the T3 Code stable pin |
| `hosts/asus/` | This laptop: `config.nix` holds its identity and hardware values, `system.nix` the firmware, kernel, nvidia, and screenpad work |
| `scripts/`, `quickshell/`, `hot-configs/` | Linked live, no rebuild |

A file in `apps/` sets config for one app, except `apps/default.nix` itself and
the helpers a module imports, such as `apps/niri/notify.nix`. Machine policy
(network, power, sudo), a bare `programs.<app>.enable`, and packages that need
no config stay in `base/system.nix`; `programs.niri.enable` stays in
`apps/niri/system.nix` because the compositor's config lives beside it. The list
a module appears in decides which rebuild applies, so the filename does not have
to say it.

### Host identity

`hosts/<name>/config.nix` is data, not work: the login user, home directory,
hostname, time zone, locale, state versions, git identity, niri outputs, and the
hardware the app modules branch on (screenpad, battery, backlight, GPU). The
schema is `lib/host.nix`; `lib/mkHost.nix` evaluates it once and passes the
result to both the NixOS and home-manager configurations as `hostConfig`.
`base/` and `apps/` read that argument, so a second machine is a new `hosts/`
directory plus a `config.nix` and one `mkHost` binding with two output lines in
`flake.nix`, not edits spread through the app modules. The flake output names
(`nixosConfigurations.asus`, `homeConfigurations."duskyelf@asus"`) come from
the same values.

What stays in a host's `system.nix` is the work: drivers, kernel tuning, BIOS
entries, boot services. A value another module reads belongs in `config.nix`.

## First checkout

Clone [DuskyElf/NixBTW](https://github.com/DuskyElf/NixBTW) into `dotfiles`:

```sh
git clone --recurse-submodules https://github.com/DuskyElf/NixBTW dotfiles
```

An existing checkout needs `git submodule update --init wallpaper-guardian`
after pulling, since the flake reads that path as an input.

The clone has no `deploy-system/` and no lock. On the laptop I restore the
private wrapper. A public-only checkout can generate an equivalent one and lock
it to the current channel tips:

```sh
scripts/bootstrap-deploy.sh
```

The script writes `deploy-system/flake.nix` from `scripts/deploy-system.nix`,
commits it into a nested repo (Nix ignores an untracked flake inside a git
tree), runs `nix flake lock`, and prints the rebuild commands for the checkout's
path. The generated directory stays gitignored. Run `nix flake update` inside
it to move the lock later. The rebuilds below assume `/home/duskyelf/dotfiles`.

## Rebuild

Home changes:

```sh
~/.config/scripts/hm-switch.sh
```

The script is the home switch. Evaluation is ~20s of single-core work, so it
keys each generation by the content of the tree and reuses it: an unchanged
tree returns in about a second, and `--force` re-activates. Its caches live in
`~/.local/state/hm-switch`.

The plain `home-manager switch` still works, and is the command for
`home-manager news`, `rollback` and `generations`; the script wraps only the
switch itself:

```sh
home-manager switch \
  --flake /home/duskyelf/dotfiles/deploy-system \
  --override-input my-dotfiles path:/home/duskyelf/dotfiles \
  --cores 16
```

System changes:

```sh
sudo nixos-rebuild switch \
  --flake /home/duskyelf/dotfiles/deploy-system \
  --override-input my-dotfiles path:/home/duskyelf/dotfiles \
  --cores 16
```

The live-tree override is what applies uncommitted edits. Without it the
wrapper evaluates its pinned `my-dotfiles` rev, which can be older than your
tree and can point at a different `nixpkgs-fast-release`, so the kernel build
misses the signed cache.

What needs which rebuild:

| Changed | Apply with |
| --- | --- |
| `base/home.nix`, the home list in `apps/default.nix` | `hm-switch.sh` |
| `base/system.nix`, the system list in `apps/default.nix`, `hosts/` | `nixos-rebuild switch` |
| `apps/niri/system.nix` | `nixos-rebuild switch`; the rest of `apps/niri/` is a home module |
| `flake.nix`, `lib/` | both, the wiring reaches both configurations |
| `wallpaper-guardian/` | `hm-switch.sh`; a submodule bump also needs `nix flake update wallpaper-guardian` in `deploy-system/` |
| `scripts/timers.mjs`, `hot-configs/`, `quickshell/` | nothing, they are linked live |
| `scripts/power.sh` | `nixos-rebuild switch` (it lands in `/usr/local/sbin`) |

A `neovimBTW` or `wallpaper-guardian` submodule bump also needs
`nix flake update <name>` inside `deploy-system/`, then a switch. The private
wrapper must list `wallpaper-guardian` as an input first; `scripts/deploy-system.nix`
shows the shape for a fresh bootstrap. `opencodeBTW` is symlinked, not a flake
input.

## What is pinned

| Thing | Where | Why |
| --- | --- | --- |
| kernel nixpkgs | `flake.nix` | CI builds the same kernel derivation as the laptop, so the signed cache hits |
| T3 Code stable | `pkgs/t3code/lock.nix` | upstream stable tag plus the three vendor hashes, moved by the daily timer |
| `setup_var.efi` | `hosts/asus/system.nix` | BIOS unlock entry, by version and hash |
| NVIDIA driver | `hosts/asus/system.nix` | must match the custom kernel, and this closure is in no public cache |

The other inputs float through the private lock, including system nixpkgs,
unstable for niri, unstable-small for the agents, home-manager, stylix,
jail-nix, neovimBTW, wallpaper-guardian, and zen-browser. The daily timer
updates three of them. The kernel pin has its own rotation, described below.

## What runs

Systemd units do the background work, not shell daemons. One daily user timer
does the morning's work: `scripts/daily-update.sh` updates the floating inputs,
moves the T3 Code pin, switches home-manager, commits the wrapper lock, pins the
listed devshells, and collects the user store. It then wakes a system path unit
that collects root's profiles, so both sides keep two days of generations. The
monthly store optimiser is the only other store unit. The wallpaper fetch,
rotate, resume, and startup units come from the `wallpaper-guardian`
home-manager module enabled in `apps/wallpaper.nix`, next to `awww-daemon`.
`quickshell`, `wl-gammarelay`, and `break-timer` are `apps/quickshell.nix`,
`apps/gammarelay.nix`, and `apps/idle.nix`. `battery-threshold-control` and
`screenpad-off` are one-shot system services. `llm-lab` starts ollama and Open
WebUI only when you ask.

## The daily update

The user timer `daily-update` fires from 08:30, with up to half an hour of
jitter, and catches up after wake. `scripts/daily-update.sh` waits for network,
runs `nix flake update nixpkgs nixpkgs-unstable-small zen-browser` and
`scripts/update-t3code-stable.sh`, runs `scripts/hm-switch.sh`, commits the
wrapper lock, pins the listed devshells, and collects the user store with
`--delete-older-than 2d`. The marker it writes last starts
`nix-gc-root.service`, which collects root's profiles with the same window. A
failed update, switch or commit still pins and collects, and the run exits
nonzero. The unit is part of the graphical session, so the run needs a login;
the old GC timers did not, and that is the trade for collecting right after the
switch.

The kernel moves on a different track. `.github/workflows/check-kernel-update.yml`
compares the pinned `nixpkgs-fast-release` rev with `release-26.05` and opens a
PR when the stable kernel changes. Merging it triggers `compile-kernel.yml`,
which publishes the kernel to the signed cache at `duskyelf.github.io/NixBTW`.
The next `nixos-rebuild` substitutes it instead of compiling for two hours.

System rebuilds stay manual. The timer only touches home-manager.

## Checks

Evaluate both configurations before switching:

```sh
nix eval --raw --no-write-lock-file .#nixosConfigurations.asus.config.system.build.toplevel.drvPath
nix eval --raw --no-write-lock-file '.#homeConfigurations."duskyelf@asus".config.home.activationPackage.drvPath'
```

These read tracked files only, so `git add` a new Nix file before evaluating.
The rebuild commands use the live tree and include untracked edits.

Build home without activating:

```sh
home-manager build \
  --flake /home/duskyelf/dotfiles/deploy-system \
  --override-input my-dotfiles path:/home/duskyelf/dotfiles \
  --cores 16
```

Check the parts that have tests or a single answer:

```sh
nix eval --raw --no-write-lock-file .#kernelVersion   # the series the selector picked
scripts/test-update-t3code-stable.sh  # t3code stable pin, against fakes
scripts/test-hm-switch.sh           # hm-switch cache, against a fake nix
scripts/test-daily-update.sh        # the daily run, against fakes
nix fmt                          # nixfmt-tree over the repo
```

After a change that is only supposed to move files, take a snapshot of what each
configuration installs before you start, and diff it afterwards:

```sh
nix eval --no-write-lock-file --json --apply \
  'ps: builtins.sort builtins.lessThan (map toString ps)' \
  '.#homeConfigurations."duskyelf@asus".config.home.packages' > /tmp/home-before
nix eval --no-write-lock-file --json --apply \
  'ps: builtins.sort builtins.lessThan (map toString ps)' \
  '.#nixosConfigurations.asus.config.environment.systemPackages' > /tmp/system-before
```

Same list after the move means the same packages and the same derivations. Do
not use `nix store diff-closures` for this: it compares names and versions, so a
rebuilt package at the same version is invisible to it.

## This is not a template

Disk devices and labels, BIOS offsets, undervolt values, the screenpad quirk,
and the kernel tuning all describe one UX581GV. A second machine should get its
own `hosts/<name>` and a real hardware config, not a copy of `hosts/asus`. Its
identity goes in `config.nix`; the drivers and tuning go in `system.nix`.

`AGENTS.md` is the operating manual for agents working in this tree. The
kernel, stylix, screenpad, and power paths each carry the reason they have to
stay as they are in a comment beside the code, so read that comment before
editing the code.
