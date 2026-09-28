{
  config,
  jail,
  pkgs,
  pkgs-unstable-small,
  ...
}:
{
  home.packages = [
    (jail "opencode" pkgs-unstable-small.opencode (
      c: with c; [
        network
        mount-cwd

        (xdg-app config.home.homeDirectory "opencode")

        # can run any binary with limited file system access
        (readonly "/nix/store")
        (readonly "/run/current-system/sw/bin")
        (readonly "/home/duskyelf/.nix-profile/bin")
        (readonly "/home/duskyelf/.deploy-system/")
        (set-env "PATH" "/run/current-system/sw/bin:/home/duskyelf/.nix-profile/bin")

        (set-env "EDITOR" "vim")

        # done-bell: system notification + audio + media pause (mirrors gui/idle.nix break-timer)
        notifications
        pipewire
        (dbus {
          talk = [
            "org.mpris.MediaPlayer2.*"
            "org.freedesktop.DBus"
          ];
        })
        (add-pkg-deps [
          pkgs.playerctl
          pkgs.mako
          pkgs.libnotify
          pkgs.sound-theme-freedesktop
        ])
      ]
    ))
  ];

  home.file.".config/opencode".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/opencodeBTW";
}
