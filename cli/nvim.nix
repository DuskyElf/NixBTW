{ pkgs, inputs, ... }:
{
  home.packages = with pkgs; [
    inputs.neovimBTW.packages.${pkgs.stdenv.hostPlatform.system}.nvim

    nodejs

    nil
    rust-analyzer
    lua-language-server
    svelte-language-server
    luajitPackages.luacheck
    typescript-language-server
    tailwindcss-language-server
    vscode-langservers-extracted

    stylua
    rustfmt
    prettierd
  ];

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };
}
