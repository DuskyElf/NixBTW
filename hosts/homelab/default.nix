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
  ];
  home = [ ./home.nix ];

  apps = {
    system = [
      "openssh"
      "auto-cpufreq"
      "daily-update"
    ];
    home = [
      "sh"
      "bash"
      "home-switch"
      "daily-update"
      "nvim"
      "languages"
    ];
  };

  # Only the installer reads this; it is what nixos-anywhere formats with.
  disko = ./disko.nix;
}
