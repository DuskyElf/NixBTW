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
}
