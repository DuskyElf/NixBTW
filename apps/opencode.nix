# OpenCode, the coding agent, plus the config it reads from ~/.config/opencode.
# The laptop runs it as its own CLI; the homelab's T3 Code server runs it as a
# provider, so the binary has to stay on the profile PATH.
#
# The config is a live symlink into the checkout, not a store copy, so an edit
# to apps/opencode/opencodeBTW applies on the next opencode start with no
# switch. That directory is a submodule, so a fresh checkout needs it
# initialized.
#
# unstable-small is in the laptop's `wrapperInputs` but not the homelab's
# (hosts/homelab/config.nix), so the homelab's copy stays at the version
# deploy-system pins until that input is bumped there by hand. T3's OpenCode
# provider probes `opencode --version`, so a version it cannot probe shows up
# as a failed provider health check, not here.
{
  config,
  hostConfig,
  jail,
  pkgs,
  pkgs-unstable-small,
  ...
}:
{
  home.packages = [
    pkgs-unstable-small.opencode
    #(jail "opencode" pkgs-unstable-small.opencode (
    #  c: with c; [
    #    network
    #    mount-cwd

    #    (xdg-app config.home.homeDirectory "opencode")

    #    # cached git clone inspections
    #    (readwrite "/home/duskyelf/.git-clones/")

    #    # can run any binary with limited file system access
    #    (readonly "/nix/store")
    #    (readonly "/run/current-system/sw/bin")
    #    (readonly "/home/duskyelf/.nix-profile/bin")
    #    (readonly "/home/duskyelf/dotfiles/deploy-system/")
    #    (set-env "PATH" "/run/current-system/sw/bin:/home/duskyelf/.nix-profile/bin")

    #    (set-env "EDITOR" "vim")

    #    # clipboard: wl-copy/wl-paste need the Wayland socket
    #    wayland

    #    # done-bell: system notification + audio + media pause (mirrors apps/idle.nix break-timer)
    #    notifications
    #    pipewire
    #    (dbus {
    #      talk = [
    #        "org.mpris.MediaPlayer2.*"
    #        "org.freedesktop.DBus"
    #      ];
    #    })
    #    (add-pkg-deps [
    #      pkgs.playerctl
    #      pkgs.mako
    #      pkgs.libnotify
    #      pkgs.sound-theme-freedesktop
    #      pkgs.wl-clipboard
    #    ])
    #  ]
    #))
  ];

  home.file.".config/opencode".source =
    config.lib.file.mkOutOfStoreSymlink "${hostConfig.dotsDir}/apps/opencode/opencodeBTW";
}
