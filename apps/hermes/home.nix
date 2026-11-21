# Hermes Agent: Nous Research's agent, run as a user service for the one
# account on this box. The gateway is always on, the dashboard answers on a
# loopback port, and the state in ~/.hermes is the same one `hermes` uses over
# ssh, because programs.hermes-agent exports HERMES_HOME.
#
# The app owns its configuration. Upstream's module is managed: activation
# merges config.yaml, writes .env from `environment` and `environmentFiles`
# when either is set, writes a `.managed` marker, and both units carry
# HERMES_MANAGED=home-manager. In that state every configuration write is
# refused with "this Hermes installation is managed by home-manager", which is
# what the desktop app's provider wizard hit. Three overrides turn that
# ownership off:
#
#   1. HERMES_MANAGED. get_managed_system() reads this variable first, and
#      treats false, 0, no and off as "not managed". A file read by systemd
#      sets it to off, after the value the module puts in Environment=.
#   2. The .managed marker. Activation writes it for an interactive shell,
#      which sees no unit environment, and the entry below deletes it after the
#      module's own activation ran.
#   3. .env. `environmentFiles` stays empty and `environment` stays unset, so
#      no activation writes that file. The app appends the keys the wizard
#      collects to it, and a rewrite each switch would delete them. A new
#      value for either option puts that rewrite back.
#
# The module still merges `terminal.cwd` and the `_config_version` stamp into
# config.yaml on each switch, and keeps every other key the app writes. Two
# consequences of that merge, because the file now has a second writer: a save
# the app makes inside the merge's read-modify-write can be lost, and comments
# in the file do not survive a switch.
#
# Upstream has no option for any of this, so the three overrides are the only
# route short of a patch. The brittle coupling is the activation entry name that
# the deletion below orders against: an unknown name in a DAG entry is ignored
# rather than an error, so a rename would silently leave the marker in place,
# and the assertion under the units turns that into a failed switch.
#
# The dashboard never binds a LAN address. apps/hermes/system.nix publishes it
# on the tailnet with `tailscale serve`, which proxies 443 to the loopback port,
# and hermes.dashboard.publicUrl in lib/host.nix carries the origin clients use.
# A host with a null publicUrl gets no unit there and keeps the dashboard local.
#
# The gate in front of the dashboard is a password plus a signing secret, and
# with the gate on and no provider registered the backend exits and its unit
# restarts for ever. On a host that publishes the dashboard, the backend reads
# the three values from `~/.config/hermes/env`, as a systemd environment file:
#
#   HERMES_DASHBOARD_BASIC_AUTH_USERNAME=<name>
#   HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=scrypt$...   (or _PASSWORD, plaintext)
#   HERMES_DASHBOARD_BASIC_AUTH_SECRET=<base64 of 32 or more random bytes>
#
# systemd does not expand `$` in an environment file, so the scrypt hash and the
# base64 secret reach the process unchanged. Write the file with a quoted
# heredoc or single quotes: a double-quoted shell string expands the `$` in the
# hash. The secret has to be that literal base64 value: a value that looks like
# an unexpanded shell command is discarded, and an empty one mints a key per
# process, which signs every session out on each restart.
#
# Make the directory and that file by hand on the box (`mkdir -p
# ~/.config/hermes`, mode 0600) and never in this tree. The values cannot live in
# the module's `settings` either: those render into the store, where every user
# can read them.
#
# This file is not copied into ~/.hermes. Hermes loads .env with override, so a
# copy there would shadow the values above and a rotated password would do
# nothing. The managed generation copied them in, so delete those three lines
# from `~/.hermes/.env` once; a reinstall never creates them.
#
# `backend.sessionTokenFile` is the second provider, the bearer token machine
# clients present, and the fallback if the desktop app's sign-in window does not
# take the password. The file has to exist and be non-empty before the unit
# starts: a backend that is named a token file it cannot read exits, and its unit
# restarts for ever. `head -c 32 /dev/urandom | base64` into
# `~/.config/hermes/session-token`, mode 0600, is the whole of it.
#
# Provider keys are not here. The app's own wizard, its settings panes and
# `hermes config set` write what they need, and the key the wizard collects
# lands in `~/.hermes/.env` with the rest of the app's state. The gateway reads
# that file again on each turn, and the process that takes a wizard key
# publishes it to itself, so a new key is live without a restart. Restart the
# backend when a key added from a shell has to reach the dashboard:
#
#   systemctl --user restart hermes-backend
#
# Not jailed (lib/jail.nix): the agent's job is running arbitrary tools with
# network access over the whole home, so a jail here would either break it or
# grant the same. It runs as duskyelf, in a user unit, with no privileges.
{
  config,
  lib,
  pkgs,
  inputs,
  hostConfig,
  ...
}:
let
  dashboard = hostConfig.hermes.dashboard;
  home = config.home.homeDirectory;

  # On a host that publishes the dashboard, the backend's unit lists this file
  # without a "-" prefix, so systemd refuses to start it when the file is
  # missing: a reinstall stops at systemd's message about the file rather than at
  # a backend that starts and drops out on the gate a few seconds later.
  gateEnvFile = "${home}/.config/hermes/env";

  # The deployment values, in one file rather than a literal on the unit: an
  # environment file read by systemd overrides Environment= for the same name,
  # and these are the values that have to win over the module's
  # HERMES_MANAGED=home-manager.
  #
  # The origin rides here and not in the module's `settings` on purpose.
  # resolve_public_url reads HERMES_DASHBOARD_PUBLIC_URL before config.yaml, so
  # the app cannot clear the gate with a config write, and a change to publicUrl
  # in lib/host.nix changes this file, which restarts the units that read it.
  #
  # The managed generation also wrote this origin into config.yaml as
  # `dashboard.public_url`. The merge only adds keys, so delete that key once:
  # while this file carries the variable it is inert, and it would turn the gate
  # back on for a host whose publicUrl is later set to null.
  deploymentEnv = pkgs.writeText "hermes-deployment.env" (
    lib.concatStringsSep "\n" (
      [ "HERMES_MANAGED=off" ]
      ++ lib.optional (dashboard.publicUrl != null) "HERMES_DASHBOARD_PUBLIC_URL=${dashboard.publicUrl}"
    )
    + "\n"
  );
