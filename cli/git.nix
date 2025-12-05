{ pkgs, ... }:
{
  programs.git = {
    enable = true;

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
