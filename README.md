# NixBTW

The NixOS and home-manager config for my laptop (`asus`, a UX581GV) and the
headless LAN box (`homelab`), plus the small tools around it: the status
scripts, the T3 Code stable pin, and the kernel cache. The Guardian wallpaper
pool lives in `apps/wallpaper/wallpaper-guardian/`, a separate flake and
submodule.

This repo is the source tree, not the deploy unit. `deploy-system/` is a
gitignored wrapper flake that pins every input and holds `flake.lock`. It stays
private on purpose, so the exact nixpkgs, stylix, niri, and zen-browser
revisions are not published. A fresh clone can evaluate after its submodules
are checked out and Nix resolves the floating inputs, but the machine's exact
closure comes from that wrapper.

## Layout

| Path | Holds |
| --- | --- |
| `flake.nix` | Inputs and outputs. Nothing computes here; the machine list comes from `hosts/`. |
| `lib/` | nixpkgs instances, the jail wrapper, the kernel selection, `mkHost`, and `lib/deploy/` with the wrapper bootstrap |
| `base/` | Machine-wide config, split by machine type: `base/core.nix` for every host, `base/workstation.nix` for a desktop, `base/home.nix` plus `base/home-workstation.nix` on the home side. The bootloader is per host. |
| `apps/` | One app's config per file, with split apps in their own subdirectory. `apps/default.nix` is a registry of app names, each mapping to its home and system modules; an app's own assets live beside it. The shells (`sh`, `zsh`, `bash`), the home switch, the power helper, and the daily update are apps, so a host opts into each. |
| `pkgs/` | Packages this repo builds itself, such as the T3 Code stable pin and its update script |
| `hosts/asus/` | This laptop: `config.nix` holds its identity and hardware values, `system.nix` the firmware, kernel, nvidia, and screenpad work |
| `hosts/homelab/` | The headless LAN box: its own config, disk layout, and the `hardware.nix` generated on the box |
| `apps/quickshell/`, `apps/daily-update/`, `apps/home-switch/` | Live-linked assets beside the module that owns them: the QML and status scripts, the daily run and its project pin, and `hm-switch.sh` |

Nothing app-specific sits at the top level any more: a script or asset lives in
the directory of the app whose `.nix` uses it, and `lib/deploy/` holds the
wrapper bootstrap because it is plumbing rather than an app.

A file in `apps/` sets config for one app, except `apps/default.nix` itself and
the helpers a module imports, such as `apps/niri/notify.nix`. Machine policy
(network, radios, the console keymap) and a bare `programs.<app>.enable` stay in
`base/core.nix` and `base/workstation.nix`; the root helpers and their sudo
rules moved out with the apps that need them (`apps/power.nix` and
`apps/daily-update/system.nix`), and `programs.niri.enable` stays in
`apps/niri/system.nix` because the compositor's config lives beside it. The list
a host puts an app name in decides which rebuild applies, so the filename does
not have to say it.

### Host identity

`hosts/<name>/config.nix` is data, not work: the login user, home directory,
hostname, time zone, locale, state versions, git identity, niri outputs, and the
hardware the app modules branch on (screenpad, battery, backlight, GPU). The
schema is `lib/host.nix`; `lib/mkHost.nix` evaluates it once and passes the
result to both the NixOS and home-manager configurations as `hostConfig`.
`base/` and `apps/` read that argument, so a second machine is a new `hosts/`
directory with a `config.nix` and a `default.nix`; `flake.nix` discovers the
directory, and nothing in it is listed by hand. The flake output names
(`nixosConfigurations.asus`, `homeConfigurations."duskyelf@asus"`) come from
the same values.

What stays in a host's `system.nix` is the work: drivers, kernel tuning, BIOS
entries, the bootloader, boot services. A value another module reads belongs in
`config.nix`.

## First checkout

