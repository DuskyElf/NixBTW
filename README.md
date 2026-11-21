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
| `apps/` | One app's config per file, with split apps in their own subdirectory. There is no registry: a host imports the app module it wants, and a split app gets one import per half. An app's own assets live beside it. The shells (`sh`, `zsh`, `bash`), the home switch, the power helper, and the daily update are apps, so a host opts into each. |
| `pkgs/` | Packages this repo builds itself, such as the T3 Code stable pin and its update script |
| `hosts/asus/` | This laptop: `config.nix` holds its identity and hardware values, `system.nix` the firmware, kernel, nvidia, and screenpad work |
| `hosts/homelab/` | The headless LAN box: its own config, disk layout, and the `hardware.nix` generated on the box |
| `apps/quickshell/`, `apps/daily-update/`, `apps/home-switch/` | Live-linked assets beside the module that owns them: the QML and status scripts, the daily run and its project pin, and `hm-switch.sh` |

Nothing app-specific sits at the top level any more: a script or asset lives in
the directory of the app whose `.nix` uses it, and `lib/deploy/` holds the
wrapper bootstrap because it is plumbing rather than an app.

A file in `apps/` is a module that sets config for one app, apart from the
helpers a module imports, such as `apps/niri/notify.nix`. Machine policy
(network, radios, the console keymap) and a bare `programs.<app>.enable` stay in
`base/core.nix` and `base/workstation.nix`; the root helpers and their sudo
rules moved out with the apps that need them (`apps/power.nix` and
`apps/daily-update/system.nix`), and `programs.niri.enable` stays in
`apps/niri/system.nix` because the compositor's config lives beside it. The list
a host imports an app module into decides which rebuild applies; a split app
names its halves `home.nix` and `system.nix`, and the import must sit in the
matching list.

### Host identity

`hosts/<name>/config.nix` is data, not work: the login user, home directory,
hostname, time zone, locale, state versions, git identity, ssh aliases, niri
outputs, and the hardware the app modules branch on (screenpad, battery,
backlight, GPU). The schema is `lib/host.nix`; `lib/mkHost.nix` evaluates it once
and passes the result to both the NixOS and home-manager configurations as
`hostConfig`. `base/` and `apps/` read that argument, so a second machine is a new `hosts/`
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

## Install a host

A new machine is a directory under `hosts/`. Install the homelab from the laptop
with the target booted from a live ISO:

```sh
nixos-anywhere --flake path:/home/duskyelf/dotfiles#homelab \
  --generate-hardware-config nixos-generate-config /home/duskyelf/dotfiles/hosts/homelab/hardware.nix \
  root@<live-iso-address>
```

The `path:` form reads the live tree, including the regenerated hardware file,
which is committed afterwards. This needs kexec on the live system. Alpine's ISO
cannot do it: its kernel has no `kexec_file_load` and sets
`kernel.kexec_load_disabled` one way, and it runs mdev, so
`/dev/disk/by-partlabel` never appears for disko. On that ISO the install is the
long way: `apk add nix bash util-linux`, generate the hardware file with
`nixos-generate-config` from the tools closure, build the system on the laptop,
`nix-store --import` it as root (the installed daemon rejects unsigned pushes
from an untrusted user), format with disko's `formatScript` after `mdev -s` and
manual partlabel links, mount with `mountScript`, then
`nixos-install --root /mnt --system ... --no-root-passwd`.

The first system switch on the new box is by hand: the daily timer comes with the
home generation, which is not installed yet. Put this checkout at
`/home/duskyelf/dotfiles` there first (`git clone --recurse-submodules`, or copy
the tree) and run `lib/deploy/bootstrap.sh` once, because the timer later execs
the run from that checkout and switches that wrapper; an unpopulated checkout
leaves the run with nothing to do. Then, with nothing else switching that host,
run the helper, or this explicit form when the installed generation did not
bring it:

```sh
sudo nixos-rebuild switch --flake ./deploy-system#homelab \
  --override-input my-dotfiles path:/home/duskyelf/dotfiles --cores 2
```

Linger, the sudo rule and the helper come from the system half, so after this
switch the daily run has everything it calls.

A CI-built kernel needs one more decision on that first switch: the trust for
the cache lives in the host's `system.nix` (on the homelab,
`hosts/homelab/system.nix`), and the generation that would use it is the one
being installed. So the first switch onto that kernel runs by hand with the
kernel already local (import its closure, then run the helper), or with
`--option substituters https://duskyelf.github.io/NixBTW --option
trusted-public-keys i9-kernel-cache:...` on that rebuild. From the second switch
on, `/etc/nix/nix.conf` carries it.

