{
  config,
  jail,
  pkgs-unstable,
  ...
}:
{
  home.packages = [
    (jail "pi" pkgs-unstable.pi-coding-agent (
      c: with c; [
        network
        mount-cwd
        (readwrite "/home/duskyelf/.pi")

        # can run any binary with limited file system access
        (readonly "/nix/store")
        (readonly "/run/current-system/sw/bin")
        (readonly "/home/duskyelf/.nix-profile/bin")
        (set-env "PATH" "/run/current-system/sw/bin:/home/duskyelf/.nix-profile/bin")

        (set-env "EDITOR" "vim")
      ]
    ))
  ];

  home.file.".pi".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/piBTW";
}