Clone [DuskyElf/NixBTW](https://github.com/DuskyElf/NixBTW) into `dotfiles`:

```sh
git clone --recurse-submodules https://github.com/DuskyElf/NixBTW dotfiles
```

An existing checkout needs `git submodule sync --recursive` and then
`git submodule update --init` after pulling, since the submodules moved under
`apps/` and the flake reads two of those paths as inputs.

The clone has no `deploy-system/` and no lock. On the laptop I restore the
private wrapper. A public-only checkout can generate an equivalent one and lock
it to the current channel tips:

```sh
lib/deploy/bootstrap.sh
```

The script writes `deploy-system/flake.nix` from `lib/deploy/deploy-system.nix`,
commits it into a nested repo (Nix ignores an untracked flake inside a git
tree), runs `nix flake lock`, and prints the rebuild commands for the checkout's
path. The generated directory stays gitignored. Run `nix flake update` inside
it to move the lock later. The rebuilds below assume `/home/duskyelf/dotfiles`.

The homelab needs the same checkout and bootstrap before its home generation is
activated: its daily timer execs the run from that checkout and switches that
wrapper, so an unpopulated `~/dotfiles` leaves the run with nothing to do.

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
sudo /usr/local/sbin/nixos-switch.sh
```

The helper is the daily timer's own command: the wrapper, the live-tree
override, the host's `--cores`, and `/run/nixos-switch.lock`, so a hand run and
the timer's run queue instead of both reaching switch-to-configuration at once.
Its expanded form, for a host that has no helper yet:

```sh
sudo nixos-rebuild switch \
  --flake /home/duskyelf/dotfiles/deploy-system \
  --override-input my-dotfiles path:/home/duskyelf/dotfiles \
  --cores 16
```

A `--target-host` run reaches the target's switch-to-configuration directly and
cannot take the target's lock, so it still collides with that host's own daily
run: ssh in and run the helper there.

The live-tree override is what applies uncommitted edits. Without it the
wrapper evaluates its pinned `my-dotfiles` rev, which can be older than your
tree and can point at a different `nixpkgs-fast-release`, so the kernel build
misses the signed cache.

What needs which rebuild:

| Changed | Apply with |
| --- | --- |
| `base/home.nix`, `base/home-workstation.nix`, an app's home modules in `apps/default.nix` | `hm-switch.sh` |
| `base/core.nix`, `base/workstation.nix`, an app's system modules in `apps/default.nix`, `hosts/` | `sudo /usr/local/sbin/nixos-switch.sh` |
| `apps/niri/system.nix` | `sudo /usr/local/sbin/nixos-switch.sh`; the rest of `apps/niri/` is a home module |
| `flake.nix`, `lib/` | both, the wiring reaches both configurations |
| `apps/wallpaper/wallpaper-guardian/` | `hm-switch.sh`; a submodule bump also needs `nix flake update wallpaper-guardian` in `deploy-system/` |
| `apps/quickshell/`, `apps/tmux/tmux.conf`, `apps/daily-update/active-projects` | nothing, they are linked live or read at run time |
| `apps/power/power.sh` | `sudo /usr/local/sbin/nixos-switch.sh` (it lands in `/usr/local/sbin`) |

A `neovimBTW` or `wallpaper-guardian` submodule bump also needs
`nix flake update <name>` inside `deploy-system/`, then a switch; the daily run
does that for both after its pull. The private wrapper must list
`wallpaper-guardian` as an input first; `lib/deploy/deploy-system.nix` shows the
shape for a fresh bootstrap. `apps/opencode/opencodeBTW` is symlinked, not a
flake input.

A hand edit still needs the rebuild from the table, but the daily run applies
whatever a pull brings to both configurations on its own. The system half is
the same helper either way: `sudo /usr/local/sbin/nixos-switch.sh` when you run
it, and the timer calling that path itself.

## What is pinned

| Thing | Where | Why |
| --- | --- | --- |
| kernel nixpkgs | `flake.nix` | CI builds the same kernel derivation as the laptop, so the signed cache hits |
| T3 Code stable | `pkgs/t3code/lock.nix` | upstream stable tag plus the three vendor hashes, moved by the daily timer |
| `setup_var.efi` | `hosts/asus/system.nix` | BIOS unlock entry, by version and hash |
| NVIDIA driver | `hosts/asus/system.nix` | must match the custom kernel, and this closure is in no public cache |

The other inputs float through the private lock, including system nixpkgs,
unstable for niri, unstable-small for the agents, home-manager, stylix,
jail-nix, disko, neovimBTW, wallpaper-guardian, and zen-browser. The laptop's
daily timer updates nixpkgs, unstable-small, zen-browser and the two submodule
inputs; the homelab's own wrapper updates nixpkgs and the two submodule inputs,
and both submodule inputs follow their checkouts whenever a pull moves one. The
kernel pin has its own rotation, described below.

## What runs

Systemd units do the background work, not shell daemons. On both machines one
daily user timer does the morning's work: `apps/daily-update/daily-update.sh`
pulls the merged changes, updates the floating inputs the host lists, moves the
T3 Code pin (laptop only), rebuilds the system through the `nixos-switch.sh`
helper, switches home-manager, commits the wrapper lock, pins the listed
devshells (laptop only), and collects the user store. It then wakes a system
path unit that collects root's profiles, so both sides keep two days of
generations. The wallpaper fetch, rotate, resume, and startup units come from
the `wallpaper-guardian` home-manager module enabled in `apps/wallpaper.nix`,
next to `awww-daemon`. `quickshell`, `wl-gammarelay`, and `break-timer` are
`apps/quickshell.nix`, `apps/gammarelay.nix`, and `apps/idle.nix`.
`battery-threshold-control` and `screenpad-off` are one-shot system services.
`llm-lab` starts ollama and Open WebUI only when you ask.

Which of those steps a machine runs is host data, not a branch in the script:
`lib/host.nix` `dailyUpdate` sets `t3`, `devshells`, `collect`,
`graphicalSession`, `linger`, `cores` and `wrapperInputs`, and
`apps/daily-update/home.nix` turns them into the unit's flags. The laptop takes
all of them and ties the timer to the graphical session; the homelab takes only
the collection, with no graphical session and `linger = true` so its user
manager starts at boot.

## The daily update

The user timer `daily-update` fires from 08:30, with up to half an hour of
jitter, and catches up after wake. On the laptop it is part of the graphical
session, so the run needs a login; the homelab has no session to join, so its
user manager lingers from boot instead. `apps/daily-update/daily-update.sh`
waits for network, pulls `origin/main` with `git pull --rebase --autostash`
(the timer's own T3 Code commits are the only local work in the way), syncs the
submodules, locks this checkout's ignored `flake.lock`, runs
`nix flake update` on the inputs the host lists (the laptop:
`nixpkgs nixpkgs-unstable-small zen-browser neovimBTW wallpaper-guardian`;
the homelab: `nixpkgs neovimBTW wallpaper-guardian`), and on the laptop also
`pkgs/t3code/update.sh`. It rebuilds the system, runs
`apps/home-switch/hm-switch.sh`, commits the wrapper lock, pins the listed
devshells, and collects the user store with `--delete-older-than 2d`. The marker
it writes starts `nix-gc-root.service`, which collects root's profiles with the
same window; the marker is written from an exit trap, so a run killed with
SIGTERM still asks for root's collection (the user half is skipped). A failed
pull, update, switch or commit still pins and collects, and the run exits
nonzero. A host that does not collect (`collect = false`) writes no marker and
runs no collection.

A missing `deploy-system/flake.nix` stops the update half before the pull with a
notification, because there is nothing to lock, update or switch; the tail still
runs. Only inputs the wrapper declares can be listed in `wrapperInputs`, and the
script refuses an empty list rather than let `nix flake update` move every
input.

Only three inputs float from the network. `neovimBTW` and `wallpaper-guardian`
are re-locked from their checkouts, which is what lets a merged submodule bump
reach the switch.

The two machines share the tree but not the tracks. The laptop mixes nixpkgs
instances on purpose (unstable for niri and zen, unstable-small for the agents,
fast-release for its tuned kernel). The homelab uses the stable nixpkgs and
`neovimBTW` only, and the 6.18 longterm kernel, so nothing it installs needs an
unstable instance or a locally built kernel.

A pull that conflicts aborts its own rebase and the run continues on the tree it
already has, with a notification; a pull that rewrites `daily-update.sh` itself
makes the run hand over to the new copy as a child before touching anything
else. Three pull states stop the update half instead: a rebase, merge, or
cherry-pick already in progress in the checkout, which a timer must not abort or
rebuild over; an autostash that conflicts after the rebase succeeded, where git
exits 0 with unmerged paths and the stash holding the edits; and unmerged paths
an earlier run left behind. A failed submodule sync or tree lock stops it too. In every one of those the checkout is left for you, both switches
skip, and the devshell pin and the collection still run. A failed system switch
skips the home switch too, because a home generation that calls into the system
half is the half-applied state the order exists to avoid.

The system half goes through `/usr/local/sbin/nixos-switch.sh`, a store-pinned
script built in `apps/daily-update/system.nix` that holds the whole command: the
fixed flake and live-tree override, the host's `dailyUpdate.cores` (16 on the
laptop, 2 on the homelab), a pinned `PATH`, and `/run/nixos-switch.lock`, so a
hand run of that same path and the timer's run queue instead of both reaching
switch-to-configuration at once. Its NOPASSWD rule names that
path with an empty argument list, which is the sudoers way to allow the command
only with no arguments, so the account cannot hand `nixos-rebuild` another
flake, attribute, or bootloader operation. That does not make the checkout
trusted: `nixos-rebuild` evaluates the login user's tree, so whoever can write a
module can install a system generation as root on the next run, which is what a
hand rebuild already allows minus the password. `--no-write-lock-file` keeps
root from writing a lock file the account then cannot.

The kernel moves on a different track. `.github/workflows/check-kernel-update.yml`
compares the pinned `nixpkgs-fast-release` rev with `release-26.05` and opens a
PR when the stable kernel changes. Merging it triggers `compile-kernel.yml`,
which publishes the kernel to the signed cache at `duskyelf.github.io/NixBTW`.
The next daily run pulls the merge, and its system rebuild substitutes the
cached kernel instead of compiling for two hours. Merging the PR is the only
manual step left; the new kernel is the boot default after that switch and runs
from the next reboot, because nothing here reboots the machine.

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
pkgs/t3code/test-update.sh        # t3code stable pin, against fakes
apps/home-switch/test-hm-switch.sh # hm-switch cache, against a fake nix
apps/daily-update/test-daily-update.sh # the daily run, against fakes
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
own `hosts/<name>` (discovered automatically) and a real hardware config, not a
copy of `hosts/asus`. Its identity goes in `config.nix`; the drivers, kernel,
and bootloader go in `system.nix`.

`AGENTS.md` is the operating manual for agents working in this tree. The
kernel, stylix, screenpad, and power paths each carry the reason they have to
stay as they are in a comment beside the code, so read that comment before
editing the code.