The home generation is not part of `nixos-install`, and the install runs before
the first timer, so push the first one by hand after that system switch. `nix
copy` to the installed box fails: its daemon requires a signature for an
untrusted push. The export below writes the store as root instead, and the one
password prompt is the console password. That build is the source flake, so it
resolves the checkout's own `flake.lock` (the file the daily run locks); the
wrapper is what the machine runs from then on:

```sh
gen=$(nix build --no-link --print-out-paths \
  path:/home/duskyelf/dotfiles#homeConfigurations."duskyelf@homelab".activationPackage)
nix-store --export $(nix-store -qR "$gen") > .tmp/home.nar
ssh homelab 'sudo nix-store --import' < .tmp/home.nar
ssh homelab "$gen/activate"
```

Both root and `duskyelf` start with the password `nixos`; change both after the
install. sshd is key-only, so those passwords are for the local console.

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
  --cores <dailyUpdate.cores>
```

`--cores` is the host's `dailyUpdate.cores` from `lib/host.nix`: 16 on the
laptop, 2 on the homelab. The CLI evaluates the configuration twice, for the
generation and its news feed, and prints the news count and the overridden-lock
notice that the script drops.

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
  --cores <dailyUpdate.cores>
```

A `--target-host` run reaches the target's switch-to-configuration directly and
cannot take the target's lock, so it still collides with that host's own daily
run: ssh in and run the helper there, reached from the laptop with `ssh homelab`.

The live-tree override is what applies uncommitted edits. Without it the
wrapper evaluates its pinned `my-dotfiles` rev, which can be older than your
tree and can point at a different `nixpkgs-fast-release`, so the kernel build
misses the signed cache.

On the laptop, the system half goes first when a change spans both: the niri
half calls the store copy at `/usr/local/sbin/power.sh`, so a home-only switch
runs the old script with the new arguments.

For the homelab, do the rebuild on the box in its own checkout, which switches
the pins that box's wrapper locked. Building the attribute on the laptop first
catches an evaluation error against the laptop's pin:

```sh
nix build --no-link \
  'path:/home/duskyelf/dotfiles/deploy-system#nixosConfigurations.homelab.config.system.build.toplevel' \
  --override-input my-dotfiles path:/home/duskyelf/dotfiles
```

```sh
ssh homelab
cd /home/duskyelf/dotfiles && git pull --rebase --autostash
sudo /usr/local/sbin/nixos-switch.sh
~/.config/scripts/hm-switch.sh
```

What needs which rebuild:

| Changed | Apply with |
| --- | --- |
| `base/home.nix`, `base/home-workstation.nix`, the home imports in a host's `default.nix`, and a `hosts/` value only the home half reads such as `ssh.aliases` | `hm-switch.sh` |
| `base/core.nix`, `base/workstation.nix`, the system imports in a host's `default.nix`, `hosts/` | `sudo /usr/local/sbin/nixos-switch.sh` |
| `apps/niri/system.nix` | `sudo /usr/local/sbin/nixos-switch.sh`; the rest of `apps/niri/` is a home module |
| `apps/tailscale.nix` | `sudo /usr/local/sbin/nixos-switch.sh`; the tailnet service on both hosts |
| `flake.nix`, `lib/` | both, the wiring reaches both configurations |
| `apps/wallpaper/wallpaper-guardian/` | `hm-switch.sh`; a submodule bump also needs `nix flake update wallpaper-guardian` in `deploy-system/` |
| `apps/quickshell/`, `apps/tmux/tmux.conf`, `apps/daily-update/active-projects` | nothing, they are linked live or read at run time; tmux.conf is reached at `~/.config/tmux/hotreloaded.conf` |
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
| kernel nixpkgs | `flake.nix` | CI builds the same kernel derivations as both machines, so the signed cache hits |
| T3 Code stable | `pkgs/t3code/lock.nix` | upstream stable tag plus the three vendor hashes; the laptop's daily timer moves it, and both hosts build it |
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
fast-release for its tuned kernel). The homelab uses the stable channel and
`neovimBTW`, and it configures its own kernel too: `hosts/homelab/kernel.nix`
takes the 6.18 longterm series out of the same rev-pinned `nixpkgs-fast-release`
input, so both kernels come from one pin and CI can build both from it. The
homelab's kernel is either in the signed cache or already in its store, and the
daily run refuses to switch otherwise (`dailyUpdate.kernelCache`).

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

