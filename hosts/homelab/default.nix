# The homelab box: a headless server reached over ssh from the laptop. There is
# no desktop here, so it does not list base/workstation.nix. Its home
# configuration is base/home.nix plus the shared shell, editor, language,
# daily-update, and agent modules; the git identity stays in home.nix, and the
# desktop-only apps (tmux, zsh, opencode) are left off. What it does run beyond
# ssh is the T3 Code server, with pi as its agent, and t3mcp so that agent can
# drive either environment's T3 tools. A 2012 AMD A10 laptop: UEFI,
# one 500 GB HDD, no desktop.
#
# The install that produced it ran from the laptop, with the target booted from
# a live ISO:
#
#   nixos-anywhere --flake path:/home/duskyelf/dotfiles#homelab \
#     --generate-hardware-config nixos-generate-config \
#     /home/duskyelf/dotfiles/hosts/homelab/hardware.nix \
#     root@<live-iso-address>
#
# The flake is `path:` and not a git flake because nixos-generate-config writes
# hosts/homelab/hardware.nix during the run: path: reads the tree on disk,
# including files no commit has, while a git flake reads tracked files only.
# That file is committed afterwards. hosts/homelab/disko.nix is the layout
# nixos-anywhere formats with, and its header has the ISO that cannot kexec.
#
# The first system switch is by hand: the daily timer comes with the home
# generation, and the install does not create one. Put this checkout at
# /home/duskyelf/dotfiles there first (clone with --recurse-submodules, or copy
# the tree) and run lib/deploy/bootstrap.sh once, because the timer later runs
# the script from that checkout and switches that wrapper; without
# deploy-system/flake.nix the run skips its update half. Then, with nothing else
# switching the host, run the helper the installed generation links, or this
# explicit form when it did not bring one:
#
#   sudo nixos-rebuild switch --no-write-lock-file \
#     --flake /home/duskyelf/dotfiles/deploy-system#homelab \
#     --override-input my-dotfiles path:/home/duskyelf/dotfiles --cores 2
#
# Linger, the sudo rule and the helper come from the system half, so after this
# switch the daily run has everything it calls. The CI-built kernel is the one
# exception: hosts/homelab/system.nix has the two cases that miss the cache (a
# kernel CI has not published yet, or a running generation older than the
# trust), and the way through either is to import the kernel closure before
# running the helper, or to pass the substituter and key options to the rebuild.
#
# The home generation is not part of nixos-install, and the install runs before
# the first timer, so the first one is pushed by hand after that system switch.
# `nix copy` cannot: the installed daemon wants a signature for an untrusted
# push, so the export below writes the store as root instead, and the one
# password prompt is the console password. The build is the source flake, so it
# resolves the checkout's own flake.lock, the file the daily run locks; the
# wrapper is what the machine runs from then on.
#
#   gen=$(nix build --no-link --print-out-paths \
#     path:/home/duskyelf/dotfiles#homeConfigurations."duskyelf@homelab".activationPackage)
#   mkdir -p .tmp
#   nix-store --export $(nix-store -qR "$gen") > .tmp/home.nar
#   ssh homelab 'sudo nix-store --import' < .tmp/home.nar
#   ssh homelab "$gen/activate"
{
  config = [ ./config.nix ];
  system = [
    ./system.nix
    ./hardware.nix

    # The three files this machine needs because of what it is: its own trimmed
    # kernel, its CPU policy, and the idle work for this panel, codec and
    # rotational disk.
    ./kernel.nix
    ./cpu.nix
    ./idle.nix

    ../../apps/openssh/system.nix
    ../../apps/tailscale.nix
    ../../apps/daily-update/system.nix
  ];
  home = [
    ./home.nix

    ../../apps/sh.nix
    ../../apps/bash.nix
    ../../apps/home-switch.nix
    ../../apps/daily-update/home.nix
    ../../apps/nvim.nix
    ../../apps/languages.nix
    ../../apps/pi.nix
    ../../apps/t3code/server.nix
    ../../apps/t3code/t3mcp.nix
  ];

  # Only the installer reads this; it is what nixos-anywhere formats with.
  disko = ./disko.nix;
}
