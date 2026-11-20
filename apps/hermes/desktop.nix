# Hermes Desktop on the laptop. Only the application: the daemons stay off
# here, because a backend service on this machine would be a second, unused one
# once the app is pointed at the homelab's, and the application carries the same
# hermes-agent runtime the service would, so it installs no second copy.
#
# The upstream module is imported for its option, and only once per machine:
# it declares both `programs.hermes-agent` and `services.hermes-agent`, so a
# host that imported it here and again in apps/hermes/home.nix would fail eval
# on the second declaration. This host runs neither service.
#
# Nix can only point the application at a local backend, so the homelab's is a
# one-time connection in the app itself: its Settings, under Gateways, takes the
# dashboard URL (AGENTS.md has the address), and its sign-in window reads the
# provider list from there. The dashboard password comes from the box's
# ~/.config/hermes/env; if the window does not take it, the box also publishes a
# session token, which the same dialog accepts.
{ inputs, ... }:
{
  imports = [ inputs.hermes-agent.homeManagerModules.default ];

  programs.hermes-agent.desktop.enable = true;
}
