{
  config,
  pkgs,
  pkgs-unstable,
  jail,
  ...
}:
let
  home = config.home.homeDirectory;
in
{
  programs.git = {
    enable = true;

    signing = {
      key = "~/.ssh/id_ed25519_signing";
      format = "ssh";
      signByDefault = true;
    };

    settings = {
      user = {
        name = "DuskyElf";
        email = "git@duskyelf.me";
      };
      init.defaultBranch = "main";
    };
  };

  programs.worktrunk = {
    enable = true;
    package = pkgs-unstable.worktrunk;
  };

  home.packages = [
    (jail "gh" pkgs.github-cli (
      c: with c; [
        network
        mount-cwd
        (readonly "/run/current-system/sw/bin")
        (xdg-app home "gh")
      ]
    ))
  ];
}
