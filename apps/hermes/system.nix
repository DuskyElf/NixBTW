# The system half of the agent app. Its home half (apps/hermes/home.nix) can
# bind the dashboard to a LAN address, which is a port on a machine-wide
# firewall, so that decision has to be visible here too. A host imports this
# file beside the home half; on a host whose hermes.dashboard.host is null it
# opens nothing.
#
# The assertion is the point of the file: the app binds the address from
# config.nix, and this file opens the port for it. If the two disagree with what
# the machine actually configures, eval fails instead of leaving a firewall hole
# in front of a dashboard that never came up.
{
  lib,
  config,
  hostConfig,
  ...
}:
let
  dashboard = hostConfig.hermes.dashboard;

  # Every IPv4 address this machine states, without the prefix length. Both
  # places a host can state one count: a static networking.interfaces entry and
  # a systemd-networkd unit, which is how the homelab states its address. An
  # address that arrives over DHCP or from NetworkManager is not listed,
  # because it is not in the configuration; a host that binds one has to state
  # it in one of these two places as well.
  stripPrefixLength = address: builtins.head (lib.splitString "/" address);

  configuredIpv4 = map stripPrefixLength (
    lib.flatten (
      lib.mapAttrsToList (_: iface: map (a: a.address) iface.ipv4.addresses) config.networking.interfaces
      ++ lib.mapAttrsToList (_: network: network.address) config.systemd.network.networks
    )
  );

  addressList = if configuredIpv4 == [ ] then "none" else lib.concatStringsSep ", " configuredIpv4;
in
{
  # The dashboard port, and only when a host deliberately published it.
  networking.firewall.allowedTCPPorts = lib.optional (dashboard.host != null) dashboard.port;

  assertions = [
    {
      # A name the machine answers to is a valid bind too, and the one the
      # module's waitFor = "hostname" mode waits for, so it passes.
      assertion =
        dashboard.host == null
        || builtins.elem dashboard.host configuredIpv4
        || builtins.elem dashboard.host [
          config.networking.hostName
          config.networking.fqdnOrHostName
        ];
      message = ''
        ${hostConfig.hostName}: hermes.dashboard.host is "${toString dashboard.host}", and this machine configures ${addressList} plus the name ${config.networking.fqdnOrHostName}. Bind an address the machine holds, state that address in hosts/${hostConfig.hostName}/system.nix, or leave hermes.dashboard.host null to keep the loopback bind.
      '';
    }
  ];
}
