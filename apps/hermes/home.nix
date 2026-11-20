# Hermes Agent: Nous Research's agent, run as a user service for the one
# account on this box. The gateway is always on, the dashboard answers on
# 127.0.0.1:9119 (reach it through an ssh tunnel), and the state in ~/.hermes is
# the same one `hermes` uses over ssh, because programs.hermes-agent exports
# HERMES_HOME.
#
# The provider key is not here, and it is not read from this file at runtime.
# Hermes reads `~/.hermes/.env`, and the activation builds that file from
# `~/.config/hermes/env`. So a new key is: `mkdir -p ~/.config/hermes`, create
# the file mode 0600 on the box, one KEY=value per line (OPENROUTER_API_KEY=...,
# ANTHROPIC_API_KEY=...), run `~/.config/scripts/hm-switch.sh --force` to re-run
# the activation, then restart `hermes-agent` and `hermes-backend`. A plain
# restart picks up nothing, and the activation only warns while the file is
# absent.
#
# Not jailed (lib/jail.nix): the agent's job is running arbitrary tools with
# network access over the whole home, so a jail here would either break it or
# grant the same. It runs as duskyelf, in a user unit, with no privileges.
#
# Managed mode is on (the nix module sets it), so `hermes setup` and
# `hermes config set` refuse to run: the settings below are the settings, and a
# change to them is a home switch.
{ config, inputs, ... }:
{
  imports = [ inputs.hermes-agent.homeManagerModules.default ];

  services.hermes-agent = {
    enable = true;
    gateway.enable = true;

    # The dashboard, on loopback only. 9119 is the upstream default and is
    # stated here so this file and the ssh tunnel in the docs cannot drift.
    backend.mode = "dashboard";
    backend.port = 9119;

    environmentFiles = [ "${config.home.homeDirectory}/.config/hermes/env" ];
  };

  # `hermes`, `hermes-agent` and `hermes-acp` on the PATH for ssh sessions.
  programs.hermes-agent.enable = true;
}
