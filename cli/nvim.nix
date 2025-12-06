{ config, pkgs, ... }:
{
  home.packages = with pkgs; [
    neovimBTW

    nil # nix LSP
    nodejs
    stylua
    lua-language-server
    vscode-langservers-extracted
    luajitPackages.luacheck
  ];

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };
}
