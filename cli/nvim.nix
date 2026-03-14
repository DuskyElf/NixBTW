{ pkgs, inputs, ... }:
{
  home.packages = with pkgs; [
    inputs.neovimBTW.packages.${pkgs.stdenv.hostPlatform.system}.nvim

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
