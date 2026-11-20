# sshd. hostConfig.ssh.openLanPort = true keeps 22 on every interface, which is
# the recovery path on a box whose tailnet is what broke; false keeps it on the
# tailscale interface only, which is the laptop's policy. The rule for that
# interface is added whenever tailscale is enabled. Keys only, and root stays
# out.
{
  config,
  hostConfig,
  lib,
  ...
}:
{
  services.openssh = {
    enable = true;
    # The module default is true, which opens 22 on every interface.
    openFirewall = hostConfig.ssh.openLanPort;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AllowUsers = [ hostConfig.user.name ];
    };
  };

  # interfaceName has a value whether or not tailscale runs, so the rule is
  # gated on the service: a host without it has no tailnet interface at all.
  networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts =
    lib.mkIf config.services.tailscale.enable
      [ 22 ];
}
