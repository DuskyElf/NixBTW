# NixBTW

The NixOS and home-manager config for my laptop (`asus`, a UX581GV), plus the
small tools around it: the wallpaper pool, the status scripts, the T3 Code pin,
and the kernel cache.

This repo is the source tree, not the deploy unit. `deploy-system/` is a
gitignored wrapper flake that pins every input and holds `flake.lock`. It stays
private on purpose, so the exact nixpkgs, stylix, niri, and zen-browser
revisions are not published. A fresh clone can evaluate after its submodules
are checked out and Nix resolves the floating inputs, but the machine's exact
closure comes from that wrapper.

## First checkout

Clone [DuskyElf/NixBTW](https://github.com/DuskyElf/NixBTW) into `dotfiles`:

```sh
git clone --recurse-submodules https://github.com/DuskyElf/NixBTW dotfiles
```

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
| `home.nix`, `cli/`, `gui/` | `home-manager switch` |
| `system.nix`, `system-health.nix`, `hosts/` | `nixos-rebuild switch` |
| `gui/niri.nix` | `home-manager switch` (it is a home module) |
| `scripts/*.mjs`, `hot-configs/`, `quickshell/` | nothing, they are linked live |
| `scripts/power.sh` | `nixos-rebuild switch` (it lands in `/usr/local/sbin`) |
| `scripts/machine-digest.sh` | `nixos-rebuild switch` (the unit reads the store copy) |

A `neovimBTW` submodule bump also needs `nix flake update neovimBTW` inside
`deploy-system/`, then a switch. `opencodeBTW` and `piBTW` are symlinked, not
flake inputs.

## Layout

| Path | What it owns |
| --- | --- |
| `flake.nix` | inputs, outputs, kernel selection, jail combinators |
| `system.nix` | machine config, `power.sh`, sudo rule, tailscale, nix cache |
| `system-health.nix` | weekly machine digest service |
| `hosts/asus/` | hardware, filesystems, custom kernel, BIOS unlock entries |
| `home.nix` | user, stylix, the daily auto-update timer |
| `cli/` | shell, git, tmux, neovim, languages, agents, T3 Code, local LLM lab |
| `gui/` | niri, kitty, browsers, blender, gnucash, idle |
| `scripts/` | wallpaper, status bars, power, digest, T3 Code pin updater, deploy bootstrap |
| `hot-configs/` | `tmux.conf`, symlinked live |
| `quickshell/` | bar and OSD QML, symlinked live |
| `neovimBTW/`, `opencodeBTW/`, `piBTW/` | submodules with their own docs |

`scripts/` and `quickshell/` are `mkOutOfStoreSymlink` targets, so edits apply
without a switch.

## What is pinned

| Thing | Where | Why |
| --- | --- | --- |
| kernel nixpkgs | `flake.nix` | CI builds the same kernel derivation as the laptop, so the signed cache hits |
| T3 Code main | `cli/t3code-main.lock.nix` | upstream commit plus the three vendor hashes, moved daily |
| `setup_var.efi` | `hosts/asus/system.nix` | BIOS unlock entry, by version and hash |
| NVIDIA driver | `hosts/asus/system.nix` | must match the custom kernel, and this closure is in no public cache |

The other inputs float through the private lock, including system nixpkgs,
unstable for niri, unstable-small for the agents, home-manager, stylix,
jail-nix, and zen-browser. The daily timer updates three of them. The kernel
pin has its own rotation, described below.

## What runs

Systemd units do the background work, not shell daemons. The daily wrapper
update and the weekly digest have timers. The wallpaper fetch, rotate, resume,
and startup units live in `gui/niri.nix`, together with `awww-daemon`,
`quickshell`, `wl-gammarelay`, and `break-timer`. `battery-threshold-control`
and `screenpad-off` are one-shot system services. `llm-lab` starts ollama and
Open WebUI only when you ask.

## The daily update

The user timer `flake-auto-update` runs at 08:30 and catches up after wake. It
waits for network, runs `nix flake update nixpkgs nixpkgs-unstable-small
zen-browser` and `scripts/update-t3code-main.sh`, switches home-manager, then
commits the wrapper lock.

The kernel moves on a different track. `.github/workflows/check-kernel-update.yml`
compares the pinned `nixpkgs-fast-release` rev with `release-26.05` and opens a
PR when the stable kernel changes. Merging it triggers `compile-kernel.yml`,
which publishes the kernel to the signed cache at `duskyelf.github.io/NixBTW`.
The next `nixos-rebuild` substitutes it instead of compiling for two hours.

System rebuilds stay manual. The timer only touches home-manager.

## Checks

Evaluate both configurations before switching:

```sh
nix eval --raw .#nixosConfigurations.asus.config.system.build.toplevel.drvPath
nix eval --raw '.#homeConfigurations."duskyelf@asus".config.home.activationPackage.drvPath'
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
nix eval --raw .#kernelVersion   # the series the selector picked
scripts/test-machine-digest.sh   # shape of the weekly report
nix fmt                          # nixfmt-tree over the repo
```

## This is not a template

Disk UUIDs, BIOS offsets, undervolt values, the screenpad quirk, and the kernel
tuning all describe one UX581GV. A second machine should get its own
`hosts/<name>` and a real hardware config, not a copy of `hosts/asus`.

`AGENTS.md` is the operating manual for agents working in this tree. It also
lists the load-bearing oddities in the kernel, stylix, screenpad, and power
paths, with the reason each one has to stay as it is. Read it before changing
any of those.
