{
  config,
  pkgs-unstable-small,
  jail,
  ...
}:
{
  home.packages = [
    (jail "opencode" pkgs-unstable-small.opencode (
      c: with c; [
        network
        mount-cwd
        (readwrite "/home/duskyelf/.config/opencode")

        # can run any binary with limited file system access
        (readonly "/nix/store")
        (readonly "/run/current-system/sw/bin")
        (readonly "/home/duskyelf/.nix-profile/bin")
        (set-env "PATH" "/run/current-system/sw/bin:/home/duskyelf/.nix-profile/bin")

        (set-env "EDITOR" "vim")
      ]
    ))
  ];

  xdg.configFile."opencode".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/opencodeBTW";
}
