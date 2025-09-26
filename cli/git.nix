{ ... }:
{
  programs.git = {
    enable = true;
    userName = "DuskyElf";
    userEmail = "91879372+DuskyElf@users.noreply.github.com";
    extraConfig = {
      init.defaultBranch = "main";
    };
  };
}
