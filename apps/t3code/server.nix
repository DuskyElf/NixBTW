# The headless half of T3 Code: upstream's prebuilt server, a user service that
# keeps it running, and the browser it needs for previews. The tarball is
# fetched and patched, never compiled, because this host's A10 is not the place
# to build a pnpm workspace and a Rust monitor; pkgs/t3code/server-lock.nix
# pins it separately from the laptop's source build.
#
# The service is declared rather than installed with `t3 service install`:
# that command downloads versions into ~/.t3 and self-updates, while this host's
# T3 comes from the nix store and moves when the server pin moves. `t3 update`,
# `t3 install` and `t3 service` are therefore not part of this host's workflow.
# A switch that moves the pin changes the unit's ExecStart, so systemd restarts
# the service with the new server and nothing has to be restarted by hand.
#
# Clients reach it over Tailscale Serve, the same way the laptop publishes its
# own server, so a client opens `https://homelab.<tailnet>.ts.net`, this node's
# name under the tailnet's DNS name, with no port in the URL. The server binds
# 127.0.0.1 (`--host` below), so that name is the way in from another machine,
# including the t3mcp tool the pi agent runs (~/.pi/agent/tools/t3mcp).
# That needs tailscaled and this user as its operator
# (hostConfig.tailscale.operator), and it serves HTTPS with a valid certificate
# from the tailnet, which a browser needs before it will hand the app its
# clipboard or crypto APIs. The route is set by the server itself on startup
# and repaired while it runs. A start before tailscaled answers leaves the
# route off until the next restart; ExecStartPre keeps that from happening at
# boot.
#
# One-time setup after the first switch: `ssh homelab pi auth login <provider>`
# writes the model credentials to ~/.pi, with `--no-browser` when the login has
# to run over ssh, and `ssh homelab t3 pair --tailscale` prints a pairing URL
# and an app link. Open the link on the laptop, then enable the Pi provider in
# T3's settings. T3 fetches the pi-acp adapter from the ACP registry with npm on
# its first use and runs `pi` from the service PATH below, which is the login
# profile plus the system profile: git, gh, node and opencode are there, and the
# Claude CLI is not.
#
# OpenCode is the second provider: apps/opencode.nix puts its CLI on that same
# PATH. After `ssh homelab opencode auth login --standalone`, enable the
# provider in T3's settings. --standalone keeps the login from starting a
# background service on a headless box; opencode's login and its config at
# ~/.config/opencode decide which providers and models it offers.
{
  config,
  hostConfig,
  lib,
  pkgs,
  ...
}:
let
  # Dropping the source wrapper also drops T3CODE_CLOUDFLARED_PATH: T3 Connect
  # would then fetch cloudflared into ~/.t3. This host publishes over tailscale
  # serve and never uses T3 Connect.
  t3code = import ../../pkgs/t3code/server.nix { inherit pkgs; };

  # PAM already puts the profile on the user manager's PATH; it is stated here
  # so the service does not depend on that policy, and so the providers T3
  # spawns resolve pi, opencode, npm, and git to the ones this configuration
  # installs.
  searchPath = [
    "${config.home.homeDirectory}/.nix-profile/bin"
    "/run/current-system/sw/bin"
  ];
in
{
  # A host that imports this module serves the port below over the tailnet, and
  # without the operator the server runs but no client can reach it.
  assertions = [
    {
      assertion = hostConfig.tailscale.operator;
      message = "apps/t3code/server.nix publishes with tailscale serve; set tailscale.operator for this host's user";
    }
  ];

  home.packages = [
    t3code
    # T3 installs its ACP agent adapters with npm from PATH, and pi is spawned
    # through one of them. Installing node here keeps that dependency owned by
    # this module instead of borrowed from a dev module a server might not have.
    pkgs.nodejs
    # The source wrapper used to put gh on T3's PATH for its GitHub provider;
    # the prebuilt tarball does not, so the profile provides it.
    pkgs.gh
    # T3's html_render and browser tools spawn their own Chrome for Testing
    # download, which wants a glibc loader NixOS does not have. chrome-shim.sh
    # points each download at this browser instead.
    pkgs.chromium
  ];

  # Anchored to the package install so the Chromium the shim points at exists
  # on a first switch.
  home.activation.t3HeadlessChromeShim = config.lib.dag.entryAfter [
    "installPackages"
  ] "run ${./chrome-shim.sh}";

  systemd.user.services.t3code = {
    Unit = {
      Description = "T3 Code server";
      # A boot where tailscaled is slower than the user manager must keep
      # retrying rather than give up at systemd's five starts per 300 s.
      StartLimitIntervalSec = 0;
    };
    Service = {
      Type = "simple";
      WorkingDirectory = "%h";
      Environment = [ "PATH=${lib.concatStringsSep ":" searchPath}" ];
      # tailscaled is a system service with no ordering edge into the user
      # manager, so gate on it being answerable.
      ExecStartPre = "${pkgs.tailscale}/bin/tailscale status";
      ExecStart = "${t3code}/bin/t3 serve --mode web --host 127.0.0.1 --no-browser --port 3773 --tailscale-serve";
      Restart = "always";
      RestartSec = 5;
      # As in upstream's own unit: the server gets SIGTERM, anything it left
      # behind gets SIGKILL, so a provider cannot hold the stop open. Agents T3
      # puts in its own slice are outside this cgroup and unaffected.
      KillMode = "mixed";
      # An OOM kill of a browser or helper in this cgroup must not take the
      # server and every session with it, which is systemd's default.
      OOMPolicy = "continue";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
