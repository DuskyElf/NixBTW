# The homelab box's identity, as data. The schema is lib/host.nix; base/ and
# apps/ read the result as `hostConfig`.
#
# It is a headless server on the LAN: bash instead of zsh, ssh open on the LAN
# instead of the tailnet, and no niri outputs, backlight, screenpad, or battery.
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

  # No tailnet on this box, so sshd opens 22 on every interface instead of on
  # the tailscale one only.
  ssh.openLanPort = true;

  # The one service on this box the home LAN may reach: the agent's dashboard,
  # so a browser on the laptop or a phone can use it without an ssh tunnel. It
  # is behind the app's own password gate (the credentials are in
  # ~/.config/hermes/env), and the address is the static one below in
  # system.nix, stated again because the app binds it and the firewall opens it.
  # Leave it null on a host that has no reason to publish an agent.
  hermes.dashboard.host = "192.168.1.200";

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
