# One search endpoint in front of the three search APIs. SearXNG is gone: the
# engines it scrapes refuse this box's address, and public instances either
# block an API client or have JSON turned off.
#
# The caller uses apps/search/search.py, which is the only listener the tailnet
# reaches; it binds every address and the firewall rule at the bottom is what
# keeps the LAN out:
#
#   POST /search {"query": "...", "limit": 10, "freshness": "day|week|month|year",
#                  "provider": "tavily|exa|tinyfish"}
#     -> {"query", "provider", "results": [{title, url, content, published_at}],
#         "took_ms"}
#
#   GET /health -> {"ok", "providers": {"tavily": bool, "exa": bool, "tinyfish": bool}}
#
# One provider is chosen at random per request from those that have a key, and a
# refusal falls through to the next, so the three free tiers are spent evenly and
# one bad key or exhausted quota does not take the endpoint down. Nothing is
# scraped and nothing needs a proxy: each provider is somebody's paid API with a
# free allowance.
#
# The keys are not systemd environment: search.py reads SEARCH_KEYS per request,
# so writing a line takes effect on the next request. home.nix seeds the file
# with empty names; fill in what you have and leave the rest alone.
{
  config,
  hostConfig,
  lib,
  pkgs,
  ...
}:
let
  port = 10001;
  keysDir = "${hostConfig.user.home}/.config/search";
  keysFile = "${keysDir}/keys.env";
in
{
  # The service hides the whole home and binds back only the keys directory, so
  # that directory has to exist before its namespace is set up. Creating it here,
  # as root, is what makes the first start work: an empty file is enough, and
  # home.nix fills it when it is empty. The service wants this unit, so a restart
  # also recreates a directory that was removed.
  systemd.services.search-api-keys = {
    description = "Create the search API keys file";
    wantedBy = [ "multi-user.target" ];
    before = [ "search-api.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      ${pkgs.coreutils}/bin/install -d -m 0755 -o '${hostConfig.user.name}' '${keysDir}'
      ${pkgs.coreutils}/bin/chown '${hostConfig.user.name}:' '${keysDir}'
      if [ ! -e '${keysFile}' ]; then
        ${pkgs.coreutils}/bin/install -m 0600 -o '${hostConfig.user.name}' /dev/null '${keysFile}'
      fi
    '';
  };

  systemd.services.search-api = {
    description = "Search API: one endpoint over Tavily, Exa and TinyFish";
    wantedBy = [ "multi-user.target" ];
    wants = [ "search-api-keys.service" ];
    after = [
      "network.target"
      "search-api-keys.service"
    ];
    # Restart=always is the whole point of the failthrough, so systemd must not
    # disable the unit after five quick crashes and leave the endpoint dead.
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      User = hostConfig.user.name;
      ExecStart = "${pkgs.python3}/bin/python3 ${./search.py}";
      Restart = "always";
      RestartSec = 2;
      Environment = [
        "SEARCH_KEYS=${keysFile}"
        "SEARCH_PORT=${toString port}"
        "PYTHONDONTWRITEBYTECODE=1"
      ];
      # It reads one file and talks to three HTTPS endpoints. Nothing else in
      # the home is readable, so a bug in a network-facing HTTP handler cannot
      # hand out ~/.ssh; the read-only bind brings back the keys directory.
      ProtectSystem = "strict";
      ProtectHome = "tmpfs";
      BindReadOnlyPaths = [ "-${keysDir}" ];
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      LockPersonality = true;
    };
  };

  # The tailnet is the only way in, as for every service this repo publishes.
  networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts =
    lib.mkIf config.services.tailscale.enable
      [ port ];
}
