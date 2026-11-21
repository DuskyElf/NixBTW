# The t3mcp CLI: the agent on this host reaches T3 Code MCP tools through a
# shell command instead of an MCP client of its own. The script is
# apps/t3code/t3mcp.py, and mcp is the official Python MCP SDK, so tool names
# and schemas are read from the server at run time; only T3's pairing handshake
# is written out.
#
# Paired servers live in ~/.config/t3mcp/config.json, one entry per T3 Code
# environment, so `--server` selects between (for example) this machine and the
# laptop. Tokens are bearer sessions from the MCP OAuth flow and last 30 days;
# `t3mcp pair` mints a new one from a code printed by `t3 auth pairing create`
# on the server being paired.
#
# Jailed to the network and its own config: it reads nothing else, and
# `network` is what also binds /etc/ssl and the resolver that the TLS MCP
# connection needs. The jail clears the environment, so the selector variable
# is forwarded explicitly, and the config directory is created on activation
# because the jail only binds directories that exist when it starts.
{
  config,
  jail,
  pkgs,
  ...
}:
let
  t3mcp = pkgs.writers.writePython3Bin "t3mcp" {
    libraries = [ pkgs.python3Packages.mcp ];
    flakeIgnore = [
      "E501"
      "W503"
    ];
  } (builtins.readFile ./t3mcp.py);
in
{
  home.packages = [
    (jail "t3mcp" t3mcp (
      c: with c; [
        network
        (xdg-app config.home.homeDirectory "t3mcp")
        (try-fwd-env "T3MCP_SERVER")
      ]
    ))
  ];

  home.activation.t3mcpConfigDir = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    run install -d -m 700 "$HOME/.config/t3mcp"
  '';
}