The kernels move on a different track. `.github/workflows/check-kernel-update.yml`
compares the pinned `nixpkgs-fast-release` rev with `release-26.05` and opens a
PR when the stable kernel changes. Merging it triggers `compile-kernel.yml`,
which builds both machines' kernels in parallel and publishes them to one signed
cache at `duskyelf.github.io/NixBTW`, under `kernel-<version>` for the laptop and
`kernel-homelab-<version>` for the server. The next daily run pulls the merge and
substitutes the cached kernel. Merging the PR is the only manual step left; the
new kernel is the boot default after that switch and runs from the next reboot,
because nothing here reboots the machine.

The kernels deploy the site through `.github/workflows/publish-cache.yml`, one
deploy at a time, because gh-pages is a single branch that each deploy replaces
whole. A release whose assets are incomplete is left out of the site and
reported as a failure, never half-served.

The first switch on a host whose kernel CI has not published yet cannot use that
cache, because the generation that would trust it is the one being installed. On
the laptop that costs two hours of compile; on the homelab the daily run notices
the kernel is neither in the cache nor in its store and skips the switch instead
of starting a night of compiling on two cores, leaving the pull, the pins and
the collection done.

## T3 Code server

The homelab runs T3 Code from the same pin as the laptop. `apps/t3code/server.nix`
installs it with a user service, `t3code`, that runs `t3 serve` on port 3773; the
host has no display, so the desktop launcher in the package is never run. The
server publishes itself with `tailscale serve`, the same route shape the laptop's
app uses, so a client opens `https://homelab.<tailnet>.ts.net`.
`tailscale.operator` is on in `hosts/homelab/config.nix` because that is what
lets the service manage the route without sudo.

The unit is declared, not installed with `t3 service install`: that command
downloads its own versions and self-updates, while this host takes T3 from the
store and lets the daily update move it. `t3 update`, `t3 install`, and
`t3 service` are therefore not part of this host's workflow. A switch that
moves the pin activates the new server on its own.

One-time setup after the first switch:

```sh
ssh homelab pi auth login <provider>   # credentials land in ~/.pi; add --no-browser over ssh if needed
ssh homelab t3 pair --tailscale        # prints a tailnet pairing URL and an app link
```

Open the pairing link on the laptop, then enable the Pi provider in T3's
settings. T3 downloads the `pi-acp` adapter from the ACP registry with npm on
first use and runs `pi` from the server's PATH. The package's wrapper also puts
codex and gh on that PATH; there is no opencode or Claude CLI on the host, so Pi
is the one to configure.

The homelab consumes the T3 Code tag but not the daily `nixpkgs-unstable-small`
bump, because that input is not in its `wrapperInputs`. A bump usually only
relinks the wrapper and substitutes pi and codex; it forces a monorepo rebuild
only when the recipe's evaluated inputs change. Update the input by hand when a
tag needs a newer recipe, or when T3's Pi health check or `pi --version` shows a
pi below what the registry's adapter requires. The same frozen input supplies
the wrapper's codex, which a later T3 can mark too old without failing the
build. The tag itself arrives the same way every other change does: after a
push, on the next daily pull.

Because nothing substitutes `t3code`, a tag move whose recipe inputs changed
means the homelab compiles the T3 monorepo on two cores before that switch
finishes. Copying the laptop's `t3code-unwrapped` output over (`nix copy --to
ssh://homelab <path>`) skips that, and the wrapper relinks locally. The two
hosts must share the recipe pin for that path to match, which the manual bump
above is what aligns.

## Checks

Evaluate each configuration before switching:

```sh
nix eval --raw --no-write-lock-file .#nixosConfigurations.asus.config.system.build.toplevel.drvPath
nix eval --raw --no-write-lock-file '.#homeConfigurations."duskyelf@asus".config.home.activationPackage.drvPath'
nix eval --raw --no-write-lock-file .#nixosConfigurations.homelab.config.system.build.toplevel.drvPath
nix eval --raw --no-write-lock-file '.#homeConfigurations."duskyelf@homelab".config.home.activationPackage.drvPath'
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
apps/t3code/test-chrome-shim.sh   # the T3 browser shim, against a fake HOME
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

`AGENTS.md` holds the rules an agent needs before every task, plus the map. The
manual is here, and every other requirement has its reason in a comment beside
the code that depends on it, so read that comment before editing the code.
