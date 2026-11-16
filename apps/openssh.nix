# sshd, so the phone and other machines on the tailnet can reach this box. The
# LAN stays closed on purpose (see base/system.nix), so port 22 is allowed on
# the tailscale interface only. Keys only, and root stays out: the controller
# key lives in /root/.ssh/authorized_keys on the live system only, which this
# repo does not manage.
{
  config,
  hostConfig,
  ...
}:
{
  services.openssh = {
    enable = true;
    # The module default is true, which opens 22 on every interface.
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AllowUsers = [ hostConfig.user.name ];
    };
  };

  networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
    22
  ];
}
