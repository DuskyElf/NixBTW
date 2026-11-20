# The system half of the agent app. The circuit it completes is three parts:
# the dashboard binds loopback (apps/hermes/home.nix), `tailscale serve` answers
# on 443 and proxies to that port, and hermes.dashboard.publicUrl states the
# origin the app should trust. A host that publishes nothing leaves publicUrl
# null and gets no unit here.
#
# The unit is declarative because the serve configuration lives in tailscaled's
# own state, not in this repo: a fresh /var/lib/tailscale, a reinstall, or a
# node that lost its state would otherwise come back with 443 unserved. It has
# to run once per tailscaled state, but running it on every boot is harmless
# and covers a reboot, and a changed hermes.dashboard.port overwrites the 443
# handler with the new target.
#
# Three facts the unit depends on exist only at runtime, so eval cannot check
# them and the script does: the node is Running, the tailnet has HTTPS enabled
# for this node, and the 443 mapping is recorded for the origin's host. Each
# failure names the setting to fix and leaves the unit failed; systemd retries
# in a minute, so enabling HTTPS in the admin console or logging the node in is
# enough, with no start by hand. Until those two one-time steps exist the unit
# is expected to fail, which `systemctl --failed` shows.
#
# Two of those are one-time tailnet settings and cannot be declared here:
# HTTPS certificates have to be enabled for the tailnet in the admin console,
# and the node has to be logged in once with `sudo tailscale up`, because the
# login is state in /var/lib/tailscale.
#
# No firewall rule: the dashboard is on loopback, and tailscaled carries the
# tailnet side itself.
{
  lib,
  config,
  pkgs,
  hostConfig,
  ...
}:
let
  dashboard = hostConfig.hermes.dashboard;

  # The assertion below pins the shape https://<hostName>.<tailnet>.ts.net, so
  # the host is the name the 443 mapping has to be recorded for.
  publicHost = lib.removePrefix "https://" dashboard.publicUrl;
in
{
  assertions = lib.optionals (dashboard.publicUrl != null) [
    {
      # Without the service there is no tailscale CLI and no tailnet to serve on.
      assertion = config.services.tailscale.enable;
      message = ''
        ${hostConfig.hostName}: hermes.dashboard.publicUrl is "${dashboard.publicUrl}", but tailscale is off. Import apps/tailscale.nix in hosts/${hostConfig.hostName}/default.nix, or leave publicUrl null to keep the dashboard local.
      '';
    }
    {
      # A tailnet name, not a LAN address or a typo. The HTTPS capability in
      # the unit is the runtime check; this one keeps a wrong shape out of eval.
      assertion = builtins.match "https://${lib.escapeRegex config.networking.hostName}\\.[a-z0-9-]+\\.ts\\.net" dashboard.publicUrl != null;
      message = ''
        ${hostConfig.hostName}: hermes.dashboard.publicUrl is "${dashboard.publicUrl}". It has to be https://${config.networking.hostName}.<tailnet>.ts.net, the MagicDNS name of this node, with no path and no port. apps/hermes/system.nix serves 443 of that name, and the app trusts exactly it for the Host check.
      '';
    }
  ];

  systemd.services.hermes-dashboard-serve = lib.mkIf (dashboard.publicUrl != null) {
    description = "Publish the Hermes dashboard on the tailnet";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tailscaled.service" ];
    after = [ "tailscaled.service" ];
    path = [
      config.services.tailscale.package
      pkgs.jq
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 60;
      TimeoutStartSec = 180;
      TimeoutStopSec = 10;
    };
    script = ''
      status="$(timeout 15 tailscale status --json --peers=false 2>/dev/null || true)"
      state="$(printf '%s' "$status" | jq -r '.BackendState // empty' 2>/dev/null || true)"
      if [ "$state" != "Running" ]; then
        echo "hermes-dashboard-serve: tailscaled is ''${state:-not answering}. Log the node in with 'sudo tailscale up'; this unit retries in 60 s." >&2
        exit 1
      fi
      if ! printf '%s' "$status" | jq -e --arg host ${lib.escapeShellArg publicHost} '((.CertDomains // []) | map(ascii_downcase | rtrimstr(".")) | index($host)) or ((.Self.CapMap // {}) | has("https"))' >/dev/null; then
        echo "hermes-dashboard-serve: this node has no HTTPS capability, so HTTPS certificates are off for the tailnet, or it has not finished joining. Enable HTTPS certificates in the admin console; this unit retries in 60 s." >&2
        exit 1
      fi
      if ! timeout -k 5 60 tailscale serve --bg --https=443 "http://127.0.0.1:${toString dashboard.port}"; then
        echo "hermes-dashboard-serve: tailscale serve failed or did not finish in 60 s; its own message is above. This unit retries in 60 s." >&2
        exit 1
      fi
      timeout 15 tailscale serve status --json | jq -e --arg key "${publicHost}:443" --arg target "http://127.0.0.1:${toString dashboard.port}" \
        '((.Web // {})[$key] // {}) as $web | (($web.Handlers // {})["/"] // {}).Proxy == $target' >/dev/null || {
        echo "hermes-dashboard-serve: could not read a 443 mapping for ${publicHost} from tailscale. Check that hermes.dashboard.publicUrl names this node; this unit retries in 60 s." >&2
        exit 1
      }
    '';
  };
}
