{
  config,
  jail,
  pkgs,
  pkgs-unstable-small,
  ...
}:
{
  services.ollama.enable = true;
  home.packages = [
    (jail "pi" pkgs-unstable-small.pi-coding-agent (
      c: with c; [
        network
        mount-cwd
        (readwrite "/home/duskyelf/.pi")

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

  home.file.".pi".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/piBTW";
}
