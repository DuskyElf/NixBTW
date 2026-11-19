# Everything specific to this laptop: firmware, kernel tuning, nvidia, the
# screenpad. The shared machine config is base/, app modules are in apps/, and
# lib/mkHost.nix is what joins them.
#
# config.nix holds the values modules read (user, panels, battery); system.nix
# holds the driver, kernel, and firmware work that only this machine needs.
#
# This is the opt-in: this file lists the desktop base modules and the apps the
# laptop runs. The app names are resolved against apps/default.nix.
{
  config = [ ./config.nix ];
  system = [
    ../../base/workstation.nix
    ./system.nix
  ];
  home = [ ../../base/home-workstation.nix ];

  apps = {
    system = [
      "auto-cpufreq"
      "niri"
      "keyd"
      "openssh"
      "power"
      "daily-update"
    ];
    home = [
      "sh"
      "zsh"
      "bash"
      "home-switch"
      "daily-update"
      "git"
      "tmux"
      "nvim"
      "languages"
      "local-llm"
      "opencode"
      "kitty"
      "zen-browser"
      "chromium"
      "blender"
      "gnucash"
      "idle"
      "niri"
      "wallpaper"
      "quickshell"
      "gammarelay"
    ];
  };
}
