# sshd. On the laptop the LAN stays closed (see base/core.nix), so port 22 is
# allowed on the tailscale interface only; a host with no tailnet, like the
# homelab box, sets hostConfig.ssh.openLanPort instead. Keys only, and root
# stays out.
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
