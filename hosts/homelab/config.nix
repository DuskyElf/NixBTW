# The homelab box's identity, as data. The schema is lib/host.nix; base/ and
# apps/ read the result as `hostConfig`.
#
# It is a headless server on the LAN: bash instead of zsh, ssh open on the LAN
# as well as the tailnet, and no niri outputs, backlight, screenpad, or battery.
{
  hostName = "homelab";
  timeZone = "Asia/Kolkata";

  stateVersion = {
    system = "26.05";
    home = "26.05";
  };

  locale = {
    default = "en_US.UTF-8";
    # Strings and regional formats are both English: the machine is reached
    # over ssh, so its output should look like the laptop's.
    extra = null;
  };

  user = {
    name = "duskyelf";
    home = "/home/duskyelf";
    description = "DuskyElf";
    shell = "bash";
    git = {
      name = "DuskyElf";
      email = "duskyelf.dev+git@gmail.com";
      # The signing key lives on the laptop; commits made here are unsigned.
      signingKey = null;
    };
  };

  # The box has a tailnet now, and 22 stays open on the LAN as the recovery
  # path: if tailscaled or the tailnet is what broke, ssh over the LAN is how to
  # get in and fix it. apps/openssh/system.nix allows 22 on the tailscale
  # interface either way.
  ssh.openLanPort = true;

  # The box updates itself once a day like the laptop, but only the stable
  # track: nixpkgs, and the two submodule inputs the wrapper pins. No T3 Code
  # pin and no devshell pin. It has no graphical session, so the timer needs
  # linger to start at boot, and two cores keep a rebuild polite on the A10. The
  # store caches stay in the home directory (the default cacheRoot): there is no
  # scratch tmpfs here.
  dailyUpdate = {
    collect = true;
    linger = true;
    cores = 2;
    wrapperInputs = [
      "nixpkgs"
      "neovimBTW"
      "wallpaper-guardian"
    ];
    # This box runs a kernel CI builds (hosts/homelab/kernel.nix), and a
    # kernel that has not been published yet is hours of compile on two
    # cores. The daily run checks this cache first and skips the switch
    # instead, so a failed or late CI run costs a day, not a night.
    kernelCache = "https://duskyelf.github.io/NixBTW";
  };
}
