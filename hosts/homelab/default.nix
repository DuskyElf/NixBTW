# The homelab box: a headless server reached over ssh from the laptop. There is
# no desktop here, so it does not list base/workstation.nix. Its home
# configuration is base/home.nix plus the shared shell, editor, language and
# daily-update modules; the git identity stays in home.nix, and the desktop-only
# apps (tmux, zsh, opencode) are left off.
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

    ../../apps/openssh.nix
    ../../apps/daily-update/system.nix
    # The firewall side of the agent's dashboard bind in config.nix.
    ../../apps/hermes/system.nix
  ];
  home = [
    ./home.nix

    ../../apps/sh.nix
    ../../apps/bash.nix
    ../../apps/home-switch.nix
    ../../apps/daily-update/home.nix
    ../../apps/nvim.nix
    ../../apps/languages.nix

    # The always-on agent. Home half here; the system half above opens its
    # dashboard port. It runs as duskyelf through the linger this box already
    # sets.
    ../../apps/hermes/home.nix
  ];

  # Only the installer reads this; it is what nixos-anywhere formats with.
  disko = ./disko.nix;
}
