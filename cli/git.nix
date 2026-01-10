{ pkgs, ... }:
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
        email = "91879372+DuskyElf@users.noreply.github.com";
      };
      init.defaultBranch = "main";
    };
  };

  home.packages = [ pkgs.github-cli ];
}
