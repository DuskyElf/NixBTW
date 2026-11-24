This repo is my nix dotfiles for all of my hosts. It contains my entire machine, NixOS, home-manager, niri, scripts, editors, agents. You are a guest with wide read access. Treat that as trust to repay with care, not room to act. Each host is under `hosts/` (my main laptop and homelab for now).

Control rules:
* Never widen a trust boundary to make a job easier. Sandboxed commands stay sandboxed. `power.sh` stays the only root path from keybinds.
* Test before you report back. Reproduce with a deterministic check where possible and paste the exact result.
* Leave the tree clean. Never commit agent state, lock noise, or session files.

Both the machines auto update daily (`apps/daily-update/`). This repo is NOT the deploy flake. `deploy-system/` is a private wrapper flake pinning this repo as `my-dotfiles`. It is gitignored with its own nested git repo, pushed to the private `NixBTW-deploy` repository, and its flake.lock is the lock source of truth for the wrapper's own inputs. The checkout keeps an untracked, gitignored `flake.lock` of its own, which a `path:` override reads and a standalone git-flake eval ignores (git flakes read tracked files only); the daily run rewrites it as you so the two stay in agreement. Each host store their own deploy flake independently.

The layout is the first thing to read:
* `flake.nix` declares inputs and outputs, nothing else. Every directory under `hosts/` becomes a host.
* `lib/` is the plumbing: nixpkgs instances, the jail wrapper, the kernel call, `mkHost`, and `lib/deploy/`. `lib/host.nix` is the option schema, evaluated once by `lib/mkHost.nix` and passed to `base/` and `apps/` as `hostConfig`, so never hardcode a username, connector name, or device path in a shared module; add an option instead.
* `base/` is machine-wide config split by machine type: `core.nix` and `workstation.nix` on the system side, `home.nix` and `home-workstation.nix` on the home side. A host lists the half it wants, and the bootloader stays in the host's `system.nix` because it is hardware.
* `apps/` is one app's config per file, with split apps in a subdirectory that also holds their own assets. There is no registry: a host imports the module it wants, one import per half for a split app, and the list the import sits in decides which rebuild applies.
* `hosts/<name>/` is one machine: `config.nix` holds its identity and hardware as data, `default.nix` the imports, `system.nix` the drivers, kernel, and bootloader, `disk.nix` and `disko.nix` the disk layout.
* `pkgs/` builds the packages this repo owns, currently the T3 Code stable pin and its update scripts.

`hosts/asus/` is the laptop, `hosts/homelab/` a headless box on the LAN. A change to a shared module has to suit both.
`ssh homelab` for setting up things there. (assuming you're on the laptop)

Agents fetch through the pi agent's own repo on the homelab (`~/.pi/agent` there, not this checkout):
* Fetch: `ssh homelab '~/.pi/agent/tools/fetch URL --json'` prints `{url, status, text, text_file, images, screenshot, fetched_at, filter, llm, llm_error}`. `--images` adds a screenshot and up to 8 page images; `--query Q` filters the text, by a free OpenCode Go model when `~/.pi/user/fetch/keys.env` has a key, by keyword otherwise. A failure exits 1 and prints `fetch: ...` on stderr, plus `{"error": ...}` on stdout with `--json`; a bad or non-public URL exits 2 without JSON. Paths are absolute on homelab, so a caller on the laptop pulls one with `scp homelab:<path> .`, and runs are pruned at 24 hours and 256 MB. Each call starts one browser and exits: no port, no service, no listener.

Search is not served here either. The pi agent on the homelab owns it in that same repo: run `ssh homelab '~/.pi/agent/tools/search "query" --limit 10 --freshness day'` (freshness is day, week, month or year). It prints JSON `{provider, results:[{title, url, content, published_at}]}` from Tavily, Exa or TinyFish and falls through when one refuses. Keys are in `~/.pi/user/search/keys.env` there.

Subrepos own their domains. Read their docs when you work inside them and do not duplicate them here:
* `apps/nvim/neovimBTW/`
* `apps/opencode/opencodeBTW/`
* `apps/wallpaper/wallpaper-guardian/`

Submodule bumps (e.g. `neovimBTW`) do not reach a switch through the live-tree override alone. The wrapper pins each submodule as its own flake input, so run `nix flake update <name>` inside `deploy-system/` after the bump, then switch; the daily timer does it for the inputs in `dailyUpdate.wrapperInputs`. The exception is `apps/opencode/opencodeBTW`, which `apps/opencode.nix` links from the checkout, so a bump needs neither a flake update nor a switch.

All rebuilds go through the wrapper with the live-tree override, so uncommitted edits apply immediately:
* System `sudo /usr/local/sbin/nixos-switch.sh`.
* Home `~/.config/scripts/hm-switch.sh`.

A few paths are not obvious from the import list: `apps/niri/system.nix` needs the system helper while the rest of `apps/niri/` is a home module, `apps/tailscale.nix` is system because the tailnet service runs on both hosts, and a change to `flake.nix` or `lib/` reaches both configurations, so run both and let the system half go first.

Both the hosts currently have custom kernel config that's heavily fine-tuned for the hardware. It's built on Github actions and released on github & gh-pages and then used as cache. There's Github CI for checking for kernel update daily independent of the hosts. The CI creates a PR, when merged starts to build the kernel on github. Nothing is built locally on either host in normal use; the code documents two exceptions, a kernel no cache holds yet (the laptop compiles it, the homelab skips) and the NVIDIA driver's userspace closure, which builds once on the laptop.

A host with no helper yet runs the explicit `nixos-rebuild switch` or `home-manager switch` against `deploy-system` with the live-tree override; the plain `home-manager` CLI is also what runs `news` and `generations`, and `home-manager switch --rollback`.

Edits to a live-linked asset go live at once, no rebuild: `apps/quickshell/` is linked to `~/.config/quickshell`, `apps/tmux/tmux.conf` and `apps/opencode/opencodeBTW` the same way, and `apps/daily-update/active-projects` is read at run time. Exception: `apps/power/power.sh` is store-pinned and symlinked into `/usr/local/sbin`, so it needs a nixos-rebuild, and any root action from a keybind must route through it or sudo hangs the keybind.

Background work is a systemd unit, never a shell daemon.

Packages are as jailed as possible using `lib/jail.nix`, see each app module to check their perms.

Checks worth running before a switch: `nix fmt`; the tests beside what they cover, which all run against fakes with no network or store access (`pkgs/t3code/test-update.sh`, `pkgs/t3code/test-update-server.sh`, `apps/t3code/test-chrome-shim.sh`, `apps/home-switch/test-hm-switch.sh`, `apps/daily-update/test-daily-update.sh`, `hosts/homelab/test-undervolt-guard.py`); and, for a change that only moves files, a before-and-after diff of `home.packages` and `environment.systemPackages` evaluated with `nix eval --json`, because `nix store diff-closures` compares names and versions, so a rebuilt package at the same version is invisible to it.

What belongs in this file (AGENTS.md):
A line stays only if every task needs it, a new agent would get it wrong without it, and no comment in the code already says it. When you add a line, name the task that breaks without it; when a behavior changes, prune the line that explains it. Everything else is a comment beside the code it describes, kept in sync with the change; install steps and one-off procedures live beside the code that owns them, and `README.md` stays the overview.
