{
  config,
  jail,
  lib,
  pkgs,
  pkgs-unstable-small,
  ...
}:
let
  # nixos-unstable-small at d63e5b96ca17 carries codex 0.167.0 without the
  # system-library inputs that nixpkgs 16b463698a added. codex replaces its
  # cargoDeps with overrideAttrs, which drops the default crate overrides, so
  # aws-lc-sys sees AWS_LC_SYS_USE_SYSTEM=1 and no system AWS-LC and fails the
  # build. Supply the missing inputs here; becomes a no-op once the pin ships
  # the fix. Drop this then.
  codex = pkgs-unstable-small.codex.overrideAttrs (
    old:
    lib.optionalAttrs (!lib.any (p: (p.pname or "") == "aws-lc") old.buildInputs) {
      buildInputs =
        old.buildInputs
        ++ (with pkgs-unstable-small; [
          aws-lc
          oniguruma
          sqlite
          zstd
        ]);
    }
  );
  t3code = pkgs-unstable-small.t3code.override { inherit codex; };
in
{
  home.packages = [
    pkgs-unstable-small.opencode
    t3code
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

    #    # done-bell: system notification + audio + media pause (mirrors gui/idle.nix break-timer)
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
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/opencodeBTW";
}
