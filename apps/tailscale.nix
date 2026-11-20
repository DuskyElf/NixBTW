# Tailscale on every machine: the laptop uses it for the t3code server on 3773,
# which the app publishes with `tailscale serve`, and the homelab for ssh and
# the agent's dashboard. The daemon is the same on both; who may operate it is
# host data (tailscale.operator in lib/host.nix), because the operator can
# manage serve and funnel targets without sudo.
#
# The node's own login is one-time state in /var/lib/tailscale: it cannot be
# declared here, and a fresh install stays logged out until somebody runs
# `sudo tailscale up`. Which service rides the tailnet is the app's own file,
# not this one.
{
  lib,
  hostConfig,
  ...
}:
{
  services.tailscale = {
    enable = true;
    openFirewall = true;
    extraSetFlags = lib.optionals hostConfig.tailscale.operator [
      "--operator=${hostConfig.user.name}"
    ];
  };
}
