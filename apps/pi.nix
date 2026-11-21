# Pi, the coding agent (pi.dev), on a host where T3 Code runs it. T3's Pi
# provider does not embed the agent: it installs the pi-acp adapter from the
# ACP registry and that adapter spawns `pi --mode rpc`, so the CLI has to be on
# the server's PATH. Pi's own config and login are one-time state in ~/.pi and
# stay app-owned; `pi auth login` is where that lives.
#
# unstable-small rather than stable: pi-acp requires pi 0.81 or newer, and
# stable 26.05 carries 0.75.4. That input is not in this host's daily update,
# so bump it in deploy-system by hand when a newer pi is wanted. The assertion
# is a floor, not a live check: T3 fetches the adapter from the ACP registry at
# runtime, so an adapter that moves past this host's frozen pi shows up as a
# failed Pi provider health check, not here.
{
  lib,
  pkgs-unstable-small,
  ...
}:
{
  assertions = [
    {
      assertion = lib.versionAtLeast pkgs-unstable-small.pi-coding-agent.version "0.81";
      message = "pi-acp needs pi 0.81 or newer, and nixpkgs-unstable-small on this host is older; update that input in deploy-system";
    }
  ];

  home.packages = [ pkgs-unstable-small.pi-coding-agent ];
}
