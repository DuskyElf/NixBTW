# Everything specific to this laptop: firmware, kernel tuning, nvidia, the
# screenpad. The shared machine config is base/, app modules are in apps/, and
# lib/mkHost.nix is what joins them.
#
# config.nix holds the values modules read (user, panels, battery); system.nix
# holds the driver, kernel, and firmware work that only this machine needs.
#
# This is the opt-in: this file imports the desktop base modules and the app
# modules the laptop runs. An app that spans both rebuilds gets one import in
# each list.
{
  config = [ ./config.nix ];
  system = [
    ../../base/workstation.nix
    ./system.nix

    ../../apps/auto-cpufreq.nix
    ../../apps/niri/system.nix
    ../../apps/keyd.nix
    ../../apps/openssh/system.nix
    ../../apps/tailscale.nix
    ../../apps/power.nix
    ../../apps/daily-update/system.nix
  ];
  home = [
    ../../base/home-workstation.nix

    ../../apps/sh.nix
    ../../apps/zsh.nix
    ../../apps/bash.nix
    ../../apps/home-switch.nix
    ../../apps/daily-update/home.nix
    ../../apps/git.nix
    ../../apps/openssh/home.nix
    ../../apps/tmux.nix
    ../../apps/nvim.nix
    ../../apps/languages.nix
    ../../apps/local-llm.nix
    ../../apps/opencode.nix
    ../../apps/kitty.nix
    ../../apps/zen-browser.nix
    ../../apps/chromium.nix
    ../../apps/blender.nix
    ../../apps/gnucash.nix
    ../../apps/idle.nix
    ../../apps/niri/home.nix
    ../../apps/wallpaper.nix
    ../../apps/quickshell.nix
    ../../apps/gammarelay.nix
  ];
}
