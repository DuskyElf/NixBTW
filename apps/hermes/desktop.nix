# Hermes Desktop on the laptop. The application and the command line, no
# daemons: a backend service on this machine would be a second, unused one once
# the app is pointed at the homelab's, and the application carries the same
# hermes-agent runtime the service would, so the command line below adds
# symlinks to that same store path rather than a second copy.
#
# The command line is here for t3code's local ACP provider. Settings > Providers
# > Add provider > Show more > Local ACP command runs `hermes acp` from the
# server process, which inherits the session PATH, so `hermes` has to be on it.
# `programs.hermes-agent.enable` is what puts it there; `desktop.enable` alone
# installs hermes-desktop and leaves the `hermes` binary out of the profile.
#
# The upstream module is imported for its option, and only once per machine:
# it declares both `programs.hermes-agent` and `services.hermes-agent`, so a
# host that imported it here and again in apps/hermes/home.nix would fail eval
# on the second declaration. This host runs neither service.
#
# Nix can only point the application at a local backend, so the homelab's is a
# one-time connection in the app itself: its Settings, under Gateways, takes
# https://homelab.tail5dc115.ts.net, which is the homelab's
# hermes.dashboard.publicUrl. Replace any entry for the old LAN address with
# it; a stale entry that still ranks first leaves the app pointed at an origin
# that no longer answers, with the password cached for it. The sign-in window
# reads the provider list from the URL. The connection is real TLS over the
# tailnet, so the laptop has to be logged in to the same tailnet and a phone
# needs the Tailscale app. The dashboard password comes from the box's
# ~/.config/hermes/env; if the window does not take it, the box also publishes a
# session token, which the same dialog accepts.
{ inputs, ... }:
{
  imports = [ inputs.hermes-agent.homeManagerModules.default ];

  programs.hermes-agent.enable = true;
  programs.hermes-agent.desktop.enable = true;
}
