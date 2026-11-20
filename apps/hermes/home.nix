# Hermes Agent: Nous Research's agent, run as a user service for the one
# account on this box. The gateway is always on, the dashboard answers on
# 127.0.0.1:9119 unless the host asks for a LAN bind, and the state in
# ~/.hermes is the same one `hermes` uses over ssh, because
# programs.hermes-agent exports HERMES_HOME.
#
# The dashboard is the one service in this tree a host may publish (see
# hermes.dashboard in lib/host.nix). The homelab does, on its LAN address:
# `backend.host` carries that literal address, and `settings.dashboard.public_url`
# states the same origin so the app's Host check accepts it. Binding the
# address rather than 0.0.0.0 matters: the wildcard also switches that check
# off.
#
# A non-loopback bind turns on the app's auth gate, and a gated dashboard with
# no provider registered exits at start, so the backend unit restarts for ever.
# The values that satisfy the gate are in `~/.config/hermes/env`, which is the
# environmentFiles entry below, and never in `settings`: settings are rendered
# into config.yaml in the store, where every user on the box can read them.
#
#   HERMES_DASHBOARD_BASIC_AUTH_USERNAME=<name>
#   HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=scrypt$...   (or _PASSWORD, plaintext)
#   HERMES_DASHBOARD_BASIC_AUTH_SECRET=<base64 of 32 or more random bytes>
#
# The secret has to be that literal base64 value: a value that looks like an
# unexpanded shell command is discarded, and an empty one mints a key per
# process, which signs every session out on each restart.
#
# `backend.sessionTokenFile` is the second provider, the bearer token machine
# clients present, and the fallback if the desktop app's sign-in window does not
# take the password. The file has to exist and be non-empty before the switch:
# the backend unit exits when it is named and unreadable, and restarts for ever.
# `head -c 32 /dev/urandom | base64` into `~/.config/hermes/session-token`, mode
# 0600, is the whole of it.
#
# The provider key is not here either, and it is not read from this file at
# runtime. Hermes reads `~/.hermes/.env`, and the activation builds that file
# from `~/.config/hermes/env`. So a new key is: `mkdir -p ~/.config/hermes`,
# create the file mode 0600 on the box, one KEY=value per line
# (OPENROUTER_API_KEY=..., ANTHROPIC_API_KEY=...), run
# `~/.config/scripts/hm-switch.sh --force` to re-run the activation, then
# restart `hermes-agent` and `hermes-backend`. That is the same path a change
# to the three gate values takes. A plain restart picks up nothing, and the
# activation only warns while the file is absent.
#
# Not jailed (lib/jail.nix): the agent's job is running arbitrary tools with
# network access over the whole home, so a jail here would either break it or
# grant the same. It runs as duskyelf, in a user unit, with no privileges.
#
# Managed mode is on (the nix module sets it), so `hermes setup` and
# `hermes config set` refuse to run: the settings below are the settings, and a
# change to them is a home switch.
{
  config,
  lib,
  inputs,
  hostConfig,
  ...
}:
let
  dashboard = hostConfig.hermes.dashboard;
in
{
  imports = [ inputs.hermes-agent.homeManagerModules.default ];

  services.hermes-agent = {
    enable = true;
    gateway.enable = true;

    backend = {
      mode = "dashboard";
      port = dashboard.port;
      sessionTokenFile = "${config.home.homeDirectory}/.config/hermes/session-token";
    }
    // lib.optionalAttrs (dashboard.host != null) {
      # Only a host that states an address gets one: the module default is
      # loopback, and a null here must leave it alone.
      host = dashboard.host;
    };

    # The origin clients use, which the app trusts for the Host check even
    # when it differs from the bind address. Unset keeps the check on the
    # bind address alone.
    settings = lib.mkIf (dashboard.host != null) {
      dashboard.public_url = "http://${dashboard.host}:${toString dashboard.port}";
    };

    environmentFiles = [ "${config.home.homeDirectory}/.config/hermes/env" ];
  };

  # `hermes`, `hermes-agent` and `hermes-acp` on the PATH for ssh sessions.
  programs.hermes-agent.enable = true;
}
