# The home half of the homelab box. It is reached over ssh and has no desktop,
# so this is the whole home configuration beyond base/home.nix: a git identity
# for the account. apps/git.nix is the laptop's module and drags the jailed gh
# and worktrunk, which this machine does not need.
{
  hostConfig,
  ...
}:
{
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = hostConfig.user.git.name;
        email = hostConfig.user.git.email;
      };
      init.defaultBranch = "main";
    };
  };
}