in
{
  imports = [ inputs.hermes-agent.homeManagerModules.default ];

  services.hermes-agent = {
    enable = true;
    gateway.enable = true;

    backend = {
      mode = "dashboard";
      port = dashboard.port;
      sessionTokenFile = "${home}/.config/hermes/session-token";
    };
  };

  # Both units, because a config write can reach either process. The deployment
  # file goes last, where it wins over anything of the same name in the gate
  # file: that file is the operator's, and a stray HERMES_MANAGED= line there
  # must not turn managed mode back on. The gate file is only there for a host
  # that publishes the dashboard; a loopback-only host has no gate to feed.
  systemd.user.services.hermes-agent.Service.EnvironmentFile = [ "${deploymentEnv}" ];
  systemd.user.services.hermes-backend.Service.EnvironmentFile =
    lib.optionals (dashboard.publicUrl != null) [ gateEnvFile ]
    ++ [ "${deploymentEnv}" ];

  # An unknown name in a DAG entry is ignored, not an error, so the deletion
  # below would run at an arbitrary point after a rename upstream, leaving the
  # marker in place and the refusal back. This turns that into a failed switch.
  assertions = [
    {
      assertion = !config.services.hermes-agent.enable || config.home.activation ? hermesAgentSetup;
      message = "apps/hermes/home.nix deletes the marker that the upstream hermesAgentSetup entry writes, and that entry no longer exists. The marker would stay in place and every Hermes config write would be refused again; check the module's activation entry name.";
    }
  ];

  # The marker the module writes for an interactive shell. Without it the
  # `hermes` command from an ssh shell refuses a settings change that nothing
  # owns, while the two units already read the opt-out above.
  home.activation.hermesUnmanagedMarker = config.lib.dag.entryAfter [ "hermesAgentSetup" ] ''
    $DRY_RUN_CMD rm -f ${lib.escapeShellArg "${config.services.hermes-agent.hermesHome}/.managed"}
  '';

  # `hermes`, `hermes-agent` and `hermes-acp` on the PATH for ssh sessions.
  programs.hermes-agent.enable = true;
}
