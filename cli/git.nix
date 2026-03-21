{ pkgs, pkgs-unstable, ... }:
{
  programs.git = {
    enable = true;
    package = pkgs.gitFull;

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

  home.packages = [ pkgs.github-cli ];
}
